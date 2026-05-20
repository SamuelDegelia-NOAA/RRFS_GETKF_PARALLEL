#!/bin/bash

max_run_cycles=3

rrfspath=${RRFSPATH:-/lfs/h1/ops/para/com/rrfs/v1.0}
baserundir=${BASERUNDIR:-/lfs/h2/emc/stmp/samuel.degelia/GETKF_PARALLEL}
max_run_cycles=${MAX_RUN_CYCLES:-3}
dispatch_lock=${baserundir}/.enspath_dispatch_lock
cycle_history=${baserundir}/.enspath_cycle_history.txt
timestamp=$(date -u +%Y%m%d%H%M%S)
status_file=${baserundir}/monitor_enspath_${timestamp}.status
script_dir=$(cd "$(dirname "$0")" && pwd)
driver_script=${DRIVER_SCRIPT:-${script_dir}/DRIVER_analysis.sh}
cycle_lock_file=""          # path of the per-cycle lock file we hold
dispatch_lock_acquired=0    # 1 while we hold the dispatcher lock
ensemble_size=${ENSEMBLE_SIZE:-30}
prepbufr_obsbase=${PREPBUFR_OBSBASE:-/lfs/h1/ops/prod/com/obsproc/v1.2}

source "${script_dir}/util/driver_analysis_common.sh"

cleanup_old_status_files() {
    find "${baserundir}" -maxdepth 1 -type f -name 'monitor_enspath_*.status' -mmin +60 \
        -exec rm -f {} \; 2>/dev/null
}

if ! mkdir -p "${baserundir}"; then
    echo "ERROR: Unable to create baserundir: ${baserundir}" >&2
    exit 1
fi

cleanup_old_status_files

if ! touch "${cycle_history}"; then
    echo "ERROR: Unable to initialize cycle history file: ${cycle_history}" >&2
    exit 1
fi
if ! [[ "${ensemble_size}" =~ ^[0-9]+$ ]] || [[ "${ensemble_size}" -lt 1 ]]; then
    echo "ERROR: ENSEMBLE_SIZE must be a positive integer: ${ensemble_size}" >&2
    exit 1
fi

required_suffixes=(
    "coupler.res"
    "fv_core.res.nc"
    "fv_core.res.tile1.nc"
    "fv_diag.res.tile1.nc"
    "fv_srf_wnd.res.tile1.nc"
    "fv_tracer.res.tile1.nc"
    "phy_data.nc"
    "sfc_data.nc"
)

declare -A file_size_thresholds=(
    ["coupler.res"]=300
    ["fv_core.res.nc"]=20852
    ["fv_core.res.tile1.nc"]=22227756443
    ["fv_diag.res.tile1.nc"]=85367256
    ["fv_srf_wnd.res.tile1.nc"]=85367256
    ["fv_tracer.res.tile1.nc"]=47139539099
    ["phy_data.nc"]=42830964708
    ["sfc_data.nc"]=10964019255
)

log() {
    local msg="[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
    echo "${msg}" >&2
    echo "${msg}" >> "${status_file}"
}

release_cycle_lock() {
    if [[ -n "${cycle_lock_file}" && -f "${cycle_lock_file}" ]]; then
        local lock_pid
        lock_pid=$(awk -F= '/^pid=/{print $2}' "${cycle_lock_file}" 2>/dev/null)
        if [[ "${lock_pid}" == "$$" ]]; then
            rm -f "${cycle_lock_file}"
        fi
        cycle_lock_file=""
    fi
}

release_dispatch_lock() {
    if [[ "${dispatch_lock_acquired}" -eq 1 && -f "${dispatch_lock}" ]]; then
        local lock_pid
        lock_pid=$(awk -F= '/^pid=/{print $2}' "${dispatch_lock}" 2>/dev/null)
        if [[ "${lock_pid}" == "$$" ]]; then
            rm -f "${dispatch_lock}"
        fi
        dispatch_lock_acquired=0
    fi
}
trap 'release_cycle_lock; release_dispatch_lock' EXIT INT TERM

pid_is_active() {
    local pid="$1"
    [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

cycle_lock_path() {
    local cycle="$1"
    echo "${baserundir}/.enspath_lock_${cycle}"
}

cycle_lock_is_active() {
    local lockpath="$1"
    local lock_pid
    lock_pid=$(awk -F= '/^pid=/{print $2}' "${lockpath}" 2>/dev/null)
    pid_is_active "${lock_pid}"
}

count_active_cycle_locks() {
    local count=0
    local lockpath
    for lockpath in "${baserundir}"/.enspath_lock_[0-9]*; do
        [[ -f "${lockpath}" ]] || continue
        if cycle_lock_is_active "${lockpath}"; then
            count=$((count + 1))
        else
            log "Removing stale per-cycle lock: ${lockpath}"
            rm -f "${lockpath}"
        fi
    done
    echo "${count}"
}

acquire_dispatch_lock() {
    local max_wait=30
    local waited=0
    while ! (set -o noclobber; printf 'pid=%s\nstart_time=%s\nowner=automated_driver\n' \
        "$$" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "${dispatch_lock}") 2>/dev/null; do
        if [[ -f "${dispatch_lock}" ]]; then
            local lock_pid
            lock_pid=$(awk -F= '/^pid=/{print $2}' "${dispatch_lock}" 2>/dev/null)
            if ! pid_is_active "${lock_pid}"; then
                rm -f "${dispatch_lock}"
                continue
            fi
        fi
        if [[ "${waited}" -ge "${max_wait}" ]]; then
            log "Timeout waiting for dispatcher lock after ${max_wait}s; aborting."
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    dispatch_lock_acquired=1
    return 0
}

acquire_cycle_lock() {
    local cycle="$1"
    local lockpath
    lockpath=$(cycle_lock_path "${cycle}")
    if ! (set -o noclobber; printf 'pid=%s\ncycle=%s\nstart_time=%s\nowner=automated_driver\n' \
        "$$" "${cycle}" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "${lockpath}") 2>/dev/null; then
        if cycle_lock_is_active "${lockpath}"; then
            log "Per-cycle lock already active for ${cycle}; skipping."
            return 1
        fi
        log "Removing stale per-cycle lock for ${cycle}: ${lockpath}"
        rm -f "${lockpath}"
        if ! (set -o noclobber; printf 'pid=%s\ncycle=%s\nstart_time=%s\nowner=automated_driver\n' \
            "$$" "${cycle}" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "${lockpath}") 2>/dev/null; then
            log "Could not acquire per-cycle lock for ${cycle} after stale removal."
            return 1
        fi
    fi
    cycle_lock_file="${lockpath}"
    return 0
}

parse_cycle_from_path() {
    local path="$1"
    if [[ "${path}" =~ enkfrrfs\.([0-9]{8})/([0-9]{2})(_spinup)?$ ]]; then
        echo "${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    else
        return 1
    fi
}

resolve_cycle_enspath() {
    local cycle="$1"
    local hh="${cycle:8:2}"
    local base="${rrfspath}/enkfrrfs.${cycle:0:8}"
    if [[ -d "${base}/${hh}" ]]; then
        echo "${base}/${hh}"
    elif [[ -d "${base}/${hh}_spinup" ]]; then
        echo "${base}/${hh}_spinup"
    else
        return 1
    fi
}

prepbufr_file_for_cycle() {
    local cycle="$1"
    if ! [[ "${cycle}" =~ ^[0-9]{10}$ ]]; then
        log "ERROR: Invalid cycle format for prepbufr path derivation: ${cycle} (expected YYYYMMDDHH)"
        return 1
    fi
    local yyyymmdd="${cycle:0:8}"
    local hh="${cycle:8:2}"
    echo "${prepbufr_obsbase}/rrfs.${yyyymmdd}/rrfs.t${hh}z.prepbufr.tm00"
}

get_successful_cycles() {
    # Outputs all cycles marked SUCCESS in the history file, one per line
    awk '$2=="SUCCESS"{print $1}' "${cycle_history}"
}

get_next_cycle_to_process() {
    local cycle
    local path
    local -A success_set

    # Build a lookup set of all cycles already successfully processed
    while read -r cycle; do
        success_set["${cycle}"]=1
    done < <(get_successful_cycles)

    if [[ ${#success_set[@]} -gt 0 ]]; then
        log "Successful cycles in history (${#success_set[@]}): ${!success_set[*]}"
    else
        log "Successful cycles in history (0): none"
    fi

    # Scan filesystem for available cycles, newest first, and select the
    # first cycle that has not already succeeded and has valid restart files
    while read -r path; do
        if ! cycle=$(parse_cycle_from_path "${path}"); then
            log "Could not parse cycle from ${path}"
            continue
        fi

        if [[ -n "${success_set[${cycle}]:-}" ]]; then
            log "Skipping cycle ${cycle}: already marked SUCCESS"
            continue
        fi

        local lockpath
        lockpath=$(cycle_lock_path "${cycle}")
        if [[ -f "${lockpath}" ]]; then
            if cycle_lock_is_active "${lockpath}"; then
                log "Skipping cycle ${cycle}: already running (lock active)"
                continue
            else
                log "Removing stale per-cycle lock for ${cycle}: ${lockpath}"
                rm -f "${lockpath}"
            fi
        fi

        log "Evaluating candidate cycle ${cycle} (${path})"
        if validate_restart_files "${path}"; then
            log "Selected cycle ${cycle} from ${path}"
            echo "${cycle}"
            return 0
        fi

        log "Cycle ${cycle} (${path}) is not ready; continuing search"
    done < <(find "${rrfspath}" -mindepth 2 -maxdepth 2 -type d -regextype posix-extended \
        -regex ".*/enkfrrfs\.[0-9]{8}/[0-9]{2}(_spinup)?" | sort -r)

    return 1
}

validate_restart_files() {
    local enspath="$1"
    local member
    local restart_dir
    local suffix
    local file
    local actual_size
    local min_size
    local missing=0

    if ! compute_valid_cycle_from_enspath "${enspath}"; then
        log "ERROR: invalid cycle parsed from enspath: ${enspath}"
        return 1
    fi
    restart_prefix="${VALID_RESTART_PREFIX}"
    log "Validating member restart files for ${enspath} (prefix ${restart_prefix})"

    for member_num in $(seq 1 "${ensemble_size}"); do
        member=$(printf "m%03d" "${member_num}")
        restart_dir="${enspath}/${member}/forecast/RESTART"
        if [[ ! -d "${restart_dir}" ]]; then
            log "MISSING: ${restart_dir}"
            missing=1
            continue
        fi
        for suffix in "${required_suffixes[@]}"; do
            file="${restart_dir}/${restart_prefix}.${suffix}"
            if [[ ! -f "${file}" ]]; then
                log "MISSING: ${file}"
                missing=1
            else
                min_size="${file_size_thresholds[${suffix}]}"
                if [[ -n "${min_size}" ]]; then
                    actual_size=$(stat -c%s "${file}" 2>/dev/null || stat -f%z "${file}" 2>/dev/null)
                    if [[ -z "${actual_size}" ]]; then
                        log "ERROR: Unable to determine file size for ${file}"
                        missing=1
                    elif [[ "${actual_size}" -lt "${min_size}" ]]; then
                        log "UNDERSIZED: ${file} (${actual_size} < ${min_size})"
                        missing=1
                    fi
                fi
            fi
        done
    done

    if [[ "${missing}" -ne 0 ]]; then
        return 1
    fi
    return 0
}

record_processed_cycle() {
    local cycle="$1"
    local status="$2"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "${cycle} ${status} ${ts}" >> "${cycle_history}"
}

if [[ ! -x "${driver_script}" ]]; then
    log "ERROR: DRIVER script not found or not executable: ${driver_script}"
    exit 1
fi

# --- Dispatcher: acquire short-lived lock to safely select the next cycle ---
if ! acquire_dispatch_lock; then
    log "Could not acquire dispatcher lock; aborting."
    exit 1
fi

# Count currently running cycles; exit if at capacity
active_count=$(count_active_cycle_locks)
log "Active running cycles: ${active_count} / ${max_run_cycles}"
if [[ "${active_count}" -ge "${max_run_cycles}" ]]; then
    log "At maximum concurrent cycles (${max_run_cycles}); not starting another."
    release_dispatch_lock
    exit 0
fi

next_cycle=$(get_next_cycle_to_process)
if [[ -z "${next_cycle}" ]]; then
    log "No new cycles with complete restart files found."
    release_dispatch_lock
    exit 0
fi
if ! next_enspath=$(resolve_cycle_enspath "${next_cycle}"); then
    log "ERROR: Cannot resolve enspath for cycle ${next_cycle}"
    release_dispatch_lock
    exit 1
fi
log "Found next cycle to process: ${next_cycle} (${next_enspath})"

if ! validate_restart_files "${next_enspath}"; then
    log "Not all required files are available yet for cycle ${next_cycle}. Will retry on next cron run."
    release_dispatch_lock
    exit 0
fi
log "All required files are present for cycle ${next_cycle}"

if ! prepbufr_file=$(prepbufr_file_for_cycle "${next_cycle}"); then
    log "ERROR: Aborting cycle ${next_cycle} due to invalid cycle format."
    release_dispatch_lock
    exit 1
fi
if [[ ! -f "${prepbufr_file}" ]]; then
    log "PREPBUFR file not available yet for cycle ${next_cycle}: ${prepbufr_file}. Will retry on next cron run."
    release_dispatch_lock
    exit 0
fi
log "PREPBUFR file is present for cycle ${next_cycle}: ${prepbufr_file}"

if ! acquire_cycle_lock "${next_cycle}"; then
    log "Could not acquire per-cycle lock for ${next_cycle}; another process may have claimed it."
    release_dispatch_lock
    exit 0
fi

# Release the dispatcher lock before the long-running analysis begins
release_dispatch_lock

log "Starting DRIVER_analysis.sh for cycle ${next_cycle}"
if "${driver_script}" "${next_enspath}" >> "${status_file}" 2>&1; then
    log "DRIVER completed successfully for cycle ${next_cycle}"
    record_processed_cycle "${next_cycle}" "SUCCESS"
else
    log "DRIVER failed for cycle ${next_cycle}; leaving cycle unprocessed for retry."
    record_processed_cycle "${next_cycle}" "FAILED"
    exit 1
fi

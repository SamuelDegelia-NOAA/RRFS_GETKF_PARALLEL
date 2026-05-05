#!/bin/bash

rrfspath=${RRFSPATH:-/lfs/h1/ops/para/com/rrfs/v1.0}
baserundir=${BASERUNDIR:-/lfs/h2/emc/stmp/samuel.degelia/GETKF_PARALLEL}
lockfile=${LOCKFILE:-${baserundir}/.enspath_lock}
cycle_history=${baserundir}/.enspath_cycle_history.txt
timestamp=$(date -u +%Y%m%d%H%M%S)
status_file=${baserundir}/monitor_enspath_${timestamp}.status
script_dir=$(cd "$(dirname "$0")" && pwd)
driver_script=${DRIVER_SCRIPT:-${script_dir}/DRIVER_analysis.sh}
lock_acquired=0
ensemble_size=${ENSEMBLE_SIZE:-30}

source "${script_dir}/util/driver_analysis_common.sh"

if ! mkdir -p "${baserundir}"; then
    echo "ERROR: Unable to create baserundir: ${baserundir}" >&2
    exit 1
fi
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
    ["phy_data.nc"]=45603871429
    ["sfc_data.nc"]=10964019255
)

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "${status_file}" >&2
}

release_lock() {
    if [[ "${lock_acquired}" -eq 1 && -f "${lockfile}" ]]; then
        lock_pid=$(awk -F= '/^pid=/{print $2}' "${lockfile}" 2>/dev/null)
        if [[ "${lock_pid}" == "$$" ]]; then
            rm -f "${lockfile}"
        fi
    fi
}
trap release_lock EXIT INT TERM

lock_is_active() {
    local lock_pid
    lock_pid=$(awk -F= '/^pid=/{print $2}' "${lockfile}" 2>/dev/null)
    [[ -n "${lock_pid}" ]] && kill -0 "${lock_pid}" 2>/dev/null
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

    log "Successful cycles in history (${#success_set[@]}): ${!success_set[*]:-none}"

    # Scan filesystem for available cycles, newest first, and select the
    # first cycle that has not already succeeded and has valid restart files
    while read -r path; do
        if ! cycle=$(parse_cycle_from_path "${path}"); then
            log "Could not parse cycle from ${path}"
            continue
        fi

        if [[ -v "success_set[${cycle}]" ]]; then
            log "Skipping cycle ${cycle}: already marked SUCCESS"
            continue
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

acquire_lock() {
    local cycle="$1"
    if [[ -f "${lockfile}" ]]; then
        if lock_is_active; then
            log "Lock exists (${lockfile}); a run is already in progress."
            return 1
        fi
        log "Removing stale lock file: ${lockfile}"
        rm -f "${lockfile}"
    fi
    cat > "${lockfile}" << EOF
pid=$$
cycle=${cycle}
start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
owner=automated_driver
EOF
    lock_acquired=1
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

next_cycle=$(get_next_cycle_to_process)
if [[ -z "${next_cycle}" ]]; then
    log "No new cycles with complete restart files found."
    exit 0
fi
if ! next_enspath=$(resolve_cycle_enspath "${next_cycle}"); then
    log "ERROR: Cannot resolve enspath for cycle ${next_cycle}"
    exit 1
fi
log "Found next cycle to process: ${next_cycle} (${next_enspath})"

if ! validate_restart_files "${next_enspath}"; then
    log "Not all required files are available yet for cycle ${next_cycle}. Will retry on next cron run."
    exit 0
fi
log "All required files are present for cycle ${next_cycle}"

if ! acquire_lock "${next_cycle}"; then
    exit 0
fi

log "Starting DRIVER_analysis.sh for cycle ${next_cycle}"
if "${driver_script}" "${next_enspath}" >> "${status_file}" 2>&1; then
    log "DRIVER completed successfully for cycle ${next_cycle}"
    record_processed_cycle "${next_cycle}" "SUCCESS"
else
    log "DRIVER failed for cycle ${next_cycle}; leaving cycle unprocessed for retry."
    record_processed_cycle "${next_cycle}" "FAILED"
    exit 1
fi

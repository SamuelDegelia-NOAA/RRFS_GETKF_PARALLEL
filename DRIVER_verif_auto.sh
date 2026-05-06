#!/bin/bash
# DRIVER_verif_auto.sh
#
# Automation wrapper for DRIVER_verif.sh.  Intended to be invoked from cron
# independently of DRIVER_analysis_auto.sh so that verification runs do not
# block or interfere with analysis cycles.
#
# Readiness is determined by checking whether the GETKF output directory for a
# given cycle contains the three expected increment files rather than by
# scanning the RRFS restart-file tree.
#
# GETKF cycle directories are named  getkf.YYYYMMDDHH  and live under
# ${getkf_base}.  When a cycle is ready DRIVER_verif.sh is called with the
# RRFS data path for one hour *earlier* than the GETKF cycle because the
# verification script derives the analysis time as +1 h from the input path.
#
# Example:
#   GETKF cycle  2026050616
#   →  ./DRIVER_verif.sh /lfs/h1/ops/para/com/rrfs/v1.0/enkfrrfs.20260506/15


max_run_cycles=3

getkf_base=${GETKF_BASE:-/lfs/h2/emc/stmp/samuel.degelia/GETKF_PARALLEL}
rrfspath=${RRFSPATH:-/lfs/h1/ops/para/com/rrfs/v1.0}
baserundir=${BASERUNDIR:-${getkf_base}}
max_run_cycles=${MAX_VERIF_RUN_CYCLES:-${MAX_RUN_CYCLES:-3}}
dispatch_lock=${baserundir}/.verif_dispatch_lock
cycle_history=${baserundir}/.verif_cycle_history.txt
script_dir=$(cd "$(dirname "$0")" && pwd)
driver_script=${DRIVER_VERIF_SCRIPT:-${script_dir}/DRIVER_verif.sh}
cycle_lock_file=""       # path of the per-cycle lock file we hold
dispatch_lock_acquired=0 # 1 while we hold the dispatcher lock

# Required increment files that must exist for a GETKF cycle to be considered done
getkf_required_files=(
    "inc_jedi_mean.fv_core.res.nc"
    "inc_jedi_mean.fv_tracer.res.nc"
    "inc_jedi_mean.phy_data.nc"
)

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >&2
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
    echo "${baserundir}/.verif_lock_${cycle}"
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
    for lockpath in "${baserundir}"/.verif_lock_[0-9]*; do
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

# Parse a YYYYMMDDHH cycle string from a getkf directory path.
# Accepts paths ending in  getkf.YYYYMMDDHH
parse_cycle_from_getkf_dir() {
    local path="$1"
    local dirname
    dirname=$(basename "${path}")
    if [[ "${dirname}" =~ ^getkf\.([0-9]{10})$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        return 1
    fi
}

# Return true if all required GETKF increment files exist in the given dir.
getkf_cycle_is_ready() {
    local getkf_dir="$1"
    local f
    for f in "${getkf_required_files[@]}"; do
        if [[ ! -f "${getkf_dir}/${f}" ]]; then
            log "GETKF cycle not ready — missing: ${getkf_dir}/${f}"
            return 1
        fi
    done
    return 0
}

# Subtract one hour from a YYYYMMDDHH cycle string.
# Outputs the adjusted YYYYMMDDHH.
# Requires GNU date (standard on Linux; use coreutils on macOS/BSD).
cycle_minus_1h() {
    local cycle="$1"
    local yyyy="${cycle:0:4}"
    local mm="${cycle:4:2}"
    local dd="${cycle:6:2}"
    local hh="${cycle:8:2}"
    # Use date arithmetic to subtract one hour
    date -u -d "${yyyy}-${mm}-${dd} ${hh}:00:00 UTC - 1 hour" +%Y%m%d%H
}

# Resolve the RRFS input directory for the given YYYYMMDDHH cycle.
resolve_rrfs_input_path() {
    local cycle="$1"
    local date="${cycle:0:8}"
    local hh="${cycle:8:2}"
    echo "${rrfspath}/enkfrrfs.${date}/${hh}"
}

get_successful_cycles() {
    awk '$2=="SUCCESS"{print $1}' "${cycle_history}"
}

get_next_getkf_cycle() {
    local -A success_set
    local cycle

    # Build lookup set of already-successful cycles
    while read -r cycle; do
        success_set["${cycle}"]=1
    done < <(get_successful_cycles)

    if [[ ${#success_set[@]} -gt 0 ]]; then
        log "Successful cycles in history (${#success_set[@]}): ${!success_set[*]}"
    else
        log "Successful cycles in history (0): none"
    fi

    # Iterate GETKF cycle directories, newest first
    local getkf_dir
    while read -r getkf_dir; do
        if ! cycle=$(parse_cycle_from_getkf_dir "${getkf_dir}"); then
            log "Could not parse cycle from ${getkf_dir}"
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

        log "Evaluating candidate GETKF cycle ${cycle} (${getkf_dir})"
        if getkf_cycle_is_ready "${getkf_dir}"; then
            log "Selected GETKF cycle ${cycle}"
            echo "${cycle}"
            return 0
        fi

        log "GETKF cycle ${cycle} is not ready; continuing search"
    done < <(find "${getkf_base}" -mindepth 1 -maxdepth 1 -type d \
        -name 'getkf.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' | sort -r)

    return 1
}

record_processed_cycle() {
    local cycle="$1"
    local status="$2"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "${cycle} ${status} ${ts}" >> "${cycle_history}"
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

if ! mkdir -p "${baserundir}"; then
    log "ERROR: Unable to create baserundir: ${baserundir}"
    exit 1
fi

if ! touch "${cycle_history}"; then
    log "ERROR: Unable to initialize cycle history file: ${cycle_history}"
    exit 1
fi

if [[ ! -x "${driver_script}" ]]; then
    log "ERROR: DRIVER script not found or not executable: ${driver_script}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Dispatcher: acquire short-lived lock to safely select the next cycle
# ---------------------------------------------------------------------------

if ! acquire_dispatch_lock; then
    log "Could not acquire dispatcher lock; aborting."
    exit 1
fi

active_count=$(count_active_cycle_locks)
log "Active running cycles: ${active_count} / ${max_run_cycles}"
if [[ "${active_count}" -ge "${max_run_cycles}" ]]; then
    log "At maximum concurrent cycles (${max_run_cycles}); not starting another."
    release_dispatch_lock
    exit 0
fi

next_cycle=$(get_next_getkf_cycle)
if [[ -z "${next_cycle}" ]]; then
    log "No GETKF cycles with complete increment files found."
    release_dispatch_lock
    exit 0
fi

# Compute RRFS input path = cycle − 1 hour
input_cycle=$(cycle_minus_1h "${next_cycle}")
rrfs_input_path=$(resolve_rrfs_input_path "${input_cycle}")
log "Found next GETKF cycle: ${next_cycle}  →  RRFS input path: ${rrfs_input_path}"

if ! acquire_cycle_lock "${next_cycle}"; then
    log "Could not acquire per-cycle lock for ${next_cycle}; another process may have claimed it."
    release_dispatch_lock
    exit 0
fi

# Release the dispatcher lock before the long-running verification begins
release_dispatch_lock

log "Starting DRIVER_verif.sh for cycle ${next_cycle}"
if "${driver_script}" "${rrfs_input_path}"; then
    log "DRIVER_verif.sh completed successfully for cycle ${next_cycle}"
    record_processed_cycle "${next_cycle}" "SUCCESS"
else
    log "DRIVER_verif.sh failed for cycle ${next_cycle}; leaving cycle unprocessed for retry."
    record_processed_cycle "${next_cycle}" "FAILED"
    exit 1
fi

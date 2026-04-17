#!/bin/bash

rrfspath=${RRFSPATH:-/lfs/h1/ops/para/com/rrfs/v1.0}
baserundir=${BASERUNDIR:-/lfs/h2/emc/stmp/samuel.degelia/GETKF_PARALLEL}
lockfile=${LOCKFILE:-${baserundir}/.enspath_lock}
processed_file=${baserundir}/.enspath_processed.list
timestamp=$(date -u +%Y%m%d%H%M%S)
status_file=${baserundir}/monitor_enspath_${timestamp}.status
script_dir=$(cd "$(dirname "$0")" && pwd)
driver_script=${DRIVER_SCRIPT:-${script_dir}/DRIVER_analysis.sh}
lock_acquired=0

if ! mkdir -p "${baserundir}"; then
    echo "ERROR: Unable to create baserundir: ${baserundir}" >&2
    exit 1
fi
if ! touch "${processed_file}"; then
    echo "ERROR: Unable to initialize processed file: ${processed_file}" >&2
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

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "${status_file}"
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

get_next_unprocessed_enspath() {
    find "${rrfspath}" -mindepth 2 -maxdepth 2 -type d -regextype posix-extended \
        -regex ".*/enkfrrfs\.[0-9]{8}/[0-9]{2}" | sort | while read -r path; do
        if ! grep -Fxq "${path}" "${processed_file}"; then
            echo "${path}"
            break
        fi
    done
}

get_restart_prefix() {
    local enspath="$1"
    local hh="${enspath##*/}"
    local tmp="${enspath%/*}"
    local yyyymmdd="${tmp##*.}"
    local cycle_epoch
    cycle_epoch=$(date -u -d "${yyyymmdd:0:4}-${yyyymmdd:4:2}-${yyyymmdd:6:2} ${hh}:00:00" +%s) || return 1
    date -u -d "@$((cycle_epoch + 3600))" +%Y%m%d.%H0000
}

validate_restart_files() {
    local enspath="$1"
    local restart_prefix
    local member
    local restart_dir
    local suffix
    local file
    local missing=0

    restart_prefix=$(get_restart_prefix "${enspath}") || return 1
    log "Validating member restart files for ${enspath} (prefix ${restart_prefix})"

    for member_num in $(seq 1 30); do
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
            fi
        done
    done

    if [[ "${missing}" -ne 0 ]]; then
        return 1
    fi
    return 0
}

acquire_lock() {
    local enspath="$1"
    if [[ -f "${lockfile}" ]]; then
        log "Lock exists (${lockfile}); a run is already in progress."
        return 1
    fi
    cat > "${lockfile}" << EOF
pid=$$
enspath=${enspath}
start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
owner=monitor_enspath.sh
EOF
    lock_acquired=1
    return 0
}

if [[ ! -x "${driver_script}" ]]; then
    log "ERROR: DRIVER script not found or not executable: ${driver_script}"
    exit 1
fi

next_enspath=$(get_next_unprocessed_enspath)
if [[ -z "${next_enspath}" ]]; then
    log "No new enspath cycles found."
    exit 0
fi
log "Found new enspath candidate: ${next_enspath}"

if ! validate_restart_files "${next_enspath}"; then
    log "Not all required files are available yet. Will retry on next cron run."
    exit 0
fi
log "All required files are present for ${next_enspath}"

if ! acquire_lock "${next_enspath}"; then
    exit 0
fi

log "Starting DRIVER_analysis.sh for ${next_enspath}"
if GETKF_EXTERNAL_LOCK=1 "${driver_script}" "${next_enspath}" >> "${status_file}" 2>&1; then
    log "DRIVER completed successfully for ${next_enspath}"
    echo "${next_enspath}" >> "${processed_file}"
else
    log "DRIVER failed for ${next_enspath}; leaving cycle unprocessed for retry."
    exit 1
fi

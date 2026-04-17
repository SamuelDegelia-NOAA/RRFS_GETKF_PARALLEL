#!/bin/bash

# This script grabs the real-time background ensemble from RRFSv1 and runs a JEDI-based GETKF analysis every hour
# Tasks include:
#   1. Run bufr2ioda.x to generate IODA observations including radar obs
#   2. Set up analysis run directory using saved fix files
#   3. Run GETKF analysis

# TODO: where and how to pre-process phy_data files in parallel?

# Settings
RDASApp=/lfs/h2/emc/da/noscrub/samuel.degelia/RDASApp_redist_iodafix/RDASApp
rrfsworkflow=/lfs/h2/emc/da/noscrub/samuel.degelia/rrfs-workflow_na3km/rrfs-workflow
rrfspath=/lfs/h1/ops/para/com/rrfs/v1.0
reflpath=/lfs/h1/ops/prod/dcom/ldmdata/obs/upperair/mrms/conus/MergedReflectivityQC
obsbase=/lfs/h1/ops/prod/com/obsproc/v1.2
baserundir=${BASERUNDIR:-/lfs/h2/emc/stmp/samuel.degelia/GETKF_PARALLEL}
getkfyaml=/lfs/h2/emc/da/noscrub/samuel.degelia/parallel_getkf/fix/rdas-atmosphere-templates-fv3_na3km_getkf.yaml
lockfile=${LOCKFILE:-${baserundir}/.enspath_lock}
lock_created=0

cleanup_lock() {
    if [[ "${lock_created}" -eq 1 && -f "${lockfile}" ]]; then
        lock_pid=$(awk -F= '/^pid=/{print $2}' "${lockfile}" 2>/dev/null)
        if [[ "${lock_pid}" == "$$" ]]; then
            rm -f "${lockfile}"
        fi
    fi
}
trap cleanup_lock EXIT INT TERM

lock_is_active() {
    local lock_pid
    lock_pid=$(awk -F= '/^pid=/{print $2}' "${lockfile}" 2>/dev/null)
    [[ -n "${lock_pid}" ]] && kill -0 "${lock_pid}" 2>/dev/null
}

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <enspath>"
    exit 1
fi
enspath="$1"
if [[ ! -d "${enspath}" ]]; then
    echo "ERROR: enspath does not exist: ${enspath}"
    exit 1
fi

if [[ "${GETKF_EXTERNAL_LOCK:-0}" == "1" ]]; then
    if [[ ! -f "${lockfile}" ]]; then
        echo "ERROR: GETKF_EXTERNAL_LOCK=1 but lock file does not exist: ${lockfile}"
        exit 1
    fi
else
    mkdir -p "$(dirname "${lockfile}")"
    if [[ -f "${lockfile}" ]]; then
        if lock_is_active; then
            echo "Another run is already in progress (lock file exists: ${lockfile})"
            exit 1
        fi
        echo "Removing stale lock file: ${lockfile}"
        rm -f "${lockfile}"
    fi
    cat > "${lockfile}" << EOF
pid=$$
enspath=${enspath}
start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
owner=DRIVER_analysis.sh
EOF
    lock_created=1
fi

# Get the latest analysis we want to run and setup the run directories
# Hard-coded now just for debugging
# TODO: add logic to fetch the latest cycle that is fully done
# NOTE: the enspath contains RESTART files for the next forecast hour
# So enkfrrfs.20260416/15 contains the restart files for 2026041616
# Thus we need to look for obs at one hour after the restart file
HH=${enspath##*/}
tmp=${enspath%/*}
YYYYMMDD=${tmp##*.}
cycle_epoch=$(date -u -d "${YYYYMMDD:0:4}-${YYYYMMDD:4:2}-${YYYYMMDD:6:2} ${HH}:00:00" +%s) || {
    echo "ERROR: invalid cycle time parsed from enspath: ${enspath}"
    exit 1
}
timestamp=$(date -u -d "@$((cycle_epoch + 3600))" +%Y%m%d%H)
YYYYMMDD=${timestamp:0:8}
HH=${timestamp:8:2}
YYYY=${YYYYMMDD:0:4}
MM=${YYYYMMDD:4:2}
DD=${YYYYMMDD:6:2}
obspath=${obsbase}/rrfs.${YYYYMMDD}
bufrdir=${baserundir}/bufr.${YYYYMMDD}${HH}
mrmsdir=${baserundir}/mrms.${YYYYMMDD}${HH}
anldir=${baserundir}/getkf.${YYYYMMDD}${HH}

# Export the variables we will need in other tasks
envfile=getkf_run.env
cat > ${envfile} << EOF
RDASApp='${RDASApp}'
rrfsworkflow='${rrfsworkflow}'
rrfspath='${rrfspath}'
reflpath='${reflpath}'
obspath='${obspath}'
baserundir='${baserundir}'
enspath='${enspath}'
HH='${HH}'
YYYYMMDD='${YYYYMMDD}'
YYYY='${YYYY}'
MM='${MM}'
DD='${DD}'
bufrdir='${bufrdir}'
mrmsdir='${mrmsdir}'
anldir='${anldir}'
getkfyaml='${getkfyaml}'
EOF

# Build run directories
#if [ -d ${bufrdir} ]; then
#  rm -rf ${bufrdir}
#fi
#if [ -d ${mrmsdir} ]; then
#  rm -rf ${mrmsdir}
#fi
#if [ -d ${anldir} ]; then
#  rm -rf ${anldir}
#fi
rm bufr.log mrms.log getkf.log
mkdir -p ${bufrdir}
mkdir -p ${mrmsdir}
mkdir -p ${anldir}
cp ${envfile} ${bufrdir}
cp ${envfile} ${mrmsdir}
cp ${envfile} ${anldir}

# Create radar observations
#job1=$(qsub -v envfile="${envfile}" scripts/exrrfs_process_radar.sh)

# Convert prepbufr observations to IODA
#job2=$(qsub -v envfile="${envfile}" scripts/exrrfs_ioda_bufr.sh)

# Now run the GETKF analysis
#qsub -W depend=afterok:${job1}:${job2} scripts/exrrfs_analysis_enkf_jedi.sh
qsub -v envfile="${envfile}" scripts/exrrfs_analysis_enkf_jedi.sh

# Move output files for better tracking
exit
# need to figure out how to wait for the jobs to be done though
mv bufr.log  bufr_${YYYYMMDD}${HH}.log
mv mrms.log  mrms_${YYYYMMDD}${HH}.log
mv getkf.log getkf_${YYYYMMDD}${HH}.log

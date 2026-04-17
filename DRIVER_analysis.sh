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

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <enspath>"
    exit 1
fi
enspath="$1"
if [[ ! -d "${enspath}" ]]; then
    echo "ERROR: enspath does not exist: ${enspath}"
    exit 1
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
source "${script_dir}/scripts/driver_analysis_common.sh"

# Path to the job-submission utility
submit="${script_dir}/scripts/submit_job.sh"

# -----------------------------------------------------------------------
# Per-task PBS resource settings.
# Override any of these environment variables before calling this script
# to customize queue, account, node counts, or wall-clock limits without
# editing the task scripts.
# -----------------------------------------------------------------------
PBS_ACCOUNT=${PBS_ACCOUNT:-RRFS-DEV}
PBS_QUEUE=${PBS_QUEUE:-dev}

# Radar reflectivity processing
RADAR_JOB_NAME=${RADAR_JOB_NAME:-na3km_process_radarref}
RADAR_SELECT=${RADAR_SELECT:-1:mpiprocs=64:ncpus=64}
radar_nodes_default=${RADAR_SELECT%%:*}
radar_ppn_default=$(echo "${RADAR_SELECT}" | sed -n 's/.*mpiprocs=\([0-9][0-9]*\).*/\1/p')
if ! [[ "${radar_nodes_default}" =~ ^[0-9]+$ ]] || ! [[ "${radar_ppn_default}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: unable to derive radar node/core settings from RADAR_SELECT=${RADAR_SELECT}" >&2
    exit 1
fi
RADAR_NNODES_PROC_RADAR=${RADAR_NNODES_PROC_RADAR:-${radar_nodes_default}}
RADAR_PPN_PROC_RADAR=${RADAR_PPN_PROC_RADAR:-${radar_ppn_default}}
RADAR_WALLTIME=${RADAR_WALLTIME:-00:25:00}
RADAR_PLACE=${RADAR_PLACE:-excl}
RADAR_LOG=${RADAR_LOG:-mrms.log}

# BUFR → IODA conversion
BUFR_JOB_NAME=${BUFR_JOB_NAME:-na3km_ioda_bufr}
BUFR_SELECT=${BUFR_SELECT:-1:mpiprocs=1:ncpus=1:mem=20G}
BUFR_WALLTIME=${BUFR_WALLTIME:-00:20:00}
BUFR_PLACE=${BUFR_PLACE:-excl}
BUFR_LOG=${BUFR_LOG:-bufr.log}

# GETKF analysis
GETKF_JOB_NAME=${GETKF_JOB_NAME:-na3km_getkf}
GETKF_SELECT=${GETKF_SELECT:-40:mpiprocs=40:ompthreads=1:ncpus=40}
getkf_nodes_default=${GETKF_SELECT%%:*}
getkf_ppn_default=$(echo "${GETKF_SELECT}" | sed -n 's/.*mpiprocs=\([0-9][0-9]*\).*/\1/p')
if ! [[ "${getkf_nodes_default}" =~ ^[0-9]+$ ]] || ! [[ "${getkf_ppn_default}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: unable to derive GETKF node/core settings from GETKF_SELECT=${GETKF_SELECT}" >&2
    exit 1
fi
GETKF_PPN=${GETKF_PPN:-${getkf_ppn_default}}
GETKF_NCORES=${GETKF_NCORES:-$(( getkf_nodes_default*GETKF_PPN ))}
GETKF_WALLTIME=${GETKF_WALLTIME:-01:00:00}
GETKF_PLACE=${GETKF_PLACE:-vscatter}
GETKF_LOG=${GETKF_LOG:-getkf.log}

# Get the latest analysis we want to run and setup the run directories
# Hard-coded now just for debugging
# TODO: add logic to fetch the latest cycle that is fully done
# NOTE: the enspath contains RESTART files for the next forecast hour
# So enkfrrfs.20260416/15 contains the restart files for 2026041616
# Thus we need to look for obs at one hour after the restart file
HH=${enspath##*/}
if ! compute_valid_cycle_from_enspath "${enspath}"; then
    echo "ERROR: invalid cycle time parsed from enspath: ${enspath}"
    exit 1
fi
YYYYMMDD=${VALID_YYYYMMDD}
HH=${VALID_HH}
YYYY=${VALID_YYYY}
MM=${VALID_MM}
DD=${VALID_DD}
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

rm -f bufr.log mrms.log getkf.log
mkdir -p ${bufrdir}
mkdir -p ${mrmsdir}
mkdir -p ${anldir}
cp ${envfile} ${bufrdir}
cp ${envfile} ${mrmsdir}
cp ${envfile} ${anldir}
cp ./scripts/prep_phydata_dbz.py ${anldir}

# Create radar observations
job1=$(bash "${submit}" \
    -N "${RADAR_JOB_NAME}" \
    -A "${PBS_ACCOUNT}" \
    -q "${PBS_QUEUE}" \
    -l "select=${RADAR_SELECT}" \
    -l "walltime=${RADAR_WALLTIME}" \
    -l "place=${RADAR_PLACE}" \
    -o "${RADAR_LOG}" \
    -v "envfile=${envfile},RADAR_NNODES_PROC_RADAR=${RADAR_NNODES_PROC_RADAR},RADAR_PPN_PROC_RADAR=${RADAR_PPN_PROC_RADAR}" \
    "${script_dir}/scripts/exrrfs_process_radar.sh")

# Convert prepbufr observations to IODA
job2=$(bash "${submit}" \
    -N "${BUFR_JOB_NAME}" \
    -A "${PBS_ACCOUNT}" \
    -q "${PBS_QUEUE}" \
    -l "select=${BUFR_SELECT}" \
    -l "walltime=${BUFR_WALLTIME}" \
    -l "place=${BUFR_PLACE}" \
    -o "${BUFR_LOG}" \
    -v "envfile=${envfile}" \
    "${script_dir}/scripts/exrrfs_ioda_bufr.sh")

# Run the GETKF analysis after both upstream jobs complete successfully
job3=$(bash "${submit}" \
    -N "${GETKF_JOB_NAME}" \
    -A "${PBS_ACCOUNT}" \
    -q "${PBS_QUEUE}" \
    -l "select=${GETKF_SELECT}" \
    -l "walltime=${GETKF_WALLTIME}" \
    -l "place=${GETKF_PLACE}" \
    -o "${GETKF_LOG}" \
    -v "envfile=${envfile},GETKF_NCORES=${GETKF_NCORES},GETKF_PPN=${GETKF_PPN}" \
    -W "depend=afterok:${job1}:${job2}" \
    "${script_dir}/scripts/exrrfs_analysis_enkf_jedi.sh")

echo "Submitted jobs: radar=${job1} bufr=${job2} getkf=${job3}"

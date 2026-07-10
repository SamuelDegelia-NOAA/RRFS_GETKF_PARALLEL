#!/bin/bash

# This script grabs the real-time background ensemble from RRFSv1 and runs a JEDI-based GETKF analysis every hour
# Tasks include:
#   1. Run bufr2ioda.x to generate IODA observations including radar obs
#   2. Generate reflectivity IODA observations from MRMS data
#   3. Copy per-member background files into data/inputs/mem0XX (runs concurrently with tasks 1 and 2)
#   4. Run GETKF analysis (depends on tasks 1, 2, and 3)
#   5. Post-process GETKF member increments into FV3-LAM-ready restart files

################
### Settings ###
################

# Clean up increments after done with analysis
do_clean="TRUE"
do_post_process_increments="${DO_POST_PROCESS_INCREMENTS:-FALSE}"
# Keep ensemble-mean increments for this many most-recent hourly cycles
# when cleaning older cycle directories. Current-cycle ensemble-mean files
# are preserved separately for verification.
clean_ensmean_retention_cycles=24

# Paths to local installs
RDASApp=/lfs/h2/emc/da/noscrub/samuel.degelia/RDASApp_redist_fv3io_dwind/RDASApp
rrfsworkflow=/lfs/h2/emc/da/noscrub/samuel.degelia/rrfs-workflow_na3km/rrfs-workflow
baserundir=/lfs/h2/emc/stmp/samuel.degelia/GETKF_PARALLEL

# GETKF config
getkfyaml=/lfs/h2/emc/da/noscrub/samuel.degelia/parallel_getkf/fix/rdas-atmosphere-templates-fv3_na3km_getkf.yaml

# Paths to RRFS ensemble and observations in realtime (wont change)
installdir=/lfs/h2/emc/da/noscrub/samuel.degelia/parallel_getkf # where this script lives
rrfspath=/lfs/h1/ops/para/com/rrfs/v1.0
reflpath=/lfs/h1/ops/prod/dcom/ldmdata/obs/upperair/mrms/conus/MergedReflectivityQC
obsbase=/lfs/h1/ops/prod/com/obsproc/v1.2

#############################
### Begin executable code ###
#############################

cd ${installdir}
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
source "${script_dir}/util/driver_analysis_common.sh"
submit="${script_dir}/util/submit_job.sh"

# -----------------------------------------------------------------------
# Per-task PBS resource settings.
# Override any of these environment variables before calling this script
# to customize queue, account, node counts, or wall-clock limits without
# editing the task scripts.
# -----------------------------------------------------------------------
PBS_ACCOUNT="RRFS-DEV"
PBS_QUEUE="dev"

# Radar reflectivity processing
RADAR_JOB_NAME="na3km_process_radarref"
RADAR_SELECT="1:mpiprocs=64:ncpus=64"
RADAR_WALLTIME="00:25:00"
RADAR_PALCE="excl"
RADAR_LOG="mrms.log"

# BUFR to IODA conversion
BUFR_JOB_NAME="na3km_ioda_bufr"
BUFR_SELECT="1:mpiprocs=1:ncpus=1:mem=20G"
BUFR_WALLTIME="00:20:00"
BUFR_PLACE="excl"
BUFR_LOG="bufr.log"

# GETKF analysis
GETKF_JOB_NAME="na3km_getkf"
GETKF_SELECT="60:mpiprocs=32:ompthreads=1:ncpus=128"
GETKF_WALLTIME="00:30:00"
GETKF_PLACE="vscatter"
GETKF_LOG="getkf.log"

# Post-process member increments into FV3-LAM-ready restart files
POST_INCS_JOB_NAME="na3km_post_process_incs"
POST_INCS_SELECT="1:mpiprocs=1:ncpus=1:mem=20G"
POST_INCS_WALLTIME="00:45:00"
POST_INCS_PLACE="vscatter"
POST_INCS_LOG="post_incs.log"

# Prep GETKF member input directories (copy background files; runs concurrently with MRMS and BUFR tasks)
PREP_GETKF_MEMS_JOB_NAME="na3km_prep_getkf_mems"
PREP_GETKF_MEMS_SELECT="1:mpiprocs=1:ncpus=1:mem=20G"
PREP_GETKF_MEMS_WALLTIME="00:15:00"
PREP_GETKF_MEMS_PLACE="excl"

# Get number of nodes and tasks to pass into the scripts
RADAR_PBS_NP=$(echo "${RADAR_SELECT}" | grep -oP 'mpiprocs\s*=\s*\K[0-9]+')
RADAR_PBS_NUM_NODES=$(echo "${RADAR_SELECT}" | grep -oP '^\s*\K[0-9]+(?=\s*:)')
BUFR_PBS_NP=$(echo "${BUFR_SELECT}" | grep -oP 'mpiprocs\s*=\s*\K[0-9]+')
BUFR_PBS_NUM_NODES=$(echo "${BUFR_SELECT}" | grep -oP '^\s*\K[0-9]+(?=\s*:)')
GETKF_PBS_NP=$(echo "${GETKF_SELECT}" | grep -oP 'mpiprocs\s*=\s*\K[0-9]+')
GETKF_PBS_NUM_NODES=$(echo "${GETKF_SELECT}" | grep -oP '^\s*\K[0-9]+(?=\s*:)')
POST_INCS_PBS_NP=$(echo "${POST_INCS_SELECT}" | grep -oP 'mpiprocs\s*=\s*\K[0-9]+')
POST_INCS_PBS_NUM_NODES=$(echo "${POST_INCS_SELECT}" | grep -oP '^\s*\K[0-9]+(?=\s*:)')
PREP_GETKF_MEMS_PBS_NP=$(echo "${PREP_GETKF_MEMS_SELECT}" | grep -oP 'mpiprocs\s*=\s*\K[0-9]+')
PREP_GETKF_MEMS_PBS_NUM_NODES=$(echo "${PREP_GETKF_MEMS_SELECT}" | grep -oP '^\s*\K[0-9]+(?=\s*:)')

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
currdir=`pwd`
fixsimple=${currdir}/fix
if [ ! -d ./logs ]; then
  mkdir -p logs
fi
mkdir -p "${baserundir}"

# Use cycle-specific log names from the start so concurrent cycles don't collide
RADAR_LOG="logs/mrms_${YYYYMMDD}${HH}.log"
BUFR_LOG="logs/bufr_${YYYYMMDD}${HH}.log"
GETKF_LOG="logs/getkf_${YYYYMMDD}${HH}.log"
POST_INCS_LOG="logs/post_incs_${YYYYMMDD}${HH}.log"
PREP_GETKF_MEMS_LOG="logs/prep_getkf_mems_${YYYYMMDD}${HH}.log"

# Export the variables we will need in other tasks.
# Use a cycle-unique absolute path so concurrent cycles cannot overwrite each other.
envfile="${baserundir}/getkf_run_${YYYYMMDD}${HH}.env"
cat > ${envfile} << EOF
RDASApp='${RDASApp}'
rrfsworkflow='${rrfsworkflow}'
rrfspath='${rrfspath}'
reflpath='${reflpath}'
obsbase='${obsbase}'
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
fixsimple='${fixsimple}'
COMOUT='${currdir}/logs'
do_clean='${do_clean}'
do_post_process_increments='${do_post_process_increments}'
clean_ensmean_retention_cycles='${clean_ensmean_retention_cycles}'
EOF

if [ -d ${bufrdir} ]; then
  rm -rf ${bufrdir}
fi
if [ -d ${mrmsdir} ]; then
  rm -rf ${mrmsdir}
fi
if [ -d ${anldir} ]; then
  rm -rf ${anldir}
fi
mkdir -p ${bufrdir}
mkdir -p ${mrmsdir}
mkdir -p ${anldir}
cp ${envfile} ${bufrdir}
cp ${envfile} ${mrmsdir}
cp ${envfile} ${anldir}
cp ./util/prep_ioda_cast.sh ${bufrdir}
cp ./util/prep_phydata_dbz.py ${anldir}

# Determine ensemble size once; used by both prep_getkf_mems and post_process_increments loops.
# Member subdirectories under enspath follow the pattern m001, m002, ..., so search for m[0-9]*.
nens="${nens:-}"
if ! [[ "${nens}" =~ ^[0-9]+$ ]] || (( nens < 1 )); then
  nens=$(find "${enspath}" -maxdepth 1 -type d -name 'm[0-9]*' | wc -l)
fi
if ! [[ "${nens}" =~ ^[0-9]+$ ]] || (( nens < 1 )); then
  echo "ERROR: unable to determine ensemble size from ${enspath}"
  exit 1
fi

# Create radar observations
job1=$(bash "${submit}" \
    -N "${RADAR_JOB_NAME}" \
    -A "${PBS_ACCOUNT}" \
    -q "${PBS_QUEUE}" \
    -l "select=${RADAR_SELECT}" \
    -l "walltime=${RADAR_WALLTIME}" \
    -l "place=${RADAR_PLACE}" \
    -o "${RADAR_LOG}" \
    -v "envfile=${envfile}" \
    -v "PBS_NP=${RADAR_PBS_NP},PBS_NUM_NODES=${RADAR_PBS_NUM_NODES}" \
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
    -v "PBS_NP=${BUFR_PBS_NP},PBS_NUM_NODES=${BUFR_PBS_NUM_NODES}" \
    "${script_dir}/scripts/exrrfs_ioda_bufr.sh")

# Copy per-member background files into data/inputs/mem0XX.
# These 30 jobs run concurrently with the MRMS and BUFR preprocessing tasks above.
prep_getkf_mems_jobs=()
for imem in $(seq 1 "${nens}"); do
  mem3=$(printf "%03i" "${imem}")
  member_log="logs/prep_getkf_mems_${YYYYMMDD}${HH}_mem${mem3}.log"
  member_job_name="${PREP_GETKF_MEMS_JOB_NAME}_m${mem3}"
  member_job=$(bash "${submit}" \
      -N "${member_job_name}" \
      -A "${PBS_ACCOUNT}" \
      -q "${PBS_QUEUE}" \
      -l "select=${PREP_GETKF_MEMS_SELECT}" \
      -l "walltime=${PREP_GETKF_MEMS_WALLTIME}" \
      -l "place=${PREP_GETKF_MEMS_PLACE}" \
      -o "${member_log}" \
      -v "envfile=${envfile}" \
      -v "PBS_NP=${PREP_GETKF_MEMS_PBS_NP},PBS_NUM_NODES=${PREP_GETKF_MEMS_PBS_NUM_NODES}" \
      -v "PREP_GETKF_MEMBER=${imem}" \
      "${script_dir}/scripts/exrrfs_prep_getkf_mems.sh")
  prep_getkf_mems_jobs+=("${member_job}")
done
prep_getkf_mems_dep=$(IFS=:; echo "${prep_getkf_mems_jobs[*]}")

# Run the GETKF analysis after MRMS, BUFR, and all per-member prep jobs complete successfully
job3=$(bash "${submit}" \
    -N "${GETKF_JOB_NAME}" \
    -A "${PBS_ACCOUNT}" \
    -q "${PBS_QUEUE}" \
    -l "select=${GETKF_SELECT}" \
    -l "walltime=${GETKF_WALLTIME}" \
    -l "place=${GETKF_PLACE}" \
    -o "${GETKF_LOG}" \
    -v "envfile=${envfile}" \
    -v "PBS_NP=${GETKF_PBS_NP},PBS_NUM_NODES=${GETKF_PBS_NUM_NODES}" \
    -W "depend=afterok:${job1}:${job2}:${prep_getkf_mems_dep}" \
    "${script_dir}/scripts/exrrfs_analysis_enkf_jedi.sh")

job4=""
job5=""
post_member_jobs=()
if [ "${do_post_process_increments}" == "TRUE" ]; then
  # Post-process member increments after GETKF analysis succeeds using one PBS job per member.
  nens="30"
  for imem in $(seq 1 "${nens}"); do
    mem3=$(printf "%03i" "${imem}")
    member_log="logs/post_incs_${YYYYMMDD}${HH}_mem${mem3}.log"
    member_job_name="${POST_INCS_JOB_NAME}_m${mem3}"
    member_job=$(bash "${submit}" \
        -N "${member_job_name}" \
        -A "${PBS_ACCOUNT}" \
        -q "${PBS_QUEUE}" \
        -l "select=${POST_INCS_SELECT}" \
        -l "walltime=${POST_INCS_WALLTIME}" \
        -l "place=${POST_INCS_PLACE}" \
        -o "${member_log}" \
        -v "envfile=${envfile}" \
        -v "PBS_NP=${POST_INCS_PBS_NP},PBS_NUM_NODES=${POST_INCS_PBS_NUM_NODES}" \
        -v "POST_INCS_MEMBER=${imem},POST_INCS_RUN_CLEANUP=FALSE" \
        -W "depend=afterok:${job3}" \
        "${script_dir}/scripts/exrrfs_post_process_increments.sh")
    post_member_jobs+=("${member_job}")
  done
  if [ "${#post_member_jobs[@]}" -gt 0 ]; then
    job4="${post_member_jobs[0]}"
    post_dep=$(IFS=:; echo "${post_member_jobs[*]}")
    if [ "${do_clean}" == "TRUE" ]; then
      job5=$(bash "${submit}" \
          -N "${POST_INCS_JOB_NAME}_cleanup" \
          -A "${PBS_ACCOUNT}" \
          -q "${PBS_QUEUE}" \
          -l "select=1:mpiprocs=1:ncpus=1" \
          -l "walltime=00:10:00" \
          -l "place=excl" \
          -o "${POST_INCS_LOG}" \
          -v "envfile=${envfile}" \
          -v "POST_INCS_CLEANUP_ONLY=TRUE,POST_INCS_RUN_CLEANUP=TRUE,PBS_NP=1,PBS_NUM_NODES=1" \
          -W "depend=afterok:${post_dep}" \
          "${script_dir}/scripts/exrrfs_post_process_increments.sh")
    fi
  fi
fi

echo "Submitted jobs: radar=${job1} bufr=${job2} prep_getkf_mems_first=${prep_getkf_mems_jobs[0]} getkf=${job3} post_incs_first=${job4:-SKIPPED} post_incs_cleanup=${job5:-SKIPPED}"

job_list=("${job1}" "${job2}" "${prep_getkf_mems_jobs[@]}" "${job3}")
if [[ "${#post_member_jobs[@]}" -gt 0 ]]; then
  job_list+=("${post_member_jobs[@]}")
fi
if [[ -n "${job5}" ]]; then
  job_list+=("${job5}")
fi

# Wait for all jobs to complete
while true; do
  qstat_output=$(qstat "${job_list[@]}" 2>/dev/null || true)
  jobs_remaining=0
  for jid in "${job_list[@]}"; do
    if [[ "${qstat_output}" == *"${jid}"* ]]; then
      jobs_remaining=1
      break
    fi
  done
  if [[ "${jobs_remaining}" -eq 0 ]]; then
    break
  fi
  sleep 10
done

rm ${envfile}
exit 0

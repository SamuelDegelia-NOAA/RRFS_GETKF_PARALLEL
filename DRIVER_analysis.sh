#!/bin/bash

# This script grabs the real-time background ensemble from RRFSv1 and runs a JEDI-based GETKF analysis every hour
# Tasks include:
#   1. Run bufr2ioda.x to generate IODA observations including radar obs
#   2. Generate reflectivity IODA observations from MRMS data
#   3. Copy per-member background files into data/inputs/mem0XX (runs concurrently with tasks 1 and 2)
#   4. Run GETKF analysis (depends on tasks 1, 2, and 3); writes most analyzed variables directly
#      in-place into the background files copied in task 3, and the analyzed A-grid wind into
#      ua_anl/va_anl (leaving the original ua/va background and the D-grid u/v untouched)
#   5. Post-process each member's analysis with rdas_ua2u.x --in_anl (depends on task 4; 30 jobs,
#      one per member, run concurrently): convert ua_anl/va_anl to a D-grid wind increment, add it
#      to the background u/v in place, and remove ua_anl/va_anl -- producing a complete,
#      restart-ready analysis
#   6. Clean up increment/rundir files (depends on all of task 5, since it is now the last step)

################
### Settings ###
################

# Clean up increments after done with analysis
do_clean="TRUE"
# Keep ensemble-mean increments for this many most-recent hourly cycles
# when cleaning older cycle directories. Current-cycle ensemble-mean files
# are preserved separately for verification.
clean_ensmean_retention_cycles=24

# Paths to local installs
#RDASApp=/lfs/h2/emc/da/noscrub/samuel.degelia/RDASApp_redist_fv3io_dwind/RDASApp
RDASApp=/lfs/h2/emc/da/noscrub/samuel.degelia/RDASApp_oopsbranchonestep_uarename/RDASApp
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

# Prep GETKF member input directories (copy background files; runs concurrently with MRMS and BUFR tasks)
PREP_GETKF_MEMS_JOB_NAME="na3km_prep_getkf_mems"
PREP_GETKF_MEMS_SELECT="1:mpiprocs=1:ncpus=1:mem=20G"
PREP_GETKF_MEMS_WALLTIME="00:15:00"
PREP_GETKF_MEMS_PLACE="excl"

# Post-process GETKF member analyses (rdas_ua2u.x --in_anl: convert the analyzed
# A-grid wind to D-grid u/v in place, then drop ua_anl/va_anl; runs after GETKF,
# one job per member, all 30 in parallel). rdas_ua2u.x's own work for this
# operation is single-rank (MPI_Init still required) with OpenMP-threaded loops,
# so ompthreads/ncpus give it some intra-node parallelism without needing more
# than 1 mpiproc.
POSTPROC_GETKF_MEMS_JOB_NAME="na3km_postproc_getkf_mems"
POSTPROC_GETKF_MEMS_SELECT="1:mpiprocs=1:ompthreads=8:ncpus=8:mem=20G"
POSTPROC_GETKF_MEMS_WALLTIME="00:15:00"
POSTPROC_GETKF_MEMS_PLACE="excl"

# Final cleanup, now that D-grid wind post-processing (not the GETKF task) is
# the last step in the workflow. Runs once, after all POSTPROC_GETKF_MEMS jobs.
POSTPROC_CLEANUP_JOB_NAME="na3km_postproc_getkf_cleanup"
POSTPROC_CLEANUP_SELECT="1:mpiprocs=1:ncpus=1:mem=4G"
POSTPROC_CLEANUP_WALLTIME="00:10:00"
POSTPROC_CLEANUP_PLACE="excl"

# Get number of nodes and tasks to pass into the scripts
RADAR_PBS_NP=$(echo "${RADAR_SELECT}" | grep -oP 'mpiprocs\s*=\s*\K[0-9]+')
RADAR_PBS_NUM_NODES=$(echo "${RADAR_SELECT}" | grep -oP '^\s*\K[0-9]+(?=\s*:)')
BUFR_PBS_NP=$(echo "${BUFR_SELECT}" | grep -oP 'mpiprocs\s*=\s*\K[0-9]+')
BUFR_PBS_NUM_NODES=$(echo "${BUFR_SELECT}" | grep -oP '^\s*\K[0-9]+(?=\s*:)')
GETKF_PBS_NP=$(echo "${GETKF_SELECT}" | grep -oP 'mpiprocs\s*=\s*\K[0-9]+')
GETKF_PBS_NUM_NODES=$(echo "${GETKF_SELECT}" | grep -oP '^\s*\K[0-9]+(?=\s*:)')
PREP_GETKF_MEMS_PBS_NP=$(echo "${PREP_GETKF_MEMS_SELECT}" | grep -oP 'mpiprocs\s*=\s*\K[0-9]+')
PREP_GETKF_MEMS_PBS_NUM_NODES=$(echo "${PREP_GETKF_MEMS_SELECT}" | grep -oP '^\s*\K[0-9]+(?=\s*:)')
POSTPROC_GETKF_MEMS_PBS_NP=$(echo "${POSTPROC_GETKF_MEMS_SELECT}" | grep -oP 'mpiprocs\s*=\s*\K[0-9]+')
POSTPROC_GETKF_MEMS_PBS_NUM_NODES=$(echo "${POSTPROC_GETKF_MEMS_SELECT}" | grep -oP '^\s*\K[0-9]+(?=\s*:)')
POSTPROC_GETKF_MEMS_PBS_OMPTHREADS=$(echo "${POSTPROC_GETKF_MEMS_SELECT}" | grep -oP 'ompthreads\s*=\s*\K[0-9]+')
POSTPROC_CLEANUP_PBS_NP=$(echo "${POSTPROC_CLEANUP_SELECT}" | grep -oP 'mpiprocs\s*=\s*\K[0-9]+')
POSTPROC_CLEANUP_PBS_NUM_NODES=$(echo "${POSTPROC_CLEANUP_SELECT}" | grep -oP '^\s*\K[0-9]+(?=\s*:)')

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
PREP_GETKF_MEMS_LOG="logs/prep_getkf_mems_${YYYYMMDD}${HH}.log"
POSTPROC_CLEANUP_LOG="logs/postproc_getkf_cleanup_${YYYYMMDD}${HH}.log"

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

# Determine ensemble size once; used by the prep_getkf_mems loop.
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

# Post-process each member's analysis (D-grid wind conversion) after GETKF
# completes. These 30 jobs run concurrently, one per member.
postproc_getkf_mems_jobs=()
for imem in $(seq 1 "${nens}"); do
  mem3=$(printf "%03i" "${imem}")
  member_log="logs/postproc_getkf_mems_${YYYYMMDD}${HH}_mem${mem3}.log"
  member_job_name="${POSTPROC_GETKF_MEMS_JOB_NAME}_m${mem3}"
  member_job=$(bash "${submit}" \
      -N "${member_job_name}" \
      -A "${PBS_ACCOUNT}" \
      -q "${PBS_QUEUE}" \
      -l "select=${POSTPROC_GETKF_MEMS_SELECT}" \
      -l "walltime=${POSTPROC_GETKF_MEMS_WALLTIME}" \
      -l "place=${POSTPROC_GETKF_MEMS_PLACE}" \
      -o "${member_log}" \
      -v "envfile=${envfile}" \
      -v "PBS_NP=${POSTPROC_GETKF_MEMS_PBS_NP},PBS_NUM_NODES=${POSTPROC_GETKF_MEMS_PBS_NUM_NODES}" \
      -v "OMP_NUM_THREADS=${POSTPROC_GETKF_MEMS_PBS_OMPTHREADS}" \
      -v "POSTPROC_GETKF_MEMBER=${imem}" \
      -W "depend=afterok:${job3}" \
      "${script_dir}/scripts/exrrfs_postproc_getkf_mems.sh")
  postproc_getkf_mems_jobs+=("${member_job}")
done
postproc_getkf_mems_dep=$(IFS=:; echo "${postproc_getkf_mems_jobs[*]}")

# Final cleanup, once all per-member post-processing jobs complete successfully
job4=$(bash "${submit}" \
    -N "${POSTPROC_CLEANUP_JOB_NAME}" \
    -A "${PBS_ACCOUNT}" \
    -q "${PBS_QUEUE}" \
    -l "select=${POSTPROC_CLEANUP_SELECT}" \
    -l "walltime=${POSTPROC_CLEANUP_WALLTIME}" \
    -l "place=${POSTPROC_CLEANUP_PLACE}" \
    -o "${POSTPROC_CLEANUP_LOG}" \
    -v "envfile=${envfile}" \
    -v "PBS_NP=${POSTPROC_CLEANUP_PBS_NP},PBS_NUM_NODES=${POSTPROC_CLEANUP_PBS_NUM_NODES}" \
    -W "depend=afterok:${postproc_getkf_mems_dep}" \
    "${script_dir}/scripts/exrrfs_postproc_getkf_cleanup.sh")

echo "Submitted jobs: radar=${job1} bufr=${job2} prep_getkf_mems_first=${prep_getkf_mems_jobs[0]} getkf=${job3} postproc_getkf_mems_first=${postproc_getkf_mems_jobs[0]} cleanup=${job4}"

job_list=("${job1}" "${job2}" "${prep_getkf_mems_jobs[@]}" "${job3}" "${postproc_getkf_mems_jobs[@]}" "${job4}")

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

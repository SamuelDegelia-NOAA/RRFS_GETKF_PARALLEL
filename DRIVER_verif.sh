#!/bin/bash

# This driver runs the verification for the earlier-run GETKF realtime parallel

################
### Settings ###
################

# Clean up analysis after done with the verification
do_clean="TRUE"

# Paths to local installs
RDASApp=/lfs/h2/emc/da/noscrub/samuel.degelia/RDASApp_redist_iodafix/RDASApp
rrfsworkflow=/lfs/h2/emc/da/noscrub/samuel.degelia/rrfs-workflow_na3km/rrfs-workflow
baserundir=/lfs/h2/emc/stmp/samuel.degelia/GETKF_PARALLEL

# Where to save the diag files for both GSI and JEDI
basesavedir=/lfs/h2/emc/da/noscrub/samuel.degelia/PARALLEL_SAVE

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

# GSI verification
VERIF_JOB_NAME="na3km_verif"
VERIF_SELECT="10:mpiprocs=8:ompthreads=16:ncpus=128"
VERIF_WALLTIME="01:00:00"
VERIF_PLACE="excl"
VERIF_LOG="verif.log"

# Get number of nodes and tasks to pass into the scripts
VERIF_PBS_NP=$(echo "${VERIF_SELECT}" | grep -oP 'ncpus\s*=\s*\K[0-9]+')
VERIF_PBS_NUM_NODES=$(echo "${VERIF_SELECT}" | grep -oP '^\s*\K[0-9]+(?=\s*:)')

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
verifdir=${baserundir}/verif.${YYYYMMDD}${HH}
savedir=${basesavedir}/verif.${YYYYMMDD}${HH}
currdir=`pwd`
fixsimple=${currdir}/fix
if [ ! -d ./logs ]; then
  mkdir -p logs
fi
mkdir -p "${baserundir}"

# Use cycle-specific log names from the start so concurrent cycles don't collide
VERIF_LOG="logs/verif_${YYYYMMDD}${HH}.log"

# Export the variables we will need in other tasks.
# Use a cycle-unique absolute path so concurrent cycles cannot overwrite each other.
envfile="${baserundir}/verif_run_${YYYYMMDD}${HH}.env"
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
verifdir='${verifdir}'
getkfyaml='${getkfyaml}'
fixsimple='${fixsimple}'
COMOUT='${savedir}'
EOF

rm -rf ${verifdir}
mkdir -p ${verifdir}
mkdir -p ${savedir}
cp ${envfile} ${verifdir}
cp ./util/apply_jedi_incs.py ${verifdir}


job4=$(bash "${submit}" \
    -N "${VERIF_JOB_NAME}" \
    -A "${PBS_ACCOUNT}" \
    -q "${PBS_QUEUE}" \
    -l "select=${VERIF_SELECT}" \
    -l "walltime=${VERIF_WALLTIME}" \
    -l "place=${VERIF_PLACE}" \
    -o "${VERIF_LOG}" \
    -v "envfile=${envfile}" \
    -v "PBS_NP=${VERIF_PBS_NP},PBS_NUM_NODES=${VERIF_PBS_NUM_NODES}" \
    "${script_dir}/scripts/exrrfs_verif_gsi.sh")

echo "Submitted jobs: verif=${job4}"

# Wait for all jobs to complete
while qstat_output=$(qstat "${job4}" 2>/dev/null || true); do
  if [[ "${qstat_output}" != *"${job4}"* ]]; then
      break
  fi
  sleep 10
done

rm ${envfile}
exit 0

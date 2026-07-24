#!/bin/bash
# Final cleanup step for the GETKF cycle. Runs once, after all 30
# exrrfs_postproc_getkf_mems.sh member jobs have completed successfully
# (this is now the last task in the workflow, since D-grid wind
# post-processing runs after the GETKF analysis task).
#
# Required environment variables (supplied via envfile + qsub -v):
#   envfile – path to the cycle-specific environment file

################
### Settings ###
################

cd "${PBS_O_WORKDIR}"
set -euox pipefail
echo "${envfile}"
source "${envfile}"

#############################
### Begin executable code ###
#############################

if [ "${do_clean}" == "TRUE" ]; then
  cleanup_script="$(cd "$(dirname "$0")/.." && pwd)/util/cleanup_getkf_increments.sh"
  if [[ ! -f "${cleanup_script}" ]]; then
    echo "ERROR: cleanup utility script not found: ${cleanup_script}"
    exit 1
  fi
  bash "${cleanup_script}" "${anldir}" "${baserundir}" "${YYYYMMDD}" "${HH}" "${clean_ensmean_retention_cycles:-24}"
fi

echo "GETKF cycle cleanup completed successfully!"

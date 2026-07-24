#!/bin/bash

# Post-processes the GETKF analysis for a single ensemble member: JEDI writes
# the analyzed A-grid wind into ua_anl/va_anl (leaving the original ua/va
# background untouched, per write-into-existing-files + field-rename) and
# writes every other analyzed variable directly in place under its normal
# name. Before the analysis is usable for a model restart, the D-grid u/v
# winds (which JEDI never touches) still need to be updated to match the new
# ua_anl/va_anl. This script does that with rdas_ua2u.x's --in_anl mode:
#   1. Compute the A-grid wind increment as (ua_anl-ua, va_anl-va)
#   2. Convert it to a D-grid (u/v) increment
#   3. Add that increment to the background u/v already in the file
#   4. Remove ua_anl/va_anl (--remove_anl_winds) now that they are no longer
#      needed, to save space
# The net effect: data/inputs/mem0XX/fv_core.res.tile1.nc goes from
# "background with an aliased analysis wind" to a complete, restart-ready
# analysis (u/v updated, everything else already in place from JEDI).
#
# One PBS job is submitted per member so all 30 runs happen in parallel.
#
# Required environment variables (supplied via envfile + qsub -v):
#   envfile                 – path to the cycle-specific environment file
#   POSTPROC_GETKF_MEMBER   – 1-based integer member index
#   OMP_NUM_THREADS         – threads for rdas_ua2u.x's OpenMP-parallel loops

################
### Settings ###
################

cd "${PBS_O_WORKDIR}"
set -euox pipefail
echo "${envfile}"
source "${envfile}"

# Member index is supplied by the driver via PBS -v
imem="${POSTPROC_GETKF_MEMBER}"
mem3=$(printf %03i "${imem}")
memcharv0="mem${mem3}"

#############################
### Begin executable code ###
#############################

cd "${anldir}"

anlfile="${anldir}/data/inputs/${memcharv0}/fv_core.res.tile1.nc"
gridfile="${anldir}/fv3_grid_spec"
pgmout="${anldir}/pgm_postproc_${memcharv0}.log"

if [[ ! -f "${anlfile}" ]]; then
  echo "ERROR: analysis file not found: ${anlfile}"
  exit 1
fi
if [[ ! -f "${gridfile}" ]]; then
  echo "ERROR: grid spec file not found: ${gridfile}"
  exit 1
fi

set +x
module purge
module use "${RDASApp}"/modulefiles
module load RDAS/wcoss2.intel
set -euox pipefail
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"
export LD_LIBRARY_PATH="${RDASApp}/build/lib64:${LD_LIBRARY_PATH}"

pgm="${RDASApp}/build/bin/rdas_ua2u.x"
if [[ ! -x "${pgm}" ]]; then
  echo "ERROR: rdas_ua2u.x executable not found: ${pgm}"
  exit 1
fi

echo "Member ${mem3}: converting analysis wind to D-grid and updating ${anlfile} in place"

start_epoch=$(date +%s)
mpiexec -n 1 -ppn 1 --cpu-bind core --depth "${OMP_NUM_THREADS}" "${pgm}" ua_update_u \
  --in_grid="${gridfile}" \
  --in_anl="${anlfile}" \
  --remove_anl_winds \
  >>"${pgmout}" 2>"errfile_ua2u_${memcharv0}"
end_epoch=$(date +%s)
elapsed=$((end_epoch - start_epoch))
echo "Total time: ${elapsed}.00s" | tee -a "${pgmout}"

echo "Member ${mem3} D-grid wind post-processing completed successfully!"

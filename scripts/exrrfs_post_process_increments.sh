#!/bin/bash

cd ${PBS_O_WORKDIR}
set -euox pipefail

echo ${envfile}
source "${envfile}"

nens=${nens:-30}
PREDEF_GRID_NAME=RRFS_NA_3km
FIX_GSI=${rrfsworkflow}/fix/gsi
EXECdir=${rrfsworkflow}/exec
apply_incs_script="$(cd "$(dirname "$0")/.." && pwd)/util/apply_jedi_incs.sh"
cleanup_script="$(cd "$(dirname "$0")/.." && pwd)/util/cleanup_getkf_increments.sh"

if [[ ! -f "${apply_incs_script}" ]]; then
  echo "ERROR: apply_jedi_incs utility script not found: ${apply_incs_script}"
  exit 1
fi
if [[ ! -f "${cleanup_script}" ]]; then
  echo "ERROR: cleanup utility script not found: ${cleanup_script}"
  exit 1
fi

cd ${anldir}
set +x
source ${rrfsworkflow}/versions/run.ver
module use ${rrfsworkflow}/modulefiles/tasks/wcoss2
module load run_fcst.local
module load intel udunits szip hdf5 netcdf gsl nco
set -x

do_radar=${DO_ENKF_RADAR_REF:-FALSE}
# Allow overriding this path externally if the default module stack changes.
UA2U_HDF5_LIB_PATH=${UA2U_HDF5_LIB_PATH:-/apps/ops/test/spack-stack-nco-1.9/oneapi/2024.2.1/hdf5-1.14.3-umtw5lv/lib}
post_work_root=${anldir}/post_process_increments_work
post_out_root=${anldir}/fv3lam_ready_restarts
mkdir -p "${post_work_root}" "${post_out_root}"
parallel_jobs=${POST_INCS_PARALLEL_JOBS:-${nens}}
if ! [[ "${parallel_jobs}" =~ ^[0-9]+$ ]] || (( parallel_jobs < 1 )); then
  echo "WARNING: invalid POST_INCS_PARALLEL_JOBS='${parallel_jobs}', using 1"
  parallel_jobs=1
fi
if [[ "${PBS_NP:-}" =~ ^[0-9]+$ ]] && (( PBS_NP > 0 )); then
  pbs_parallel_limit=${PBS_NP}
  if [[ "${PBS_NUM_NODES:-}" =~ ^[0-9]+$ ]] && (( PBS_NUM_NODES > 0 )); then
    pbs_parallel_limit=$(( PBS_NP * PBS_NUM_NODES ))
  fi
  if (( parallel_jobs > pbs_parallel_limit )); then
    parallel_jobs=${pbs_parallel_limit}
  fi
fi

process_member() {
  local imem="$1"
  local mem3
  mem3=$(printf "%03i" "${imem}")
  local memcharv0="mem${mem3}"
  local bkgdir="${anldir}/data/inputs/${memcharv0}"
  local incdir="${anldir}/${memcharv0}"
  local workdir="${post_work_root}/${memcharv0}"
  local outdir="${post_out_root}/${memcharv0}"

  mkdir -p "${workdir}" "${outdir}"

  for f in fv_core.res.tile1.nc fv_tracer.res.tile1.nc sfc_data.nc phy_data.nc fv_srf_wnd.res.tile1.nc coupler.res; do
    if [[ ! -e "${bkgdir}/${f}" ]]; then
      echo "ERROR: Missing background file for ${memcharv0}: ${bkgdir}/${f}"
      return 1
    fi
  done

  for f in inc_jedi.fv_core.res.nc inc_jedi.fv_tracer.res.nc; do
    if [[ ! -f "${incdir}/${f}" ]]; then
      echo "ERROR: Missing increment file for ${memcharv0}: ${incdir}/${f}"
      return 1
    fi
  done

  cp -f "${bkgdir}/fv_core.res.tile1.nc" "${workdir}/fv_core.res.tile1.nc"
  cp -f "${bkgdir}/fv_tracer.res.tile1.nc" "${workdir}/fv_tracer.res.tile1.nc"
  cp -f "${bkgdir}/phy_data.nc" "${workdir}/phy_data.nc"

  cp -f "${incdir}/inc_jedi.fv_core.res.nc" "${workdir}/inc_jedi.fv_core.res.nc"
  cp -f "${incdir}/inc_jedi.fv_tracer.res.nc" "${workdir}/inc_jedi.fv_tracer.res.nc"
  if [[ "${do_radar}" == "TRUE" && -f "${incdir}/inc_jedi.phy_data.nc" ]]; then
    cp -f "${incdir}/inc_jedi.phy_data.nc" "${workdir}/inc_jedi.phy_data.nc"
  fi

  ln -snf "${FIX_GSI}/${PREDEF_GRID_NAME}/fv3_grid_spec" "${workdir}/fv3_grid_spec"
  cp -f "${EXECdir}/bin/rdas_ua2u.x" "${workdir}/rdas_ua2u.x"

  pushd "${workdir}" >/dev/null
  mv inc_jedi.fv_core.res.nc agrid_inc_jedi.fv_core.res.nc
  LD_LIBRARY_PATH="${UA2U_HDF5_LIB_PATH}:${LD_LIBRARY_PATH}" \
    ./rdas_ua2u.x ua_update_u \
      --in_grid=fv3_grid_spec \
      --in_file=agrid_inc_jedi.fv_core.res.nc \
      --out_file=inc_jedi.fv_core.res.nc

  if [[ ! -s inc_jedi.fv_core.res.nc ]]; then
    echo "ERROR: inc_jedi.fv_core.res.nc missing or empty after rdas_ua2u.x for ${memcharv0}"
    popd >/dev/null
    return 1
  fi

  "${apply_incs_script}" "${do_radar}" fv_core.res.tile1.nc fv_tracer.res.tile1.nc phy_data.nc

  cp -f fv_core_analysis.res.tile1.nc "${outdir}/fv_core.res.tile1.nc"
  cp -f fv_tracer_analysis.res.tile1.nc "${outdir}/fv_tracer.res.tile1.nc"
  if [[ "${do_radar}" == "TRUE" && -f phy_data_analysis.nc ]]; then
    cp -f phy_data_analysis.nc "${outdir}/phy_data.nc"
  else
    cp -Lf phy_data.nc "${outdir}/phy_data.nc"
  fi
  cp -Lf "${bkgdir}/sfc_data.nc" "${outdir}/sfc_data.nc"
  cp -Lf "${bkgdir}/fv_srf_wnd.res.tile1.nc" "${outdir}/fv_srf_wnd.res.tile1.nc"
  cp -Lf "${bkgdir}/coupler.res" "${outdir}/coupler.res"
  popd >/dev/null

  echo "Completed post-processing for ${memcharv0}"
}

export anldir post_work_root post_out_root FIX_GSI PREDEF_GRID_NAME EXECdir do_radar apply_incs_script
export -f process_member

seq 1 "${nens}" | parallel -j "${parallel_jobs}" --halt soon,fail=1 process_member

echo "Post-processed FV3-LAM-ready restarts available under ${post_out_root}"

if [ "${do_clean:-FALSE}" == "TRUE" ]; then
  bash "${cleanup_script}" "${anldir}" "${baserundir}" "${YYYYMMDD}" "${HH}" "${clean_ensmean_retention_cycles:-24}"
fi

echo "POST-PROCESS-INCREMENTS completed successfully!!!"

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
member_id="${POST_INCS_MEMBER:-}"
cleanup_only="${POST_INCS_CLEANUP_ONLY:-FALSE}"
if [[ -n "${POST_INCS_RUN_CLEANUP:-}" ]]; then
  run_cleanup="${POST_INCS_RUN_CLEANUP}"
else
  run_cleanup="${do_clean:-FALSE}"
fi

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
if [[ "${run_cleanup}" != "TRUE" && "${run_cleanup}" != "FALSE" ]]; then
  echo "WARNING: invalid cleanup toggle '${run_cleanup}', using FALSE"
  run_cleanup="FALSE"
fi
# Allow overriding this path externally if the default module stack changes.
UA2U_HDF5_LIB_PATH=${UA2U_HDF5_LIB_PATH:-/apps/ops/test/spack-stack-nco-1.9/oneapi/2024.2.1/hdf5-1.14.3-umtw5lv/lib}
ua2u_timeout_sec=${POST_INCS_UA2U_TIMEOUT_SEC:-0}
if ! [[ "${ua2u_timeout_sec}" =~ ^[0-9]+$ ]]; then
  echo "WARNING: invalid POST_INCS_UA2U_TIMEOUT_SEC='${ua2u_timeout_sec}', disabling timeout"
  ua2u_timeout_sec=0
fi
post_work_root=${anldir}/post_process_increments_work
post_out_root=${anldir}/fv3lam_ready_restarts
mkdir -p "${post_work_root}" "${post_out_root}"

if [[ "${cleanup_only}" == "TRUE" ]]; then
  if [[ "${run_cleanup}" == "TRUE" ]]; then
    bash "${cleanup_script}" "${anldir}" "${baserundir}" "${YYYYMMDD}" "${HH}" "${clean_ensmean_retention_cycles:-24}"
  fi
  echo "POST-PROCESS-INCREMENTS cleanup-only task completed successfully!!!"
  exit 0
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

  rm -f "${workdir}/agrid_inc_jedi.fv_core.res.nc" "${workdir}/inc_jedi.fv_core.res.nc"
  cp -Lf "${incdir}/inc_jedi.fv_core.res.nc" "${workdir}/agrid_inc_jedi.fv_core.res.nc"
  ln -snf "${incdir}/inc_jedi.fv_tracer.res.nc" "${workdir}/inc_jedi.fv_tracer.res.nc"
  if [[ "${do_radar}" == "TRUE" && -f "${incdir}/inc_jedi.phy_data.nc" ]]; then
    ln -snf "${incdir}/inc_jedi.phy_data.nc" "${workdir}/inc_jedi.phy_data.nc"
  fi

  ln -snf "${FIX_GSI}/${PREDEF_GRID_NAME}/fv3_grid_spec" "${workdir}/fv3_grid_spec"
  cp -f "${EXECdir}/bin/rdas_ua2u.x" "${workdir}/rdas_ua2u.x"

  local ua2u_log="${workdir}/rdas_ua2u.log"
  {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Starting rdas_ua2u.x for ${memcharv0}"
    echo "******"
    echo "INPUT=${workdir}/agrid_inc_jedi.fv_core.res.nc"
    echo "OUTPUT=${workdir}/inc_jedi.fv_core.res.nc"
    echo "POST_INCS_UA2U_TIMEOUT_SEC=${ua2u_timeout_sec}"
  } > "${ua2u_log}"

  if (( ua2u_timeout_sec > 0 )) && command -v timeout >/dev/null 2>&1; then
    (
      cd "${workdir}"
      timeout "${ua2u_timeout_sec}" env LD_LIBRARY_PATH="${UA2U_HDF5_LIB_PATH}:${LD_LIBRARY_PATH:-}" \
        ./rdas_ua2u.x ua_update_u \
          --in_grid=fv3_grid_spec \
          --in_file=agrid_inc_jedi.fv_core.res.nc \
          --out_file=inc_jedi.fv_core.res.nc
    ) >> "${ua2u_log}" 2>&1
  else
    (
      cd "${workdir}"
      env LD_LIBRARY_PATH="${UA2U_HDF5_LIB_PATH}:${LD_LIBRARY_PATH:-}" \
        ./rdas_ua2u.x ua_update_u \
          --in_grid=fv3_grid_spec \
          --in_file=agrid_inc_jedi.fv_core.res.nc \
          --out_file=inc_jedi.fv_core.res.nc
    ) >> "${ua2u_log}" 2>&1
  fi
  local ua2u_rc=$?

  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] rdas_ua2u.x exit code=${ua2u_rc}" >> "${ua2u_log}"
  if (( ua2u_rc != 0 )); then
    echo "ERROR: rdas_ua2u.x failed for ${memcharv0}; see ${ua2u_log}"
    tail -n 50 "${ua2u_log}" || true
    return 1
  fi

  if [[ ! -s "${workdir}/inc_jedi.fv_core.res.nc" ]]; then
    echo "ERROR: inc_jedi.fv_core.res.nc missing or empty after rdas_ua2u.x for ${memcharv0}"
    tail -n 50 "${ua2u_log}" || true
    return 1
  fi

  (
    cd "${workdir}"
    module purge
    module load intel udunits szip hdf5 netcdf gsl nco
    "${apply_incs_script}" "${do_radar}" "${bkgdir}/fv_core.res.tile1.nc" "${bkgdir}/fv_tracer.res.tile1.nc" "${bkgdir}/phy_data.nc"
  )
  for f in fv_core_analysis.res.tile1.nc fv_tracer_analysis.res.tile1.nc; do
    if [[ ! -s "${workdir}/${f}" ]]; then
      echo "ERROR: Missing expected post-processed file for ${memcharv0}: ${workdir}/${f}"
      return 1
    fi
  done

  mv -f "${workdir}/fv_core_analysis.res.tile1.nc" "${outdir}/fv_core.res.tile1.nc"
  mv -f "${workdir}/fv_tracer_analysis.res.tile1.nc" "${outdir}/fv_tracer.res.tile1.nc"
  if [[ "${do_radar}" == "TRUE" && -f "${workdir}/phy_data_analysis.nc" ]]; then
    mv -f "${workdir}/phy_data_analysis.nc" "${outdir}/phy_data.nc"
  else
    cp -Lf "${bkgdir}/phy_data.nc" "${outdir}/phy_data.nc"
  fi
  cp -Lf "${bkgdir}/sfc_data.nc" "${outdir}/sfc_data.nc"
  cp -Lf "${bkgdir}/fv_srf_wnd.res.tile1.nc" "${outdir}/fv_srf_wnd.res.tile1.nc"
  cp -Lf "${bkgdir}/coupler.res" "${outdir}/coupler.res"

  echo "Completed post-processing for ${memcharv0}"
}

if [[ -z "${member_id}" ]]; then
  echo "ERROR: POST_INCS_MEMBER must be set for non-cleanup post-processing tasks"
  exit 1
fi
if ! [[ "${member_id}" =~ ^[0-9]+$ ]] || (( member_id < 1 || member_id > nens )); then
  echo "ERROR: invalid POST_INCS_MEMBER='${member_id}' for nens=${nens}"
  exit 1
fi
process_member "${member_id}"

echo "Post-processed FV3-LAM-ready restarts available under ${post_out_root}"

if [[ "${run_cleanup}" == "TRUE" ]]; then
  bash "${cleanup_script}" "${anldir}" "${baserundir}" "${YYYYMMDD}" "${HH}" "${clean_ensmean_retention_cycles:-24}"
fi

echo "POST-PROCESS-INCREMENTS completed successfully!!!"

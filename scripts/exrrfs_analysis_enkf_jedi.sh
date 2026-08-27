#!/bin/bash
################
### Settings ###
################

cd ${PBS_O_WORKDIR}
set -euox pipefail
echo ${envfile}
source "${envfile}"

nens=30
CRES="C3463"
output_ens="TRUE"
DO_ENKF_RADAR_REF="FALSE"
FIX_JEDI=${rrfsworkflow}/fix/jedi
FIX_GSI=${rrfsworkflow}/fix/gsi
PREDEF_GRID_NAME=RRFS_NA_3km
RDASAPP_DIR=${RDASApp}
PARM_IODACONV=${rrfsworkflow}/parm/iodaconv
PARMdir=${rrfsworkflow}/parm
USHdir=${rrfsworkflow}/ush
EXECdir=${rrfsworkflow}/exec
pgmout=${anldir}/pgm.log

#############################
### Begin executable code ###
#############################

cd ${anldir}
set +x
source ${rrfsworkflow}/versions/run.ver
module use ${rrfsworkflow}/modulefiles/tasks/wcoss2
module load run_enkfupdt_jedi.local
ulimit -s unlimited
ulimit -v unlimited
ulimit -a
set -euox pipefail
export OOPS_TRACE=0
export LD_LIBRARY_PATH="${RDASAPP_DIR}/build/lib64:${LD_LIBRARY_PATH}"
export FI_MR_CACHE_MONITOR=memhooks
export FI_MR_CACHE_MAX_COUNT=0
export MPICH_ENV_DISPLAY=1
export MPICH_OFI_STARTUP_CONNECT=1
export MPICH_OFI_VERBOSE=1
export MPICH_MPIIO_HINTS='*.tile1.nc:romio_cb_read=disable,*.sfc_data.nc:romio_cb_read=disable,*.phy_data.nc:romio_cb_read=disable,*.fv_*.res.nc:romio_cb_write=disable,*.sfc_data.nc:romio_cb_write=disable'
export OMP_STACKSIZE=500M
export OMP_NUM_THREADS=1 #${TPP_RUN_ANALYSIS}

# Compute depth
export ntasks=$( wc -l $PBS_NODEFILE | awk '{print $1}')
export ppn=$(grep -c $(head -1 $PBS_NODEFILE) $PBS_NODEFILE)
export depth=$(( 128 / $ppn ))
export nodes=$(( $ntasks / $ppn ))
APRUN="mpirun -n ${ntasks} -ppn ${ppn} --cpu-bind core --depth ${depth}"

#
#-----------------------------------------------------------------------
#
# Define fix path
#
#-----------------------------------------------------------------------
#
fixgriddir=$FIX_GSI/${PREDEF_GRID_NAME}
cp ${fixgriddir}/fv3_coupler.res    coupler.res
cp ${fixgriddir}/fv3_akbk           fv3_akbk
cp ${fixgriddir}/fv3_grid_spec      fv3_grid_spec

# update times in coupler.res to current cycle time
sed -i "s/yyyy/${YYYY}/" coupler.res
sed -i "s/mm/${MM}/"     coupler.res
sed -i "s/dd/${DD}/"     coupler.res
sed -i "s/hh/${HH}/"     coupler.res
YYYYMMDDHH=${YYYYMMDD}${HH}
CDATE=${YYYYMMDD}${HH}

#
#-----------------------------------------------------------------------
#
# Verify per-member input directories populated by the prep_getkf_mems task
#
#-----------------------------------------------------------------------
#
max_retries=5
retry_count=0
files_missing=true

while [ "$files_missing" = true ] && [ $retry_count -lt $max_retries ]; do
  files_missing=false
  for imem in $(seq 1 $nens); do
    memcharv0="mem"$(printf %03i $imem)
    if [ ! -f "data/inputs/${memcharv0}/phy_data.nc" ]; then
      echo "  WARNING: data/inputs/${memcharv0}/phy_data.nc not accessible yet (attempt $((retry_count+1))/$max_retries)"
      files_missing=true
    fi
  done

  if [ "$files_missing" = true ]; then
    if [ $retry_count -lt $((max_retries-1)) ]; then
      echo "  Waiting 10 seconds before retrying..."
      sleep 10
    else
      echo "ERROR: Input files still not accessible after $max_retries attempts. Aborting."
      exit 1
    fi
  fi
  retry_count=$((retry_count+1))
done

echo "All input files verified successfully!"

#
#-----------------------------------------------------------------------
#
# Pre-process the phy_data for reflectivity assimilation
#
#-----------------------------------------------------------------------
#
echo "Extracting ref_f3d and running prep_phydata_dbz.py in parallel for all members..."
for imem in $(seq 1 $nens); do
  memcharv0="mem"$(printf %03i $imem)
  echo "ncks -O -v ref_f3d data/inputs/${memcharv0}/phy_data.nc data/inputs/${memcharv0}/phy_data.nc_prepdbz > prep_phydata_${memcharv0}.log 2>&1 && python prep_phydata_dbz.py data/inputs/${memcharv0}/phy_data.nc_prepdbz >> prep_phydata_${memcharv0}.log 2>&1"
done | parallel -j 30 --halt soon,fail=1
echo "phy_data.nc preprocessing completed successfully!!!"

# View timing for all members
echo "Timing summary:"
grep "Total time" prep_phydata_*.log

#
#-----------------------------------------------------------------------
#
# JCB - JEDI Configuration Builder
#
#-----------------------------------------------------------------------
#
# pyioda libraries
shopt -s nullglob
dirs=("$RDASAPP_DIR"/build/lib/python3.*)
PYIODALIB=${dirs[0]}
WXFLOWLIB=${RDASAPP_DIR}/sorc/wxflow/src
JCBLIB=${RDASAPP_DIR}/sorc/jcb/src
export PYTHONPATH="${JCBLIB}:${WXFLOWLIB}:${PYIODALIB}:${PYTHONPATH}"

cp ${getkfyaml} .
cp ${fixsimple}/gsd*txt .
cp ${fixsimple}/../util/run_jcb.py .
JCB_CONFIG_ENKF=$(basename $getkfyaml)

#sed - rdas-atmosphere-templates.yaml
# set other placeholders
WIN_ISO="${YYYY}-${MM}-${DD}T${HH}:00:00Z"
WIN_PREFIX="${YYYY}${MM}${DD}.${HH}0000."
SUFFIX="${CDATE}"
jedi_yaml="jedienkf.yaml"

# do replacements
sed -i \
  -e "s|@ATMOSPHERE_BACKGROUND_TIME_ISO@|'${WIN_ISO}'|" \
  -e "s|@ATMOSPHERE_BACKGROUND_TIME_PREFIX@|'${WIN_PREFIX}'|" \
  -e "s|@SUFFIX@|${SUFFIX}|g" \
  ${JCB_CONFIG_ENKF}

python run_jcb.py "${YYYYMMDDHH}" "${JCB_CONFIG_ENKF}" "${jedi_yaml}"

#
#-----------------------------------------------------------------------
#
# Perform some YAML post processing that JCB cannot handle yet
#
#-----------------------------------------------------------------------
#

# Since JCB does not support OSDF yet, do a sed replacement to turn these on
sed -i 's/^ *distribution:$/      use data frame container: true\
      redistribution:/' "${jedi_yaml}"

# JCB does not set linear observer so we need to change that
sed -i 's/use linear observer: false/use linear observer: true/' "${jedi_yaml}"
sed -i 's/do test prints: true/do test prints: false/' "${jedi_yaml}"

# Turn off all jdiag outputs
sed -i '/^[[:space:]]*obsdataout:/,+6 s/^/#/' "${jedi_yaml}"

#
#-----------------------------------------------------------------------
#
# link observation files
# copy observation files to working directory
#
#-----------------------------------------------------------------------
#
mkdir -p data/obs
cp ${bufrdir}/ioda_*.nc data/obs/.
cp ${mrmsdir}/00/ioda_mrms_${YYYYMMDD}${HH}_00.nc4 data/obs/ioda_mrms_refl.nc

#
#-----------------------------------------------------------------------
#
# Copy in other fix files needed
#
#-----------------------------------------------------------------------
#

mkdir -p INPUT
FIXLAM=${rrfsworkflow}/fix/lam/RRFS_NA_3km
ln -snf ${FIXLAM}/${CRES}_grid.tile7.halo3.nc INPUT/${CRES}_grid.tile7.halo3.nc
ln -snf ${FIXLAM}/${CRES}_grid.tile7.halo3.nc INPUT/${CRES}_grid.tile7.nc
ln -snf ${FIXLAM}/${CRES}_mosaic.halo3.nc INPUT/grid_spec.nc
cp ${FIX_JEDI}/dynamics_lam_cmaq.yaml .
cp ${FIX_JEDI}/field_table .
cp ${FIX_JEDI}/${PREDEF_GRID_NAME}/fmsmpp.nml .
#cp ${FIX_JEDI}/${PREDEF_GRID_NAME}/input_lam* .
cp ${fixsimple}/input_lam* .

#
#-----------------------------------------------------------------------
# Create the output directories for the analyses (no more restriping)
#-----------------------------------------------------------------------
#


if [ ${output_ens} == "TRUE" ]; then

  for imem in  $(seq 1 $nens); do
    memcharv0="mem"$(printf %03i $imem)
    mkdir ${memcharv0}
  done

fi

#
#-----------------------------------------------------------------------
#
# Run JEDI-based EnKF
#
#-----------------------------------------------------------------------
#
#export OOPS_TRACE=1
#export OOPS_DEBUG=1
export OMP_NUM_THREADS=1
export pgm="fv3jedi_letkf.x"
#jedi_exec="${EXECdir}/bin/${pgm}"
jedi_exec="${RDASAPP_DIR}/build/bin/${pgm}"
cp "${jedi_exec}" "${anldir}/${pgm}"

. prep_step

${APRUN} ./$pgm jedienkf.yaml >>$pgmout 2>errfile
export err=$?; err_chk
cp $pgmout ${COMOUT}/rrfs.${YYYYMMDDHH}.jediout.tm00
#cp ${JCB_CONFIG_ENKF_OBSERVER} ${COMOUT}
#cp jedienkf_observer.yaml ${COMOUT}/jedienkf_observer.yaml
mv errfile errfile_jedi_enkf

# NOTE: increment/rundir cleanup used to happen here, but this task is no
# longer the last one in the workflow -- the exrrfs_postproc_getkf_mems.sh
# (D-grid wind conversion) and exrrfs_postproc_getkf_cleanup.sh tasks now run
# afterward, so cleanup has moved to exrrfs_postproc_getkf_cleanup.sh.

echo "JEDI-EnKF PROCESS completed successfully!!!"

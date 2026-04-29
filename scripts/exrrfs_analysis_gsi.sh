#!/bin/bash

################
### Settings ###
################

cd ${PBS_O_WORKDIR}
set -euox pipefail
echo ${envfile}
source "${envfile}"

cd ${verifdir}
ob_type="conv" # verification type
gsi_type="OBSERVER"
mem_type="MEAN"
CRES="C3463"
CYCLE_TYPE="prod"
DO_ENKF_RADAR_REF="FALSE"
DO_GLM_FED_DA="FALSE"
DO_RADDA="FALSE"
DO_GSIDIAG_OFFLINE="FALSE"
NUM_ENS_MEMBERS=30
FIX_GSI=${rrfsworkflow}/fix/gsi
PREDEF_GRID_NAME=RRFS_NA_3km
PARMdir=${rrfsworkflow}/parm
USHdir=${rrfsworkflow}/ush
EXECdir=${rrfsworkflow}/exec
COMOUT="."
pgmout=${verifdir}/pgm.log

# Some fix namelists
HYBENSMEM_NMIN="66"
ANAVINFO_FN="anavinfo.rrfs"
ANAVINFO_SD_FN="anavinfo.rrfs_sd"
ANAVINFO_DBZ_FN="anavinfo.rrfs_dbz"
ANAVINFO_CONV_DBZ_FN="anavinfo.rrfs_conv_dbz"
ANAVINFO_CONV_DBZ_FED_FN="anavinfo.rrfs_conv_dbz_fed"
ANAVINFO_DBZ_FED_FN="anavinfo.rrfs_dbz_fed"
ENKF_ANAVINFO_FN="anavinfo.rrfs"
ENKF_ANAVINFO_DBZ_FN="anavinfo.enkf.rrfs_dbz"
CONVINFO_FN="convinfo.rrfs"
CONVINFO_SD_FN="convinfo.rrfs_sd"
BERROR_FN="rrfs_glb_berror.l127y770.f77" #under $FIX_GSI
BERROR_SD_FN="berror.rrfs_sd" # for test only
OBERROR_FN="errtable.rrfs"
HYBENSINFO_FN="hybens_info.rrfs"
AIRCRAFT_REJECT="/lfs/h3/emc/eib/noscrub/emc.lam/rrfs-stagedata//amdar_reject_lists"
SFCOBS_USELIST="/lfs/h3/emc/eib/noscrub/emc.lam/rrfs-stagedata//mesonet_uselists"
FIX_CRTM="/apps/test/hpc-stack/i-19.1.3.304__m-8.1.12__h-1.14.0__n-4.9.2__p-2.5.10__e-8.4.2/intel-19.1.3.304/cray-mpich-8.1.12/crtm/2.4.0/fix"

# Defaults for building GSI namelist

# &SETUP  and &BKGERR
niter1="50"
niter2="50"
l_obsprvdiag=".false."
diag_radardbz=".true."
diag_fed=".false."
if_model_fed=".false."
innov_use_model_fed=".false."
write_diag_2=".false."
bkgerr_vs="1.0"
bkgerr_hzscl="0.7,1.4,2.80"   #no trailing ,
usenewgfsberror=".true."
netcdf_diag=".true."
binary_diag=".false."

# &HYBRID_ENSEMBLE
l_both_fv3sar_gfs_ens=".false."
weight_ens_gfs="1.0"
weight_ens_fv3sar="1.0"
readin_localization=".false."     #if true, it overwrites the "beta1_inv/ens_h/ens_v" setting
beta1_inv="0.15"                 #beata_inv is 1-ensemble_wgt
ens_h="110"                      #horizontal localization scale of "Gaussian function=exp(-0.5)" for EnVar (km)
ens_v="3"                        #vertical localization scale of "Gaussian function=exp(-0.5)" for EnVar (positive:grids, negative:lnp)
ens_h_radardbz="17.80098"         #horizontal localization scale of "Gaussian function=exp(-0.5)" for radardbz EnVar (km)
ens_v_radardbz="-0.30125"        #vertical localization scale of "Gaussian function=exp(-0.5)" for radardbz EnVar (positive:grids, negative:lnp)
nsclgrp="1"
ngvarloc="1"
r_ensloccov4tim="1.0"
r_ensloccov4var="1.0"
r_ensloccov4scl="1.0"
regional_ensemble_option="5"     #1 for GDAS ; 5 for FV3LAM ensemble
grid_ratio_fv3="2.0"             #fv3 resolution 3km, so analysis=3*2=6km
grid_ratio_ens="3"               #if analysis is 3km, then ensemble=3*3=9km. GDAS ensemble is 20km
i_en_perts_io="1"                #0 or 1: original file   3: pre-processed ensembles
q_hyb_ens=".false."
ens_fast_read=".false."
CORRLENGTH="300"                 #horizontal localization scale of "Gaspari-Cohn function=0" for EnKF (km)
LNSIGCUTOFF="0.5"                #vertical localization scale of "Gaspari-Cohn function=0" for EnKF (lnp)
CORRLENGTH_radardbz="18"         #horizontal localization scale of "Gaspari-Cohn function=0" for radardbz EnKF (km)
LNSIGCUTOFF_radardbz="0.5"       #vertical localization scale of "Gaspari-Cohn function=0" for radardbz EnKF (lnp)
assign_vdl_nml=".false."
vdl_scale="0"

# &RAPIDREFRESH_CLDSURF
l_PBL_pseudo_SurfobsT=".false."
l_PBL_pseudo_SurfobsQ=".false."
i_use_2mQ4B="0"
i_use_2mT4B="0"
i_T_Q_adjust="1"
l_rtma3d=".false."
i_precip_vertical_check="0"
l_cld_uncertainty=".false."
#  &CHEM
laeroana_fv3smoke=".false."
berror_fv3_cmaq_regional=".false."
berror_fv3_sd_regional=".false."

#
#-----------------------------------------------------------------------
#
# Set environment
#
#-----------------------------------------------------------------------
#

#############################
### Begin executable code ###
#############################

set +x
source ${rrfsworkflow}/versions/run.ver
module use ${rrfsworkflow}/modulefiles/tasks/wcoss2
module load run_analysis_gsi.local
ulimit -s unlimited
ulimit -a
set -euox pipefail
export FI_OFI_RXM_SAR_LIMIT=3145728
export OMP_STACKSIZE=500M
export OMP_NUM_THREADS=8
APRUN="mpiexec -n $(( PBS_NP * 1 )) -ppn ${PBS_NP} --cpu-bind core --depth ${OMP_NUM_THREADS}"
APRUN_UA="mpiexec -n $(( PBS_NP * 1 )) -ppn ${PBS_NP} --cpu-bind core --depth 1"
APRUN_MEAN="mpiexec -n $(( PBS_NP * PBS_NUM_NODES )) -ppn ${PBS_NP} --cpu-bind core --depth 1"

#
#-----------------------------------------------------------------------
#
# Extract from CDATE the starting year, month, day, and hour of the
# forecast.  These are needed below for various operations.
#
#-----------------------------------------------------------------------
#
YYYYMMDDHH=${YYYYMMDD}${HH}
CDATE=${YYYYMMDD}${HH}
START_DATE=$(echo "${CDATE}" | sed 's/\([[:digit:]]\{2\}\)$/ \1/')
JJJ=$(date +%j -d "${START_DATE}")

#
# YYYY-MM-DD_meso_uselist.txt and YYYYMMDD_rejects.txt:
# both contain past 7 day OmB averages till ~YYYYMMDD_23:59:59 UTC
# So they are to be used by next day cycles
MESO_USELIST_FN=$(date +%Y-%m-%d -d "${START_DATE} -1 day")_meso_uselist.txt
AIR_REJECT_FN=$(date +%Y%m%d -d "${START_DATE} -1 day")_rejects.txt

#
#-----------------------------------------------------------------------
#
# define fix and background path
#
#-----------------------------------------------------------------------
#
fixgriddir=$FIX_GSI/${PREDEF_GRID_NAME}
bkpath=${anldir}
BKTYPE=0
regional_ensemble_option=5

#
#-----------------------------------------------------------------------
#
# set default values for namelist
#
#-----------------------------------------------------------------------
#
ifsatbufr=.false.
ifsoilnudge=.false.
ifhyb=.false.
miter=2
niter1=50
niter2=50
lread_obs_save=.false.
lread_obs_skip=.false.
if_model_dbz=.false.
nummem_gfs=0
nummem_fv3sar=0
anav_type=${ob_type}
i_use_2mQ4B=2
i_use_2mT4B=1

# Determine if hybrid option is available
memname='atmf009'

if [ ${regional_ensemble_option:-1} -eq 5 ]  && [ ${BKTYPE} != 1  ]; then
  if [ ${l_both_fv3sar_gfs_ens} = ".true." ]; then
    nummem_gfs=$(more filelist03 | wc -l)
    nummem_gfs=$((nummem_gfs - 3 ))
  fi
  nummem_fv3sar=$NUM_ENS_MEMBERS
  nummem=`expr ${nummem_gfs} + ${nummem_fv3sar}`
  echo "Do hybrid with FV3LAM ensemble"
  ifhyb=.true.
  echo " Cycle ${YYYYMMDDHH}: GSI hybrid uses FV3LAM ensemble with n_ens=${nummem}"
  grid_ratio_ens="1"
  ens_fast_read=.false.
else
  nummem_gfs=$(more filelist03 | wc -l)
  nummem_gfs=$((nummem_gfs - 3 ))
  nummem=${nummem_gfs}
  if [[ ${nummem} -ge ${HYBENSMEM_NMIN} ]]; then
    echo "Do hybrid with ${memname}"
    ifhyb=.true.
    echo " Cycle ${YYYYMMDDHH}: GSI hybrid uses ${memname} with n_ens=${nummem}"
  else
    echo " Cycle ${YYYYMMDDHH}: GSI does pure 3DVAR."
    echo " Hybrid needs at least ${HYBENSMEM_NMIN} ${memname} ensembles, only ${nummem} available"
  fi
  if [ "${anav_type}" = "conv_dbz" ]; then
    anav_type="conv"
  fi
fi

#
#-----------------------------------------------------------------------
#
# Post-process the JEDI increments
#    1) Convert wind increments from D-grid to A-grid
#    2) Apply increments to the background fields
#
#-----------------------------------------------------------------------
#

# Copy or link in the increment files
ln -sf ${bkpath}/inc_jedi_mean.fv_core.res.nc          ./inc_jedi_mean.fv_core.res.nc # will be renamed once we add d-grid winds
ln -sf ${bkpath}/inc_jedi_mean.fv_tracer.res.nc        ./inc_jedi.fv_tracer.res.nc

# Convert a to d grid winds
# This will create the new inc_jedi.fv_core.res.nc file
export pgm="rdas_ua2u.x"
ua2u_exec="${EXECdir}/bin/${pgm}"
cp "${ua2u_exec}" ./${pgm}
ln -snf ${fixgriddir}/fv3_grid_spec  fv3_grid_spec
LD_LIBRARY_PATH="/apps/ops/test/spack-stack-nco-1.9/oneapi/2024.2.1/hdf5-1.14.3-umtw5lv/lib:${LD_LIBRARY_PATH}" \
  ${APRUN_UA} ./${pgm} ua_update_u --in_grid=fv3_grid_spec --in_file=inc_jedi_mean.fv_core.res.nc --out_file=inc_jedi.fv_core.res.nc >>"$pgmout" 2>errfile
mv errfile errfile_ua2u
rm inc_jedi_mean.fv_core.res.nc

# Compute the full ensemble mean background using ens_mean_recenter_P2DIO.exe
for imem in $(seq 1 $NUM_ENS_MEMBERS); do
  memberstring=$(printf "%03d" $imem)
  bkmempath=${anldir}/data/inputs/mem${memberstring}
  ln -sf ${bkmempath}/fv_core.res.tile1.nc   ./fv3sar_tile1_mem${memberstring}_dynvar
  ln -sf ${bkmempath}/fv_tracer.res.tile1.nc ./fv3sar_tile1_mem${memberstring}_tracer
  ln -sf ${bkmempath}/sfc_data.nc            ./fv3sar_tile1_mem${memberstring}_sfcvar
  if [ $imem -eq 1 ]; then
    # Prepare the data structure for ensemble mean output
    cp -f ${bkmempath}/fv_core.res.tile1.nc  fv3sar_tile1_dynvar
    cp -f ${bkmempath}/fv_tracer.res.tile1.nc fv3sar_tile1_tracer
    cp -f ${bkmempath}/sfc_data.nc            fv3sar_tile1_sfcvar
  fi
done

# Create namelist.ens for ens_mean_recenter_P2DIO.exe
cat << EOF > namelist.ens
&setup
  fv3_io_layout_y=1,
  ens_size=${NUM_ENS_MEMBERS},
  filebase='fv3sar_tile1'
  filetail(1)='dynvar'
  filetail(2)='tracer'
  filetail(3)='sfcvar'
  numvar(1)=9
  numvar(2)=13
  numvar(3)=10
  varlist(1)="u v W DZ T delp phis ua va"
  varlist(2)="sphum liq_wat ice_wat rainwat snowwat graupel water_nc ice_nc rain_nc o3mr liq_aero ice_aero sgs_tke"
  varlist(3)="t2m q2m f10m tslb smois tsea tsfc tsfcl emis_ice emis_lnd"
  l_write_mean=.true.
  l_recenter=.false.
/
EOF

# Run ens_mean_recenter_P2DIO.exe to compute the full ensemble mean
export pgm="ens_mean_recenter_P2DIO.exe"
${APRUN_MEAN} ${EXECdir}/$pgm < namelist.ens >>$pgmout 2>errfile
if [ $? -ne 0 ]; then
  echo "ERROR: Failed to compute ensemble mean with ${pgm}"
  cat errfile
  exit 7
fi
mv errfile errfile_ensmean

# Remove checksums from ensemble mean files (they will be recalculated)
for files in fv3sar_tile1_dynvar fv3sar_tile1_sfcvar fv3sar_tile1_tracer; do
  ncatted -a checksum,,d,, $files
done

# Rename the ensemble mean files so we can apply the increments to them
mv fv3sar_tile1_dynvar fv3_dynvars
mv fv3sar_tile1_tracer fv3_tracer
mv fv3sar_tile1_sfcvar fv3_sfcdata

# Now apply the increments to the background file with Python/xarray
dynfile=fv3_dynvars
trafile=fv3_tracer
phyfile=fv3_phyvars
set +x
module purge
module use ${RDASApp}/modulefiles
module load RDAS/wcoss2.intel
set -x
if ( ! time ( python3 -u ./apply_jedi_incs.py "FALSE" ${dynfile} ${trafile} ${phyfile}) ); then
  echo "Failed applying JEDI increments"
  exit 6
else
  echo "Successfully applied JEDI increments"
  mv fv_core_analysis.res.tile1.nc ${dynfile}
  mv fv_tracer_analysis.res.tile1.nc ${trafile}
fi

# Restore the GSI modules
set +x
module reset
source ${rrfsworkflow}/versions/run.ver
module use ${rrfsworkflow}/modulefiles/tasks/wcoss2
module load run_analysis_gsi.local
set -x

#
#-----------------------------------------------------------------------
#
# link or copy background and grib configuration files
#
#  Using ncks to add phis (terrain) into cold start input background.
#           it is better to change GSI to use the terrain from fix file.
#  Adding radar_tten array to fv3_tracer. Should remove this after add this array in
#           radar_tten converting code.
#-----------------------------------------------------------------------
#
IO_LAYOUT_X="1"
IO_LAYOUT_Y="1"
n_iolayouty=$(($IO_LAYOUT_Y-1))
list_iolayout=$(seq 0 $n_iolayouty)
ln -snf ${fixgriddir}/fv3_akbk  fv3_akbk
ln -snf ${bkpath}/data/inputs/mem001/phy_data.nc fv3_phyvars # is this actually used? or is cref recomputed?
fv3lam_bg_type=0

# update times in coupler.res to current cycle time
cp ${fixgriddir}/fv3_coupler.res  coupler.res
sed -i "s/yyyy/${YYYY}/" coupler.res
sed -i "s/mm/${MM}/"     coupler.res
sed -i "s/dd/${DD}/"     coupler.res
sed -i "s/hh/${HH}/"     coupler.res
#
#-----------------------------------------------------------------------
#
# link observation files
# copy observation files to working directory 
#
#-----------------------------------------------------------------------

OBSTYPE_SOURCE="rrfs"
OBSPATH=${obsbase}
SUBH=""
obs_source=${OBSTYPE_SOURCE}
obsfileprefix=${obs_source}
obspath_tmp=${OBSPATH}/${obs_source}.${YYYYMMDD}

obs_files_source[0]=${obspath_tmp}/${obsfileprefix}.t${HH}${SUBH}z.prepbufr.tm00
obs_files_target[0]=prepbufr
obs_number=${#obs_files_source[@]}
obs_files_source[${obs_number}]=${obspath_tmp}/${obsfileprefix}.t${HH}${SUBH}z.satwnd.tm00.bufr_d
obs_files_target[${obs_number}]=satwndbufr
#obs_number=${#obs_files_source[@]}
#obs_files_source[${obs_number}]=${obspath_tmp}/${obsfileprefix}.t${HH}${SUBH}z.nexrad.tm00.bufr_d
#obs_files_target[${obs_number}]=l2rwbufr

if [ "${anav_type}" = "conv_dbz" ]; then
  obs_number=${#obs_files_source[@]}
  if [ "${CYCLE_TYPE}" = "spinup" ]; then
    obs_files_source[${obs_number}]=${cycle_dir}/process_radarref_spinup/00/Gridded_ref.nc
  else
    obs_files_source[${obs_number}]=${cycle_dir}/process_radarref/00/Gridded_ref.nc
  fi
  obs_files_target[${obs_number}]=dbzobs.nc
  if [ "${DO_GLM_FED_DA}" = "TRUE" ]; then
    obs_number=${#obs_files_source[@]}
    if [ "${CYCLE_TYPE}" = "spinup" ]; then
      obs_files_source[${obs_number}]=${cycle_dir}/process_glmfed_spinup/fedobs.nc
    else
      obs_files_source[${obs_number}]=${cycle_dir}/process_glmfed/fedobs.nc
    fi
    obs_files_target[${obs_number}]=fedobs.nc
  fi
fi

if [ "${DO_ENKF_RADAR_REF}" = "TRUE" ]; then
  obs_number=${#obs_files_source[@]}
  if [ "${CYCLE_TYPE}" = "spinup" ]; then
    obs_files_source[${obs_number}]=${cycle_dir}/process_radarref_spinup_enkf/00/Gridded_ref.nc
  else
    obs_files_source[${obs_number}]=${cycle_dir}/process_radarref_enkf/00/Gridded_ref.nc
  fi
  obs_files_target[${obs_number}]=dbzobs.nc
  if [ "${DO_GLM_FED_DA}" = "TRUE" ]; then
    obs_number=${#obs_files_source[@]}
    obs_files_source[${obs_number}]=${cycle_dir}/process_glmfed_enkf/fedobs.nc
    obs_files_target[${obs_number}]=fedobs.nc
  fi
fi

obs_number=${#obs_files_source[@]}
for (( i=0; i<${obs_number}; i++ ));
do
  obs_file=${obs_files_source[$i]}
  obs_file_t=${obs_files_target[$i]}
  if [ -r "${obs_file}" ]; then
    ln -s "${obs_file}" "${obs_file_t}"
  else
    echo "WARNING: ${obs_file} does not exist!"
  fi
done

#
#-----------------------------------------------------------------------
#
# Create links to fix files in the FIXgsi directory.
# Set fixed files
#   berror   = forecast model background error statistics
#   specoef  = CRTM spectral coefficients
#   trncoef  = CRTM transmittance coefficients
#   emiscoef = CRTM coefficients for IR sea surface emissivity model
#   aerocoef = CRTM coefficients for aerosol effects
#   cldcoef  = CRTM coefficients for cloud effects
#   satinfo  = text file with information about assimilation of brightness temperatures
#   satangl  = angle dependent bias correction file (fixed in time)
#   pcpinfo  = text file with information about assimilation of prepcipitation rates
#   ozinfo   = text file with information about assimilation of ozone data
#   errtable = text file with obs error for conventional data (regional only)
#   convinfo = text file with information about assimilation of conventional data
#   bufrtable= text file ONLY needed for single obs test (oneobstest=.true.)
#   bftab_sst= bufr table for sst ONLY needed for sst retrieval (retrieval=.true.)
#
#-----------------------------------------------------------------------
#
ANAVINFO=${FIX_GSI}/${ANAVINFO_FN}
if [ "${DO_ENKF_RADAR_REF}" = "TRUE" ]; then
  ANAVINFO=${FIX_GSI}/${ANAVINFO_DBZ_FN}
  diag_radardbz=.true.
  if [ "${DO_GLM_FED_DA}" = "TRUE" ]; then
    diag_fed=.true.
  fi
  beta1_inv=0.0
  if_model_dbz=.true.
fi
naensloc=`expr ${nsclgrp} \* ${ngvarloc} + ${nsclgrp} - 1`
if [ ${assign_vdl_nml} = ".true." ]; then
  nsclgrp=`expr ${nsclgrp} \* ${ngvarloc}`
  ngvarloc=1
fi
CONVINFO=${FIX_GSI}/${CONVINFO_FN}
HYBENSINFO=${FIX_GSI}/${HYBENSINFO_FN}
OBERROR=${FIX_GSI}/${OBERROR_FN}
BERROR=${FIX_GSI}/${BERROR_FN}
SATINFO=${FIX_GSI}/global_satinfo.txt
OZINFO=${FIX_GSI}/global_ozinfo.txt
PCPINFO=${FIX_GSI}/global_pcpinfo.txt
ATMS_BEAMWIDTH=${FIX_GSI}/atms_beamwidth.txt

# Fixed fields
cp ${ANAVINFO} anavinfo
cp ${BERROR}   berror_stats
cp $SATINFO    satinfo
cp $CONVINFO   convinfo
cp $OZINFO     ozinfo
cp $PCPINFO    pcpinfo
cp $OBERROR    errtable
cp $ATMS_BEAMWIDTH atms_beamwidth.txt
cp ${HYBENSINFO} hybens_info

# Get surface observation provider list
if [ -r ${FIX_GSI}/gsd_sfcobs_provider.txt ]; then
  cp ${FIX_GSI}/gsd_sfcobs_provider.txt gsd_sfcobs_provider.txt
else
  echo "WARNING: gsd surface observation provider does not exist!"
fi

# Get aircraft reject list
for reject_list in "${AIRCRAFT_REJECT}/current_bad_aircraft.txt" \
                   "${AIRCRAFT_REJECT}/${AIR_REJECT_FN}" \
                   "${FIX_GSI}/current_bad_aircraft.txt"
do
  if [ -r $reject_list ]; then
    cp $reject_list current_bad_aircraft
    echo "Use aircraft reject list: $reject_list "
    break
  fi
done
if [ ! -r $reject_list ] ; then
  echo "WARNING: gsd aircraft reject list does not exist!"
fi

# Get mesonet uselist
gsd_sfcobs_uselist="gsd_sfcobs_uselist.txt"
for use_list in "${SFCOBS_USELIST}/current_mesonet_uselist.txt" \
                "${SFCOBS_USELIST}/${MESO_USELIST_FN}"      \
                "${SFCOBS_USELIST}/gsd_sfcobs_uselist.txt"  \
                "${FIX_GSI}/gsd_sfcobs_uselist.txt"
do
  if [ -r $use_list ] ; then
    cp $use_list  $gsd_sfcobs_uselist
    echo "Use surface obs uselist: $use_list "
    break
  fi
done
if [ ! -r $use_list ] ; then
  echo "WARNING: gsd surface observation uselist does not exist!"
fi
#
#-----------------------------------------------------------------------
#
# CRTM Spectral and Transmittance coefficients
# set coefficient under crtm_coeffs_path='./crtm_coeffs/',
#-----------------------------------------------------------------------
#
CRTMFIX=${FIX_CRTM}
emiscoef_IRwater=${CRTMFIX}/Nalli.IRwater.EmisCoeff.bin
emiscoef_IRice=${CRTMFIX}/NPOESS.IRice.EmisCoeff.bin
emiscoef_IRland=${CRTMFIX}/NPOESS.IRland.EmisCoeff.bin
emiscoef_IRsnow=${CRTMFIX}/NPOESS.IRsnow.EmisCoeff.bin
emiscoef_VISice=${CRTMFIX}/NPOESS.VISice.EmisCoeff.bin
emiscoef_VISland=${CRTMFIX}/NPOESS.VISland.EmisCoeff.bin
emiscoef_VISsnow=${CRTMFIX}/NPOESS.VISsnow.EmisCoeff.bin
emiscoef_VISwater=${CRTMFIX}/NPOESS.VISwater.EmisCoeff.bin
emiscoef_MWwater=${CRTMFIX}/FASTEM6.MWwater.EmisCoeff.bin
aercoef=${CRTMFIX}/AerosolCoeff.bin
cldcoef=${CRTMFIX}/CloudCoeff.bin

mkdir -p crtm_coeffs
ln -s ${emiscoef_IRwater} ./crtm_coeffs/Nalli.IRwater.EmisCoeff.bin
ln -s $emiscoef_IRice ./crtm_coeffs/NPOESS.IRice.EmisCoeff.bin
ln -s $emiscoef_IRsnow ./crtm_coeffs/NPOESS.IRsnow.EmisCoeff.bin
ln -s $emiscoef_IRland ./crtm_coeffs/NPOESS.IRland.EmisCoeff.bin
ln -s $emiscoef_VISice ./crtm_coeffs/NPOESS.VISice.EmisCoeff.bin
ln -s $emiscoef_VISland ./crtm_coeffs/NPOESS.VISland.EmisCoeff.bin
ln -s $emiscoef_VISsnow ./crtm_coeffs/NPOESS.VISsnow.EmisCoeff.bin
ln -s $emiscoef_VISwater ./crtm_coeffs/NPOESS.VISwater.EmisCoeff.bin
ln -s $emiscoef_MWwater ./crtm_coeffs/FASTEM6.MWwater.EmisCoeff.bin
ln -s $aercoef  ./crtm_coeffs/AerosolCoeff.bin
ln -s $cldcoef  ./crtm_coeffs/CloudCoeff.bin

# Copy CRTM coefficient files based on entries in satinfo file
for file in $(awk '{if($1!~"!"){print $1}}' ./satinfo | sort | uniq) ;do
   ln -s ${CRTMFIX}/${file}.SpcCoeff.bin ./crtm_coeffs/.
   ln -s ${CRTMFIX}/${file}.TauCoeff.bin ./crtm_coeffs/.
done

#-----------------------------------------------------------------------
#
# cycling radiance bias corretion files
#
#-----------------------------------------------------------------------
if [ "${DO_RADDA}" = "TRUE" ]; then
  if [ "${CYCLE_TYPE}" = "spinup" ]; then
    echo "spin up cycle"
    spinup_or_prod_rrfs=spinup
    for cyc_start in "${CYCL_HRS_SPINSTART[@]}"; do
      if [ ${HH} -eq ${cyc_start} ]; then
        spinup_or_prod_rrfs=prod 
      fi
    done
  else 
    echo " product cycle"
    spinup_or_prod_rrfs=prod
    for cyc_start in "${CYCL_HRS_PRODSTART[@]}"; do
      if [ ${HH} -eq ${cyc_start} ]; then
        spinup_or_prod_rrfs=spinup      
      fi 
    done
  fi

  satcounter=1
  maxcounter=240
  while [ $satcounter -lt $maxcounter ]; do
    SAT_TIME=`date +"%Y%m%d%H" -d "${START_DATE}  ${satcounter} hours ago"`
    echo $SAT_TIME
	
    if [ "${DO_ENS_RADDA}" = "TRUE" ]; then			
      # For EnKF.  Note, EnKF does not need radstat file
      if [ -r ${satbias_dir}_ensmean/rrfs.${spinup_or_prod_rrfs}.${SAT_TIME}_satbias ]; then
        echo " using satellite bias files from ${SAT_TIME}" 
        cp ${satbias_dir}_ensmean/rrfs.${spinup_or_prod_rrfs}.${SAT_TIME}_satbias ./satbias_in
        cp ${satbias_dir}_ensmean/rrfs.${spinup_or_prod_rrfs}.${SAT_TIME}_satbias_pc ./satbias_pc
	    
        break
      fi
	  
    else
      # For EnVar
      if [ -r ${satbias_dir}/rrfs.${spinup_or_prod_rrfs}.${SAT_TIME}_satbias ]; then
        echo " using satellite bias files from ${satbias_dir} ${spinup_or_prod_rrfs}.${SAT_TIME}"
        cp ${satbias_dir}/rrfs.${spinup_or_prod_rrfs}.${SAT_TIME}_satbias ./satbias_in
        cp ${satbias_dir}/rrfs.${spinup_or_prod_rrfs}.${SAT_TIME}_satbias_pc ./satbias_pc
        if [ -r ${satbias_dir}/rrfs.${spinup_or_prod_rrfs}.${SAT_TIME}_radstat ]; then
           cp ${satbias_dir}/rrfs.${spinup_or_prod_rrfs}.${SAT_TIME}_radstat ./radstat.rrfs
        fi

        break
      fi
	
    fi
    satcounter=` expr $satcounter + 1 `
  done

  ## if satbias files (go back to previous 10 dyas) are not available from ${satbias_dir}, use satbias files from the ${FIX_GSI} 
  ## now check if there are satbias files in continue cycle data space
  if [ $satcounter -eq $maxcounter ]; then
    satcounter=1
    maxcounter=240
    satbias_dir_cont=${CONT_CYCLE_DATA_ROOT}/satbias
    while [ $satcounter -lt $maxcounter ]; do
      SAT_TIME=`date +"%Y%m%d%H" -d "${START_DATE}  ${satcounter} hours ago"`
      echo $SAT_TIME
	
      if [ "${DO_ENS_RADDA}" = "TRUE" ]; then			
        # For EnKF.  Note, EnKF does not need radstat file
        if [ -r ${satbias_dir_cont}_ensmean/rrfs.${spinup_or_prod_rrfs}.${SAT_TIME}_satbias ]; then
          echo " using satellite bias files from ${SAT_TIME}"
          cp ${satbias_dir_cont}_ensmean/rrfs.${spinup_or_prod_rrfs}.${SAT_TIME}_satbias ./satbias_in
          cp ${satbias_dir_cont}_ensmean/rrfs.${spinup_or_prod_rrfs}.${SAT_TIME}_satbias_pc ./satbias_pc
          break
        fi
      else	
        # For EnVar
        if [ -r ${satbias_dir_cont}/rrfs.${spinup_or_prod_rrfs}.${SAT_TIME}_satbias ]; then
          echo " using satellite bias files from ${satbias_dir_cont} ${spinup_or_prod_rrfs}.${SAT_TIME}"
          cp ${satbias_dir_cont}/rrfs.${spinup_or_prod_rrfs}.${SAT_TIME}_satbias ./satbias_in
          cp ${satbias_dir_cont}/rrfs.${spinup_or_prod_rrfs}.${SAT_TIME}_satbias_pc ./satbias_pc
          if [ -r ${satbias_dir_cont}/rrfs.${spinup_or_prod_rrfs}.${SAT_TIME}_radstat ]; then
             cp ${satbias_dir_cont}/rrfs.${spinup_or_prod_rrfs}.${SAT_TIME}_radstat ./radstat.rrfs
          fi
          break
        fi
      fi
      satcounter=` expr $satcounter + 1 `
    done
  fi

  ## if satbias files (go back to previous 10 dyas) are not available from ${satbias_dir}, use satbias files from the ${FIX_GSI} 
  if [ $satcounter -eq $maxcounter ]; then
    # satbias_in
    if [ -r ${FIX_GSI}/rrfs.starting_satbias ]; then
      echo "using satelite satbias_in files from ${FIX_GSI}"     
      cp ${FIX_GSI}/rrfs.starting_satbias ./satbias_in
    fi
	  	  
    # satbias_pc
    if [ -r ${FIX_GSI}/rrfs.starting_satbias_pc ]; then
      echo "using satelite satbias_pc files from ${FIX_GSI}"     
      cp ${FIX_GSI}/rrfs.starting_satbias_pc ./satbias_pc
    fi
  fi

  if [ -r radstat.rrfs ]; then
    listdiag=`tar xvf radstat.rrfs | cut -d' ' -f2 | grep _ges`
    for type in $listdiag; do
      diag_file=`echo $type | cut -d',' -f1`
      fname=`echo $diag_file | cut -d'.' -f1`
      date=`echo $diag_file | cut -d'.' -f2`
      gunzip $diag_file
      fnameanl=$(echo $fname|sed 's/_ges//g')
      mv $fname.$date* $fnameanl
    done
  fi
fi

#-----------------------------------------------------------------------
# skip radar reflectivity analysis if no RRFSE ensemble
#-----------------------------------------------------------------------

if [[ ${gsi_type} == "ANALYSIS" && ${anav_type} == "radardbz" ]]; then
  if  [[ ${regional_ensemble_option:-1} -eq 1 ]]; then
    echo "No RRFSE ensemble available, cannot do radar reflectivity analysis"
    exit 0
  fi
fi
#-----------------------------------------------------------------------
#
# Build the GSI namelist on-the-fly
#    most configurable paramters take values from settings in config.sh
#                                             (var_defns.sh in runtime)
#
#-----------------------------------------------------------------------
# 
if [ "${gsi_type}" = "OBSERVER" ]; then
  miter=0
  ifhyb=.false.
  if [ "${mem_type}" = "MEAN" ]; then
    lread_obs_save=.true.
    lread_obs_skip=.false.
  else
    lread_obs_save=.false.
    lread_obs_skip=.true.
    if [ "${CYCLE_TYPE}" = "spinup" ]; then
      ln -s ../../ensmean/observer_gsi_spinup/obs_input.* .
    else
      ln -s ../../ensmean/observer_gsi/obs_input.* .
    fi
  fi
fi
if [ ${BKTYPE} -eq 1 ]; then
  n_iolayouty=1
else
  n_iolayouty=$(($IO_LAYOUT_Y))
fi

. ${FIX_GSI}/gsiparm.anl.sh
cat << EOF > gsiparm.anl
$gsi_namelist
EOF
#
#-----------------------------------------------------------------------
#
# Run the GSI.  Note that we have to launch the forecast from
# the current cycle's run directory because the GSI executable will look
# for input files in the current directory.
#
#-----------------------------------------------------------------------
#
if [[ ${gsi_type} == "ANALYSIS" && ${anav_type} == "AERO" ]]; then
  gsi_exec="${EXECdir}/gsi.x.sd"
else
  gsi_exec="${EXECdir}/gsi.x"
fi
cp ${gsi_exec} ${verifdir}/gsi.x

export pgm="gsi.x"
#. prep_step

if [ -r ${FIX_GSI}/${PREDEF_GRID_NAME}/xnorm_new.480.1351.1976 ] && [ -r ${FIX_GSI}/${PREDEF_GRID_NAME}/anl_grid.480.3950.2700 ]; then
  cp ${FIX_GSI}/${PREDEF_GRID_NAME}/xnorm_new.480.1351.1976 .
  cp ${FIX_GSI}/${PREDEF_GRID_NAME}/anl_grid.480.3950.2700 .
fi
if [ -r ${FIX_GSI}/${PREDEF_GRID_NAME}/xnorm_new.240.1351.1976 ] && [ -r ${FIX_GSI}/${PREDEF_GRID_NAME}/anl_grid.240.3950.2700 ]; then
  cp ${FIX_GSI}/${PREDEF_GRID_NAME}/xnorm_new.240.1351.1976 .
  cp ${FIX_GSI}/${PREDEF_GRID_NAME}/anl_grid.240.3950.2700 .
fi

$APRUN ./$pgm < gsiparm.anl >>$pgmout 2>errfile
cp $pgmout ${COMOUT}/rrfs.t${HH}z.gsiout.tm00
#export err=$?; err_chk
mv errfile errfile_gsi
#cp gsiparm.anl ${COMOUT}/.
#cp convinfo ${COMOUT}/.

if [ "${anav_type}" = "radardbz" ]; then
  cat fort.238 > ${COMOUT}/rrfs.t${HH}z.fits3.tm00
else
  mv fort.207 fit_rad1
  sed -e 's/   asm all     /ps asm 900 0000/; s/   rej all     /ps rej 900 0000/; s/   mon all     /ps mon 900 0000/' fort.201 > fit_p1
  sed -e 's/   asm all     /uv asm 900 0000/; s/   rej all     /uv rej 900 0000/; s/   mon all     /uv mon 900 0000/' fort.202 > fit_w1
  sed -e 's/   asm all     / t asm 900 0000/; s/   rej all     / t rej 900 0000/; s/   mon all     / t mon 900 0000/' fort.203 > fit_t1
  sed -e 's/   asm all     / q asm 900 0000/; s/   rej all     / q rej 900 0000/; s/   mon all     / q mon 900 0000/' fort.204 > fit_q1
  sed -e 's/   asm all     /pw asm 900 0000/; s/   rej all     /pw rej 900 0000/; s/   mon all     /pw mon 900 0000/' fort.205 > fit_pw1
  sed -e 's/   asm all     /rw asm 900 0000/; s/   rej all     /rw rej 900 0000/; s/   mon all     /rw mon 900 0000/' fort.209 > fit_rw1

  cat fit_p1 fit_w1 fit_t1 fit_q1 fit_pw1 fit_rad1 fit_rw1 > ${COMOUT}/rrfs.t${HH}z.fits.tm00
  cat fort.208 fort.210 fort.211 fort.212 fort.213 fort.220 > ${COMOUT}/rrfs.t${HH}z.fits2.tm00
  cat fort.238 > ${COMOUT}/rrfs.t${HH}z.fits3.tm00
  cp -L dbzobs.nc  ${COMOUT}/rrfs.mrms.${YYYYMMDDHH}.nc
fi
#
#-----------------------------------------------------------------------
#
# touch a file "gsi_complete.txt" after the successful GSI run. This is to inform
# the successful analysis for the EnKF recentering
#
#-----------------------------------------------------------------------
#
touch ${COMOUT}/gsi_complete.txt
if [[ ${anav_type} == "radardbz" || ${anav_type} == "conv_dbz" ]]; then
  touch ${COMOUT}/gsi_complete_radar.txt # for nonvarcldanl
fi
#
#-----------------------------------------------------------------------
# Loop over first and last outer loops to generate innovation
# diagnostic files for indicated observation types (groups)
#
# NOTE:  Since we set miter=2 in GSI namelist SETUP, outer
#        loop 03 will contain innovations with respect to 
#        the analysis.  Creation of o-a innovation files
#        is triggered by write_diag(3)=.true.  The setting
#        write_diag(1)=.true. turns on creation of o-g
#        innovation files.
#-----------------------------------------------------------------------
#
if [ "${DO_GSIDIAG_OFFLINE}" = "FALSE" ]; then
  netcdf_diag=${netcdf_diag:-".false."}
  binary_diag=${binary_diag:-".true."}

  loops="01 03"
  for loop in $loops; do

  case $loop in
    01) string=ges;;
    03) string=anl;;
     *) string=$loop;;
  esac

  #  Collect diagnostic files for obs types (groups) below
  numfile_rad_bin=0
  numfile_cnv=0
  numfile_rad=0
  if [ $binary_diag = ".true." ]; then
    listall="hirs2_n14 msu_n14 sndr_g08 sndr_g11 sndr_g11 sndr_g12 sndr_g13 sndr_g08_prep sndr_g11_prep sndr_g12_prep sndr_g13_prep sndrd1_g11 sndrd2_g11 sndrd3_g11 sndrd4_g11 sndrd1_g15 sndrd2_g15 sndrd3_g15 sndrd4_g15 sndrd1_g13 sndrd2_g13 sndrd3_g13 sndrd4_g13 hirs3_n15 hirs3_n16 hirs3_n17 amsua_n15 amsua_n16 amsua_n17 amsua_n18 amsua_n19 amsua_metop-a amsua_metop-b amsua_metop-c amsub_n15 amsub_n16 amsub_n17 hsb_aqua airs_aqua amsua_aqua imgr_g08 imgr_g11 imgr_g12 pcp_ssmi_dmsp pcp_tmi_trmm conv sbuv2_n16 sbuv2_n17 sbuv2_n18 omi_aura ssmi_f13 ssmi_f14 ssmi_f15 hirs4_n18 hirs4_metop-a mhs_n18 mhs_n19 mhs_metop-a mhs_metop-b mhs_metop-c amsre_low_aqua amsre_mid_aqua amsre_hig_aqua ssmis_las_f16 ssmis_uas_f16 ssmis_img_f16 ssmis_env_f16 iasi_metop-a iasi_metop-b iasi_metop-c seviri_m08 seviri_m09 seviri_m10 seviri_m11 cris_npp atms_npp ssmis_f17 cris-fsr_npp cris-fsr_n20 atms_n20 abi_g16 abi_g18 radardbz fed atms_n21 cris-fsr_n21"
    for type in $listall; do
      count=$(ls pe*.${type}_${loop} | wc -l)
      if [[ $count -gt 0 ]]; then
         $(cat pe*.${type}_${loop} > diag_${type}_${string}.${YYYYMMDDHH})
         cp diag_${type}_${string}.${YYYYMMDDHH} $COMOUT
         echo "diag_${type}_${string}.${YYYYMMDDHH}" >> listrad_bin
         numfile_rad_bin=`expr ${numfile_rad_bin} + 1`
      fi
    done
  fi

  if [ "$netcdf_diag" = ".true." ]; then
    export pgm="nc_diag_cat.x"

    listall_cnv="conv_ps conv_q conv_t conv_uv conv_pw conv_rw conv_sst conv_dbz conv_fed"
    listall_rad="hirs2_n14 msu_n14 sndr_g08 sndr_g11 sndr_g11 sndr_g12 sndr_g13 sndr_g08_prep sndr_g11_prep sndr_g12_prep sndr_g13_prep sndrd1_g11 sndrd2_g11 sndrd3_g11 sndrd4_g11 sndrd1_g15 sndrd2_g15 sndrd3_g15 sndrd4_g15 sndrd1_g13 sndrd2_g13 sndrd3_g13 sndrd4_g13 hirs3_n15 hirs3_n16 hirs3_n17 amsua_n15 amsua_n16 amsua_n17 amsua_n18 amsua_n19 amsua_metop-a amsua_metop-b amsua_metop-c amsub_n15 amsub_n16 amsub_n17 hsb_aqua airs_aqua amsua_aqua imgr_g08 imgr_g11 imgr_g12 pcp_ssmi_dmsp pcp_tmi_trmm conv sbuv2_n16 sbuv2_n17 sbuv2_n18 omi_aura ssmi_f13 ssmi_f14 ssmi_f15 hirs4_n18 hirs4_metop-a mhs_n18 mhs_n19 mhs_metop-a mhs_metop-b mhs_metop-c amsre_low_aqua amsre_mid_aqua amsre_hig_aqua ssmis_las_f16 ssmis_uas_f16 ssmis_img_f16 ssmis_env_f16 iasi_metop-a iasi_metop-b iasi_metop-c seviri_m08 seviri_m09 seviri_m10 seviri_m11 cris_npp atms_npp ssmis_f17 cris-fsr_npp cris-fsr_n20 atms_n20 abi_g16 abi_g18 atms_n21 cris-fsr_n21"

    for type in $listall_cnv; do
      count=$(ls pe*.${type}_${loop}.nc4 | wc -l)
      if [[ $count -gt 0 ]]; then
	 #. prep_step
         ${APRUN} $pgm -o diag_${type}_${string}.${YYYYMMDDHH}.nc4 pe*.${type}_${loop}.nc4 >>$pgmout 2>errfile
	 export err=$?; err_chk
	 mv errfile errfile_nc_diag_cat_$type
         gzip diag_${type}_${string}.${YYYYMMDDHH}.nc4
         #cp diag_${type}_${string}.${YYYYMMDDHH}.nc4.gz ${COMOUT}
         echo "diag_${type}_${string}.${YYYYMMDDHH}.nc4.gz" >> listcnv
         numfile_cnv=`expr ${numfile_cnv} + 1`
      fi
    done

    for type in $listall_rad; do
      count=$(ls pe*.${type}_${loop}.nc4 | wc -l)
      if [[ $count -gt 0 ]]; then
        #. prep_step
        ${APRUN} $pgm -o diag_${type}_${string}.${YYYYMMDDHH}.nc4 pe*.${type}_${loop}.nc4 >>$pgmout 2>errfile
	export err=$?; err_chk
	mv errfile errfile_nc_diag_cat_$type
        gzip diag_${type}_${string}.${YYYYMMDDHH}.nc4
        #cp diag_${type}_${string}.${YYYYMMDDHH}.nc4.gz ${COMOUT}
        echo "diag_${type}_${string}.${YYYYMMDDHH}.nc4.gz" >> listrad
        numfile_rad=`expr ${numfile_rad} + 1`
      else
        echo 'No diag_' ${type} 'exist'
      fi
    done
  fi
  done

#  if [ "${gsi_type}" = "OBSERVER" ]; then
#    cp *diag*ges* ${observer_nwges_dir}/.
#    if [ "${mem_type}" = "MEAN" ]; then
#      mkdir -p ${observer_nwges_dir}/../../../observer_diag/${YYYYMMDDHH}/ensmean/observer_gsi
#      cp *diag*ges* ${observer_nwges_dir}/../../../observer_diag/${YYYYMMDDHH}/ensmean/observer_gsi/.
#    else
#      mkdir -p ${observer_nwges_dir}/../../../observer_diag/${YYYYMMDDHH}/${slash_ensmem_subdir}/observer_gsi
#      cp *diag*ges* ${observer_nwges_dir}/../../../observer_diag/${YYYYMMDDHH}/${slash_ensmem_subdir}/observer_gsi/.
#    fi
#  fi
  #
  #-----------------------------------------------------------------------
  #
  # cycling radiance bias corretion files
  #
  #-----------------------------------------------------------------------
  #
  if [ "${DO_RADDA}" = "TRUE" ]; then
    if [ "${CYCLE_TYPE}" = "spinup" ]; then
      spinup_or_prod_rrfs=spinup
    else
      spinup_or_prod_rrfs=prod
    fi
    if [ ${numfile_cnv} -gt 0 ]; then
      tar -cvzf rrfs.${spinup_or_prod_rrfs}.${YYYYMMDDHH}_cnvstat_nc `cat listcnv`
      cp ./rrfs.${spinup_or_prod_rrfs}.${YYYYMMDDHH}_cnvstat_nc  ${satbias_dir}/rrfs.${spinup_or_prod_rrfs}.${YYYYMMDDHH}_cnvstat
    fi
    if [ ${numfile_rad} -gt 0 ]; then
      tar -cvzf rrfs.${spinup_or_prod_rrfs}.${YYYYMMDDHH}_radstat_nc `cat listrad`
      cp ./rrfs.${spinup_or_prod_rrfs}.${YYYYMMDDHH}_radstat_nc  ${satbias_dir}/rrfs.${spinup_or_prod_rrfs}.${YYYYMMDDHH}_radstat
    fi
    if [ ${numfile_rad_bin} -gt 0 ]; then
      tar -cvzf rrfs.${spinup_or_prod_rrfs}.${YYYYMMDDHH}_radstat `cat listrad_bin`
      cp ./rrfs.${spinup_or_prod_rrfs}.${YYYYMMDDHH}_radstat  ${satbias_dir}/rrfs.${spinup_or_prod_rrfs}.${YYYYMMDDHH}_radstat
    fi

    if [ "${DO_ENS_RADDA}" = "TRUE" ]; then
      # For EnKF: ensmean, copy satbias files; ens. member, do nothing  
      if [ ${mem_type} == "MEAN" ]; then  
        cp ./satbias_out ${satbias_dir}_ensmean/rrfs.${spinup_or_prod_rrfs}.${YYYYMMDDHH}_satbias
        cp ./satbias_pc.out ${satbias_dir}_ensmean/rrfs.${spinup_or_prod_rrfs}.${YYYYMMDDHH}_satbias_pc
        cp ./satbias_out ${COMOUT}_ensmean/rrfs.${spinup_or_prod_rrfs}.${YYYYMMDDHH}_satbias
        cp ./satbias_pc.out ${COMOUT}_ensmean/rrfs.${spinup_or_prod_rrfs}.${YYYYMMDDHH}_satbias_pc
      fi	 
    else
      # For EnVar DA  
      cp ./satbias_out ${satbias_dir}/rrfs.${spinup_or_prod_rrfs}.${YYYYMMDDHH}_satbias
      cp ./satbias_pc.out ${satbias_dir}/rrfs.${spinup_or_prod_rrfs}.${YYYYMMDDHH}_satbias_pc
      cp ./satbias_out ${COMOUT}/rrfs.${spinup_or_prod_rrfs}.${YYYYMMDDHH}_satbias
      cp ./satbias_pc.out ${COMOUT}/rrfs.${spinup_or_prod_rrfs}.${YYYYMMDDHH}_satbias_pc
      cp -L dbzobs.nc  $COMOUT/rrfs.mrms.${YYYYMMDDHH}.nc

    fi
  fi
fi # run diag inline (with GSI)
#
#-----------------------------------------------------------------------
#
# Print message indicating successful completion of script.
#
#-----------------------------------------------------------------------
#
echo "ANALYSIS GSI completed successfully!!!"

#!/bin/bash
###
### Utility for applying FV3-JEDI increments to background restart files
###

set -euo pipefail
set -x
do_radar=${1}
dynfile=${2}
trafile=${3}
phyfile=${4}

if command -v ncap2 >/dev/null 2>&1; then
  NCAP_BIN=ncap2
elif command -v ncap >/dev/null 2>&1; then
  NCAP_BIN=ncap
else
  echo "ERROR: Neither ncap2 nor ncap is available in PATH."
  exit 1
fi

cleanup_tmp() {
  rm -f \
    tmp_inc.nc tmp_bkg.nc tmp_inctr.nc tmp_bkgtr.nc tmp_incph.nc tmp_bkgph.nc
}
trap cleanup_tmp EXIT

#####################################################################
# 1. Core background + increments
#####################################################################
BKG=${dynfile}
INC=inc_jedi.fv_core.res.nc
OUT=fv_core_analysis.res.tile1.nc

# Make Time a record dimension (unlimited dimension)
ncks --mk_rec_dmn Time "$INC" tmp_inc.nc

# Copy background
ncks -O "$BKG" tmp_bkg.nc

# Make a temporary increment file with renamed variables
ncrename -v u,u_inc tmp_inc.nc
ncrename -v v,v_inc tmp_inc.nc
ncrename -v T,T_inc tmp_inc.nc
ncrename -v ua,ua_inc tmp_inc.nc
ncrename -v va,va_inc tmp_inc.nc
ncrename -v delp,delp_inc tmp_inc.nc
if [[ "${do_radar}" = "TRUE" ]]; then
  ncrename -v W,W_inc tmp_inc.nc
fi

# Append increment vars to tmp_bkg.nc
ncks -A tmp_inc.nc tmp_bkg.nc

# Perform addition in place
addstr="u=u+u_inc; v=v+v_inc; T=T+T_inc; ua=ua+ua_inc; va=va+va_inc; delp=delp+delp_inc;"
varlist="u_inc,v_inc,T_inc,ua_inc,va_inc,delp_inc"
if [[ "${do_radar}" = "TRUE" ]]; then
  addstr="${addstr} W=W+W_inc;"
  varlist="${varlist},W_inc"
fi
"${NCAP_BIN}" -O -s "${addstr}" tmp_bkg.nc "$OUT"

# Remove increment variables
ncks -O -x -v ${varlist} "$OUT" "$OUT"

#####################################################################
# 2. Tracer background + increments
#####################################################################
BKGtr=${trafile}
INCtr=inc_jedi.fv_tracer.res.nc
OUTtr=fv_tracer_analysis.res.tile1.nc

# Make Time a record dimension (unlimited dimension) on needed tracer increment vars.
tracer_vars=(sphum o3mr)
if [[ "${do_radar}" = "TRUE" ]]; then
  tracer_vars+=(ice_wat liq_wat rainwat snowwat graupel)
fi
tracer_vars_csv=$(IFS=,; echo "${tracer_vars[*]}")
ncks --mk_rec_dmn Time -v "${tracer_vars_csv}" "$INCtr" tmp_inctr.nc

# Copy background
ncks -O "$BKGtr" tmp_bkgtr.nc

# Make a temporary increment file with renamed variables
ncrename -v sphum,sphum_inc tmp_inctr.nc
ncrename -v o3mr,o3mr_inc   tmp_inctr.nc
if [[ "${do_radar}" = "TRUE" ]]; then
  ncrename -v ice_wat,ice_wat_inc  tmp_inctr.nc
  ncrename -v liq_wat,liq_wat_inc  tmp_inctr.nc
  ncrename -v rainwat,rainwat_inc  tmp_inctr.nc
  ncrename -v snowwat,snowwat_inc  tmp_inctr.nc
  ncrename -v graupel,graupel_inc  tmp_inctr.nc
fi

# Harmonize known tracer increment dimension names
if ncdump -h tmp_inctr.nc | grep -q 'yaxis_2 = '; then
  ncrename -d yaxis_2,yaxis_1 tmp_inctr.nc
fi

if ncdump -h tmp_inctr.nc | grep -q 'xaxis_2 = '; then
  ncrename -d xaxis_2,xaxis_1 tmp_inctr.nc
fi

# Ensure Time is record/unlimited on increment file if present
if ncdump -h tmp_inctr.nc | grep -q 'Time = '; then
  ncks --mk_rec_dmn Time -O tmp_inctr.nc tmp_inctr.nc
fi

# Append only increment vars into background
append_vars="sphum_inc,o3mr_inc"
if [[ "${do_radar}" = "TRUE" ]]; then
  append_vars="${append_vars},ice_wat_inc,liq_wat_inc,rainwat_inc,snowwat_inc,graupel_inc"
fi
ncks -A -v "${append_vars}" tmp_inctr.nc tmp_bkgtr.nc

# Perform addition in place
addstr="sphum=sphum+sphum_inc; o3mr=o3mr+o3mr_inc;"
varlist="sphum_inc,o3mr_inc"
if [[ "${do_radar}" = "TRUE" ]]; then
  addstr="${addstr} ice_wat=ice_wat+ice_wat_inc;"
  addstr="${addstr} liq_wat=liq_wat+liq_wat_inc;"
  addstr="${addstr} rainwat=rainwat+rainwat_inc;"
  addstr="${addstr} snowwat=snowwat+snowwat_inc;"
  addstr="${addstr} graupel=graupel+graupel_inc;"
  varlist="${varlist},ice_wat_inc,liq_wat_inc,rainwat_inc,snowwat_inc,graupel_inc"
fi

ncks -m -v sphum tmp_bkgtr.nc
ncks -m -v sphum_inc tmp_bkgtr.nc
"${NCAP_BIN}" -O \
  -s "${addstr}" \
  tmp_bkgtr.nc "$OUTtr"

# Remove increment variables
ncks -O -x -v ${varlist} "$OUTtr" "$OUTtr"

#####################################################################
# 3. Physics background + increments (only for radar DA)
#####################################################################
if [[ "${do_radar}" = "TRUE" ]]; then
  BKGph=${phyfile}
  INCph=inc_jedi.phy_data.nc
  OUTph=phy_data_analysis.nc

  # Make Time a record dimension (unlimited dimension)
  ncks --mk_rec_dmn Time "$INCph" tmp_incph.nc

  # Copy background
  ncks -O "$BKGph" tmp_bkgph.nc

  # Make a temporary increment file with renamed variables
  ncrename -v ref_f3d,ref_f3d_inc tmp_incph.nc

  # Append increment vars into OUT
  ncks -A tmp_incph.nc tmp_bkgph.nc

  # Perform addition in place
  "${NCAP_BIN}" -O \
    -s "ref_f3d=ref_f3d+ref_f3d_inc;" \
    tmp_bkgph.nc "$OUTph"

  # Remove increment variables
  ncks -O -x -v ref_f3d_inc "$OUTph" "$OUTph"

fi

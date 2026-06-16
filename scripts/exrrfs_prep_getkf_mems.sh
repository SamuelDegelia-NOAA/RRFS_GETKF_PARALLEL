#!/bin/bash
# Prepares the GETKF run directory for a single ensemble member by copying
# background restart files into data/inputs/mem0XX.  One PBS job is submitted
# per member so all 30 copies run in parallel.
#
# Required environment variables (supplied via envfile + qsub -v):
#   envfile              – path to the cycle-specific environment file
#   PREP_GETKF_MEMBER    – 1-based integer member index

################
### Settings ###
################

cd ${PBS_O_WORKDIR}
set -euox pipefail
echo ${envfile}
source "${envfile}"

# Member index is supplied by the driver via PBS -v
imem="${PREP_GETKF_MEMBER}"
mem3=$(printf %03i "${imem}")
memcharv0="mem${mem3}"

#############################
### Begin executable code ###
#############################

bkpath=${enspath}/m${mem3}/forecast/RESTART
suffix=${YYYYMMDD}.${HH}0000.

mkdir -p "${anldir}/data/inputs/${memcharv0}"

cp "${bkpath}/${suffix}coupler.res"             "${anldir}/data/inputs/${memcharv0}/coupler.res"
cp "${bkpath}/${suffix}fv_core.res.tile1.nc"    "${anldir}/data/inputs/${memcharv0}/fv_core.res.tile1.nc"
cp "${bkpath}/${suffix}fv_srf_wnd.res.tile1.nc" "${anldir}/data/inputs/${memcharv0}/fv_srf_wnd.res.tile1.nc"
cp "${bkpath}/${suffix}fv_tracer.res.tile1.nc"  "${anldir}/data/inputs/${memcharv0}/fv_tracer.res.tile1.nc"
cp "${bkpath}/${suffix}phy_data.nc"             "${anldir}/data/inputs/${memcharv0}/phy_data.nc"
cp "${bkpath}/${suffix}sfc_data.nc"             "${anldir}/data/inputs/${memcharv0}/sfc_data.nc"

echo "Member ${mem3} background files copied successfully to ${anldir}/data/inputs/${memcharv0}/"

#!/bin/bash

# This script grabs the real-time background ensemble from RRFSv1 and runs a JEDI-based GETKF analysis every hour
# Tasks include:
#   1. Run bufr2ioda.x to generate IODA observations including radar obs
#   2. Set up analysis run directory using saved fix files
#   3. Run GETKF analysis

# TODO: where and how to pre-process phy_data files in parallel?

# Settings
RDASApp=/lfs/h2/emc/da/noscrub/samuel.degelia/RDASApp_redist_iodafix/RDASApp
rrfsworkflow=/lfs/h2/emc/da/noscrub/samuel.degelia/rrfs-workflow_na3km/rrfs-workflow
rrfspath=/lfs/h1/ops/para/com/rrfs/v1.0
reflpath=/lfs/h1/ops/prod/dcom/ldmdata/obs/upperair/mrms/conus/MergedReflectivityQC
obsbase=/lfs/h1/ops/prod/com/obsproc/v1.2
baserundir=/lfs/h2/emc/stmp/samuel.degelia/GETKF_PARALLEL
getkfyaml=/lfs/h2/emc/da/noscrub/samuel.degelia/parallel_getkf/fix/rdas-atmosphere-templates-fv3_na3km_getkf.yaml

# Get the latest analysis we want to run and setup the run directories
# Hard-coded now just for debugging
# TODO: add logic to fetch the latest cycle that is fully done
# NOTE: the enspath contains RESTART files for the next forecast hour
# So enkfrrfs.20260416/15 contains the restart files for 2026041616
# Thus we need to look for obs at one hour after the restart file
enspath=/lfs/h1/ops/para/com/rrfs/v1.0/enkfrrfs.20260416/15
HH=${enspath##*/}
tmp=${enspath%/*}
YYYYMMDD=${tmp##*.}
YYYY=${YYYYMMDD:0:4}
MM=${YYYYMMDD:4:2}
DD=${YYYYMMDD:6:2}

# Now increase times by one hour since restart files are 1 h forecasts from this enspath
HH=$((HH + 1))
if (( HH >= 24 )); then
    HH=00
    # Increment the date by one day
    YYYYMMDD=$(date -d "${YYYY}-${MM}-${DD} +1 day" +%Y%m%d)
    YYYY=${YYYYMMDD:0:4}
    MM=${YYYYMMDD:4:2}
    DD=${YYYYMMDD:6:2}
fi
obspath=${obsbase}/rrfs.${YYYYMMDD}
bufrdir=${baserundir}/bufr.${YYYYMMDD}${HH}
mrmsdir=${baserundir}/mrms.${YYYYMMDD}${HH}
anldir=${baserundir}/getkf.${YYYYMMDD}${HH}

# Export the variables we will need in other tasks
envfile=getkf_run.env
cat > ${envfile} << EOF
RDASApp='${RDASApp}'
rrfsworkflow='${rrfsworkflow}'
rrfspath='${rrfspath}'
reflpath='${reflpath}'
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
EOF

# Build run directories
#if [ -d ${bufrdir} ]; then
#  rm -rf ${bufrdir}
#fi
#if [ -d ${mrmsdir} ]; then
#  rm -rf ${mrmsdir}
#fi
#if [ -d ${anldir} ]; then
#  rm -rf ${anldir}
#fi
rm bufr.log mrms.log getkf.log
mkdir -p ${bufrdir}
mkdir -p ${mrmsdir}
mkdir -p ${anldir}
cp ${envfile} ${bufrdir}
cp ${envfile} ${mrmsdir}
cp ${envfile} ${anldir}

# Create radar observations
#job1=$(qsub -v envfile="${envfile}" scripts/exrrfs_process_radar.sh)

# Convert prepbufr observations to IODA
#job2=$(qsub -v envfile="${envfile}" scripts/exrrfs_ioda_bufr.sh)

# Now run the GETKF analysis
#qsub -W depend=afterok:${job1}:${job2} scripts/exrrfs_analysis_enkf_jedi.sh
qsub -v envfile="${envfile}" scripts/exrrfs_analysis_enkf_jedi.sh

# Move output files for better tracking
exit
# need to figure out how to wait for the jobs to be done though
mv bufr.log  bufr_${YYYYMMDD}${HH}.log
mv mrms.log  mrms_${YYYYMMDD}${HH}.log
mv getkf.log getkf_${YYYYMMDD}${HH}.log






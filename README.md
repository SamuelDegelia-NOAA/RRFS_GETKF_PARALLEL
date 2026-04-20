# VERY Simple GETKF RRFS Workflow

This tool performs a GETKF analysis whenever the staged RRFS Workflow ensemble becomes available.

It only performs three tasks:

1. Convert prepbufr observations to IODA format
2. Generate reflectivity IODA observations from MRMS data
3. Run a GETKF analysis

It can either be run in standalone mode such as through:

`./DRIVER_analysis.sh /lfs/h1/ops/para/com/rrfs/v1.0/enkfrrfs.20260417/15`

Or it can be automated to run on the latest ensemble data available on Cactus:

`*/5 * * * * /path/to/RRFS_GETKF_PARALLEL/DRIVER_analysis_auto.sh`

Requirements: 
* Access to WCOSS2
* RDASApp and rrfs-workflow installed

Paths to data used on WCOSS2
* RRFS ensemble: `/lfs/h1/ops/para/com/rrfs/v1.0`
* BUFR observations: `/lfs/h1/ops/prod/com/obsproc/v1.2`
* MRMS observations: `/lfs/h1/ops/prod/dcom/ldmdata/obs/upperair/mrms/conus/MergedReflectivityQC`

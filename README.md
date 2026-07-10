# VERY Simple GETKF RRFS Workflow

This tool performs a GETKF analysis whenever the staged RRFS Workflow ensemble becomes available.

It performs four tasks, with the first three running concurrently:

1. Convert prepbufr observations to IODA format
2. Generate reflectivity IODA observations from MRMS data
3. Copy per-member background files into `getkf.{cycle}/data/inputs/mem0XX` (30 parallel jobs, one per member)
4. Run a GETKF analysis (depends on tasks 1, 2, and 3)

Tasks 1–3 run concurrently so that observation preprocessing and member background preparation overlap.
Background files are **copied** (not symlinked) into the per-member input directories because the GETKF
analysis (RDASApp) writes analyses directly back into those files in place, including the D-grid wind
conversion, so no separate post-processing step is needed.

It can either be run in standalone mode such as through:

`./DRIVER_analysis.sh /lfs/h1/ops/para/com/rrfs/v1.0/enkfrrfs.20260417/15`

Or it can be automated to run on the latest ensemble data available on Cactus:

`*/5 * * * * /path/to/RRFS_GETKF_PARALLEL/DRIVER_analysis_auto.sh`

The automated driver supports both regular cycle directories (`HH`) and spinup cycle directories
(`HH_spinup`, e.g. `07_spinup`, `19_spinup`). It resolves the actual directory by checking the
filesystem, so both forms work transparently.

The automated driver tracks processed cycles in:

`~/.enspath_cycle_history.txt`

Useful operations:
* Monitor progress: `tail -f ~/.enspath_cycle_history.txt`
* Restart from a specific cycle by removing newer entries from the history file
* Manual trim example (remove last 5 entries): `head -n -5 ~/.enspath_cycle_history.txt > ~/.enspath_cycle_history.txt.tmp && mv ~/.enspath_cycle_history.txt.tmp ~/.enspath_cycle_history.txt`

Requirements: 
* Access to WCOSS2
* RDASApp and rrfs-workflow installed

Paths to data used on WCOSS2
* RRFS ensemble: `/lfs/h1/ops/para/com/rrfs/v1.0`
* BUFR observations: `/lfs/h1/ops/prod/com/obsproc/v1.2`
* MRMS observations: `/lfs/h1/ops/prod/dcom/ldmdata/obs/upperair/mrms/conus/MergedReflectivityQC`

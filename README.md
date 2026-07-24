# VERY Simple GETKF RRFS Workflow

This tool performs a GETKF analysis whenever the staged RRFS Workflow ensemble becomes available.

It performs six tasks, with the first three running concurrently:

1. Convert prepbufr observations to IODA format
2. Generate reflectivity IODA observations from MRMS data
3. Copy per-member background files into `getkf.{cycle}/data/inputs/mem0XX` (30 parallel jobs, one per member)
4. Run a GETKF analysis (depends on tasks 1, 2, and 3)
5. Post-process each member's analysis with `rdas_ua2u.x --in_anl` (depends on task 4; 30 parallel jobs, one per member)
6. Clean up increment/rundir files (depends on all of task 5)

Tasks 1–3 run concurrently so that observation preprocessing and member background preparation overlap.
Background files are **copied** (not symlinked) into the per-member input directories because the GETKF
analysis (RDASApp) writes most analyzed variables directly back into those files in place.

The GETKF analysis uses `write into existing files` with the analyzed A-grid wind aliased to
`ua_anl`/`va_anl`, so the original background `ua`/`va` and the D-grid `u`/`v` are left untouched by
JEDI. This is required to get JEDI's LETKF/GETKF peak-memory reduction (releasing background member
states during the solve and reconstructing them afterward only works when the fields JEDI writes don't
overwrite fields it needs to leave alone). The tradeoff is that a separate post-processing step (task 5)
is then needed to turn `ua_anl`/`va_anl` into a model-restart-ready analysis: for each member,
`rdas_ua2u.x ua_update_u --in_anl=data/inputs/mem0XX/fv_core.res.tile1.nc --remove_anl_winds` computes the
A-grid wind increment as `(ua_anl-ua, va_anl-va)`, converts it to a D-grid `u`/`v` increment, adds that to
the background `u`/`v` already in the file, and removes `ua_anl`/`va_anl` once they're no longer needed.
After task 5, `data/inputs/mem0XX/fv_core.res.tile1.nc` is a complete analysis with `u`/`v` updated,
ready to restart the model from.

Because task 5 is now the last step in the workflow, cleanup of increment/rundir files (previously done
at the end of the GETKF task) has moved to task 6, which runs once after all 30 task-5 jobs complete.

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

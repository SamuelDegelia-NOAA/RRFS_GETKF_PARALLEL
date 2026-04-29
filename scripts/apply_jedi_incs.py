#!/usr/bin/env python3
###
### Utility for applying FV3-JEDI increments to background restart files.
###
### Replaces apply_jedi_incs.sh with an xarray/dask-based implementation that:
###   - Avoids the slow double-to-float conversion step
###   - Eliminates the ncks --mk_rec_dmn step that causes chunk size errors
###   - Handles mixed precision (float32 background + float64 increments)
###   - Loads each file once, performs arithmetic in memory, and saves once
###
### Usage:
###   python apply_jedi_incs.py <do_radar> <dynfile> <trafile> <phyfile>
###
### Arguments:
###   do_radar  - "TRUE" to enable radar DA variables, anything else to disable
###   dynfile   - path to fv_core background file (e.g. fv_core.res.tile1.nc)
###   trafile   - path to fv_tracer background file (e.g. fv_tracer.res.tile1.nc)
###   phyfile   - path to phy_data background file (e.g. phy_data.nc)
###

import os
import sys
import xarray as xr
import dask.array as da


def apply_increments(bkg_path, inc_path, out_path, var_names):
    """
    Add increment values to background variables and write to an output file.

    Parameters
    ----------
    bkg_path : str
        Path to the background NetCDF file.
    inc_path : str
        Path to the increment NetCDF file.
    out_path : str
        Path to write the analysis output NetCDF file.
    var_names : list of str
        Variable names to update (the same name must exist in both files).
    """
    for path in (bkg_path, inc_path):
        if not os.path.exists(path):
            raise FileNotFoundError(f"Input file not found: {path}")

    # Load datasets with dask chunking for lazy evaluation
    bkg = xr.open_dataset(bkg_path, chunks="auto")
    inc = xr.open_dataset(inc_path, chunks="auto")

    # Start with a deep copy of the background dataset
    out = bkg.copy(deep=True)

    for var in var_names:
        if var in bkg and var in inc:
            # Extract as numpy/dask arrays to avoid dimension alignment issues.
            # Use .values to get the underlying array (dask.array if chunked).
            bkg_data = bkg[var].data
            inc_data = inc[var].data
            orig_dtype = bkg[var].dtype

            # Cast increment to background dtype before addition to preserve precision
            inc_data_cast = inc_data.astype(orig_dtype)

            # Perform the addition (dask will compute this lazily if chunked)
            result_data = bkg_data + inc_data_cast

            # Wrap back into a DataArray with original coordinates and attributes
            result = xr.DataArray(
                result_data,
                coords=bkg[var].coords,
                dims=bkg[var].dims,
                attrs=bkg[var].attrs,
            )
            out[var] = result
        else:
            missing = [v for v in (bkg_path, inc_path)
                       if var not in (bkg if v == bkg_path else inc)]
            print(f"WARNING: variable '{var}' not found in: "
                  f"{', '.join(missing)}; skipping", file=sys.stderr)

    # Preserve original dtypes for all variables in the output file.
    encoding = {var: {"dtype": str(out[var].dtype)} for var in out.data_vars}

    out.to_netcdf(out_path, encoding=encoding)

    bkg.close()
    inc.close()


def main():
    if len(sys.argv) != 5:
        print(f"Usage: {sys.argv[0]} <do_radar> <dynfile> <trafile> <phyfile>")
        sys.exit(1)

    do_radar = sys.argv[1].upper() == "TRUE"
    dynfile  = sys.argv[2]
    trafile  = sys.argv[3]
    phyfile  = sys.argv[4]

    #####################################################################
    # 1. Core background + increments (fv_core)
    #####################################################################
    core_vars = ["u", "v", "T", "ua", "va", "delp"]
    if do_radar:
        core_vars.append("W")

    apply_increments(
        dynfile,
        "inc_jedi.fv_core.res.nc",
        "fv_core_analysis.res.tile1.nc",
        core_vars,
    )

    #####################################################################
    # 2. Tracer background + increments (fv_tracer)
    #####################################################################
    tracer_vars = ["sphum", "o3mr"]
    if do_radar:
        tracer_vars.extend(["ice_wat", "liq_wat", "rainwat", "snowwat", "graupel"])

    apply_increments(
        trafile,
        "inc_jedi.fv_tracer.res.nc",
        "fv_tracer_analysis.res.tile1.nc",
        tracer_vars,
    )

    #####################################################################
    # 3. Physics background + increments (only for radar DA)
    #####################################################################
    if do_radar:
        apply_increments(
            phyfile,
            "inc_jedi.phy_data.nc",
            "phy_data_analysis.nc",
            ["ref_f3d"],
        )


if __name__ == "__main__":
    main()

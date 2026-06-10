#!/usr/bin/env python3
###
### Utility for applying FV3-JEDI increments to background restart files.
###
### Debug-enhanced version to help diagnose stalls/hangs during increment
### application and NetCDF output writing.
###
### Usage:
###   python apply_jedi_incs.py <do_radar> <dynfile> <trafile> <phyfile>
###
### Optional environment variables for debugging:
###   APPLY_JEDI_USE_DASK=1          -> open with chunks="auto"
###   APPLY_JEDI_EAGER_LOAD=1        -> call out.load() before to_netcdf()
###   APPLY_JEDI_WRITE_TMP=1         -> write to <out>.tmp then rename atomically
###   APPLY_JEDI_ENGINE=netcdf4      -> pass engine to open_dataset/to_netcdf
###   APPLY_JEDI_FORMAT=NETCDF4      -> pass format to to_netcdf
###

import os
import sys
import time
import socket
import traceback
import xarray as xr


def log(msg):
    now = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime())
    print(f"[{now} UTC] [apply_jedi_incs.py] {msg}", flush=True)


def env_flag(name, default=False):
    val = os.environ.get(name)
    if val is None:
        return default
    return val.strip().lower() in ("1", "true", "yes", "y", "on")


def safe_filesize(path):
    try:
        return os.path.getsize(path)
    except Exception:
        return None


def describe_file(path, label):
    exists = os.path.exists(path)
    size = safe_filesize(path) if exists else None
    log(f"{label}: path={path} exists={exists} size_bytes={size}")


def describe_dataarray(label, da):
    try:
        chunks = getattr(da.data, "chunks", None)
    except Exception:
        chunks = None

    try:
        shape = da.shape
    except Exception:
        shape = "UNKNOWN"

    try:
        dims = da.dims
    except Exception:
        dims = "UNKNOWN"

    try:
        dtype = da.dtype
    except Exception:
        dtype = "UNKNOWN"

    log(
        f"{label}: dims={dims} shape={shape} dtype={dtype} "
        f"chunks={chunks}"
    )


def describe_dataset(label, ds):
    try:
        vars_list = list(ds.data_vars)
    except Exception:
        vars_list = []

    try:
        coords_list = list(ds.coords)
    except Exception:
        coords_list = []

    log(
        f"{label}: data_vars={len(vars_list)} coords={len(coords_list)} "
        f"vars={vars_list}"
    )


def apply_increments(bkg_path, inc_path, out_path, var_names):
    t0 = time.time()

    log("------------------------------------------------------------------")
    log(f"Starting apply_increments")
    log(f"Host={socket.gethostname()} PID={os.getpid()}")
    log(f"bkg_path={bkg_path}")
    log(f"inc_path={inc_path}")
    log(f"out_path={out_path}")
    log(f"var_names={var_names}")

    use_dask = env_flag("APPLY_JEDI_USE_DASK", default=False)
    eager_load = env_flag("APPLY_JEDI_EAGER_LOAD", default=False)
    write_tmp = env_flag("APPLY_JEDI_WRITE_TMP", default=False)
    engine = os.environ.get("APPLY_JEDI_ENGINE")
    nc_format = os.environ.get("APPLY_JEDI_FORMAT")

    log(
        f"Config: use_dask={use_dask} eager_load={eager_load} "
        f"write_tmp={write_tmp} engine={engine} format={nc_format}"
    )

    for path in (bkg_path, inc_path):
        describe_file(path, "input")
        if not os.path.exists(path):
            raise FileNotFoundError(f"Input file not found: {path}")

    open_kwargs = {}
    if use_dask:
        open_kwargs["chunks"] = "auto"
    if engine:
        open_kwargs["engine"] = engine

    bkg = None
    inc = None
    out = None

    try:
        t_open = time.time()
        log(f"Opening background dataset with kwargs={open_kwargs}")
        bkg = xr.open_dataset(bkg_path, **open_kwargs)
        log(f"Opened background dataset in {time.time() - t_open:.2f} s")
        describe_dataset("background dataset", bkg)

        t_open = time.time()
        log(f"Opening increment dataset with kwargs={open_kwargs}")
        inc = xr.open_dataset(inc_path, **open_kwargs)
        log(f"Opened increment dataset in {time.time() - t_open:.2f} s")
        describe_dataset("increment dataset", inc)

        log("Creating output dataset with bkg.copy(deep=False)")
        t_copy = time.time()
        out = bkg.copy(deep=False)
        log(f"Created output dataset in {time.time() - t_copy:.2f} s")
        describe_dataset("initial output dataset", out)

        for idx, var in enumerate(var_names, start=1):
            log(f"[{idx}/{len(var_names)}] Processing variable '{var}'")

            if var not in bkg:
                log(f"WARNING: variable '{var}' missing from background file {bkg_path}; skipping")
                continue

            if var not in inc:
                log(f"WARNING: variable '{var}' missing from increment file {inc_path}; skipping")
                continue

            describe_dataarray(f"background[{var}]", bkg[var])
            describe_dataarray(f"increment[{var}]", inc[var])

            t_var = time.time()
            try:
                bkg_data = bkg[var].data
                inc_data = inc[var].data
                orig_dtype = bkg[var].dtype

                log(f"Variable '{var}': original dtype={orig_dtype}")
                log(f"Variable '{var}': casting increment to {orig_dtype}")
                inc_data_cast = inc_data.astype(orig_dtype)

                log(f"Variable '{var}': performing addition")
                result_data = bkg_data + inc_data_cast

                log(f"Variable '{var}': wrapping result in DataArray")
                result = xr.DataArray(
                    result_data,
                    coords=bkg[var].coords,
                    dims=bkg[var].dims,
                    attrs=bkg[var].attrs,
                )

                out[var] = result
                describe_dataarray(f"output[{var}]", out[var])

                log(f"Variable '{var}' completed in {time.time() - t_var:.2f} s")
            except Exception as e:
                log(f"ERROR while processing variable '{var}': {repr(e)}")
                log(traceback.format_exc())
                raise

        log("Building encoding dictionary")
        t_enc = time.time()
        encoding = {var: {"dtype": str(out[var].dtype)} for var in out.data_vars}
        log(
            f"Built encoding for {len(encoding)} variables in "
            f"{time.time() - t_enc:.2f} s"
        )

        final_out_path = out_path
        tmp_out_path = out_path + ".tmp"

        if write_tmp:
            final_write_path = tmp_out_path
            log(f"Temporary write enabled: writing first to {final_write_path}")
        else:
            final_write_path = final_out_path
            log(f"Temporary write disabled: writing directly to {final_write_path}")

        if os.path.exists(final_write_path):
            describe_file(final_write_path, "pre-existing output")
            log(f"Removing pre-existing file at {final_write_path}")
            os.remove(final_write_path)

        if eager_load:
            log("APPLY_JEDI_EAGER_LOAD enabled: forcing out.load() before write")
            t_load = time.time()
            out = out.load()
            log(f"out.load() completed in {time.time() - t_load:.2f} s")
            describe_dataset("loaded output dataset", out)

        write_kwargs = {"encoding": encoding}
        if engine:
            write_kwargs["engine"] = engine
        if nc_format:
            write_kwargs["format"] = nc_format

        log(f"Beginning to_netcdf -> {final_write_path} with kwargs={write_kwargs}")
        t_write = time.time()
        out.to_netcdf(final_write_path, **write_kwargs)
        log(f"to_netcdf completed in {time.time() - t_write:.2f} s")
        describe_file(final_write_path, "written output")

        if write_tmp:
            log(f"Renaming {tmp_out_path} -> {final_out_path}")
            os.replace(tmp_out_path, final_out_path)
            describe_file(final_out_path, "final output after rename")

        log(f"apply_increments completed successfully in {time.time() - t0:.2f} s")

    except Exception as e:
        log(f"FATAL ERROR in apply_increments: {repr(e)}")
        log(traceback.format_exc())

        if os.path.exists(out_path):
            describe_file(out_path, "output file after error")
        if os.path.exists(out_path + ".tmp"):
            describe_file(out_path + ".tmp", "tmp output file after error")

        raise

    finally:
        log("Closing datasets")
        try:
            if out is not None:
                out.close()
                log("Closed output dataset")
        except Exception as e:
            log(f"WARNING: failed to close output dataset: {repr(e)}")

        try:
            if bkg is not None:
                bkg.close()
                log("Closed background dataset")
        except Exception as e:
            log(f"WARNING: failed to close background dataset: {repr(e)}")

        try:
            if inc is not None:
                inc.close()
                log("Closed increment dataset")
        except Exception as e:
            log(f"WARNING: failed to close increment dataset: {repr(e)}")


def main():
    log("Program start")
    log(f"argv={sys.argv}")

    if len(sys.argv) != 5:
        print(f"Usage: {sys.argv[0]} <do_radar> <dynfile> <trafile> <phyfile>", flush=True)
        sys.exit(1)

    do_radar = sys.argv[1].upper() == "TRUE"
    dynfile = sys.argv[2]
    trafile = sys.argv[3]
    phyfile = sys.argv[4]

    log(f"do_radar={do_radar}")
    log(f"dynfile={dynfile}")
    log(f"trafile={trafile}")
    log(f"phyfile={phyfile}")

    #####################################################################
    # 1. Core background + increments (fv_core)
    #####################################################################
    core_vars = ["u", "v", "T", "ua", "va", "delp"]
    if do_radar:
        core_vars.append("W")

    log("Starting fv_core increment application")
    apply_increments(
        dynfile,
        "inc_jedi.fv_core.res.nc",
        "fv_core_analysis.res.tile1.nc",
        core_vars,
    )
    log("Finished fv_core increment application")

    #####################################################################
    # 2. Tracer background + increments (fv_tracer)
    #####################################################################
    tracer_vars = ["sphum", "o3mr"]
    if do_radar:
        tracer_vars.extend(["ice_wat", "liq_wat", "rainwat", "snowwat", "graupel"])

    log("Starting fv_tracer increment application")
    apply_increments(
        trafile,
        "inc_jedi.fv_tracer.res.nc",
        "fv_tracer_analysis.res.tile1.nc",
        tracer_vars,
    )
    log("Finished fv_tracer increment application")

    #####################################################################
    # 3. Physics background + increments (only for radar DA)
    #####################################################################
    if do_radar:
        log("Starting phy_data increment application")
        apply_increments(
            phyfile,
            "inc_jedi.phy_data.nc",
            "phy_data_analysis.nc",
            ["ref_f3d"],
        )
        log("Finished phy_data increment application")

    log("Program finished successfully")


if __name__ == "__main__":
    main()

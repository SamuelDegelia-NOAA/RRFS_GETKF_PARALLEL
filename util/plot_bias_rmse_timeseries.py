import os
import subprocess
from subprocess import CalledProcessError, TimeoutExpired
from datetime import datetime, timedelta

import numpy as np
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from netCDF4 import Dataset

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
firstcycle = '2026050601'  # YYYYMMDDHH
lastcycle  = '2026050711'  # YYYYMMDDHH
archivedir = '/lfs/h2/emc/da/noscrub/samuel.degelia/PARALLEL_SAVE'
outdir     = '.'

diaglist = [
    'diag_conv_t',
    'diag_conv_q',
    'diag_conv_uv',
]

DO_PAIR = True

# ---------------------------------------------------------------------------
# Pressure-bin toggle
#
# Set PLOT_PRESSURE_BINS = False (default) to produce a single time-series
# plot using all observations at all pressure levels.
#
# Set PLOT_PRESSURE_BINS = True to produce one plot per pressure bin defined
# in PRESSURE_BINS below (five plots total, including the all-levels bin).
# ---------------------------------------------------------------------------
PLOT_PRESSURE_BINS = False

# Pressure bins: (pmin, pmax, title_label, filename_tag)
# Bounds are inclusive (>=, <=); None means unbounded on that side.
# pmin is the lower numerical pressure bound (higher altitude),
# pmax is the upper numerical pressure bound (lower altitude / near surface).
# The labels follow meteorological convention: higher pressure value listed
# first (e.g., '1150–950 hPa' means pmin=950, pmax=1150).
PRESSURE_BINS = [
    (None,   None,   'All Levels',   'all'),
    (950.0, 1150.0, '1150\u2013950 hPa', '1150-950hPa'),
    (750.0,  950.0,  '950\u2013750 hPa',  '950-750hPa'),
    (550.0,  750.0,  '750\u2013550 hPa',  '750-550hPa'),
    (None,   550.0,  '<550 hPa',          'lt550hPa'),
]

GUNZIP_TIMEOUT_SECONDS = 300

GSI_COLOR  = 'red'
JEDI_COLOR = 'blue'

PLOT_NAMES = {
    'diag_conv_t':  'Temperature',
    'diag_conv_q':  'Humidity',
    'diag_conv_uv': 'Wind',
}

# ---------------------------------------------------------------------------
# Helper functions (shared with plot_bias_rmse_profile.py)
# ---------------------------------------------------------------------------

def safe_read_var(ds, name):
    """Read a NetCDF variable and return a numpy array."""
    if name not in ds.variables:
        raise KeyError(f"Variable '{name}' not found in file")
    return np.asarray(ds.variables[name][:])


def build_pairing_keys(lat, lon, hgt, tim,
                       lat_decimals=4, lon_decimals=4,
                       hgt_decimals=1, tim_decimals=3):
    """Build robust pairing keys from metadata."""
    lat_r = np.round(lat, lat_decimals)
    lon_r = np.round(lon, lon_decimals)
    hgt_r = np.round(hgt, hgt_decimals)
    tim_r = np.round(tim, tim_decimals)
    return list(zip(lat_r, lon_r, hgt_r, tim_r))


def enumerate_cycles(first, last):
    """Return hourly cycle strings from first to last, inclusive."""
    first_dt = datetime.strptime(first, '%Y%m%d%H')
    last_dt  = datetime.strptime(last,  '%Y%m%d%H')
    if first_dt > last_dt:
        raise ValueError('firstcycle must be <= lastcycle')

    cycles = []
    cdt = first_dt
    while cdt <= last_dt:
        cycles.append(cdt.strftime('%Y%m%d%H'))
        cdt += timedelta(hours=1)
    return cycles


def get_diag_path(cycle, system, idiag):
    """Build archived diag path for one cycle/system/diagnostic."""
    return os.path.join(
        archivedir,
        f'verif.{cycle}',
        system,
        f'{idiag}_ges.{cycle}.nc4.gz'
    )


def read_diag_arrays(diag_file, idiag):
    """Read pressure, OMF-adjusted, and pairing metadata from an unzipped diag file."""
    with Dataset(diag_file, 'r') as ds:
        lat = safe_read_var(ds, 'Latitude')
        lon = safe_read_var(ds, 'Longitude')
        hgt = safe_read_var(ds, 'Height')
        tim = safe_read_var(ds, 'Time')

        try:
            prs = safe_read_var(ds, 'Pressure')
        except KeyError:
            prs = np.full(len(lat), np.nan)

        if idiag == 'diag_conv_uv':
            # For wind diagnostics, use a consistent scalar OMF definition based
            # on vector wind speed: OMF_speed = |Obs| - |Forecast|.
            u_obs = safe_read_var(ds, 'u_Observation')
            v_obs = safe_read_var(ds, 'v_Observation')
            u_omf = safe_read_var(ds, 'u_Obs_Minus_Forecast_adjusted')
            v_omf = safe_read_var(ds, 'v_Obs_Minus_Forecast_adjusted')

            u_fcst  = u_obs - u_omf
            v_fcst  = v_obs - v_omf
            obs_spd  = np.sqrt(u_obs**2 + v_obs**2)
            fcst_spd = np.sqrt(u_fcst**2 + v_fcst**2)
            omf = obs_spd - fcst_spd
        else:
            omf = safe_read_var(ds, 'Obs_Minus_Forecast_adjusted')

    if idiag == 'diag_conv_q':
        omf = omf * 1000.0  # Convert kg/kg to g/kg

    keys = build_pairing_keys(lat, lon, hgt, tim)

    mask = np.isfinite(prs) & np.isfinite(omf)
    keys = [keys[i] for i in np.flatnonzero(mask)]
    return {
        'keys':     keys,
        'pressure': prs[mask],
        'omf':      omf[mask],
    }


def pair_omf(gsi_data, jedi_data):
    """Pair GSI/JEDI observations by metadata keys."""
    gsi_map = {}
    for i, key in enumerate(gsi_data['keys']):
        if key not in gsi_map:
            gsi_map[key] = i

    jedi_map = {}
    for i, key in enumerate(jedi_data['keys']):
        if key not in jedi_map:
            jedi_map[key] = i

    common_keys = sorted(set(gsi_map.keys()) & set(jedi_map.keys()))
    if len(common_keys) == 0:
        return np.array([]), np.array([]), np.array([])

    gsi_idx  = np.array([gsi_map[key]  for key in common_keys], dtype=int)
    jedi_idx = np.array([jedi_map[key] for key in common_keys], dtype=int)

    gsi_omf  = gsi_data['omf'][gsi_idx]
    jedi_omf = jedi_data['omf'][jedi_idx]
    prs      = gsi_data['pressure'][gsi_idx]

    good = np.isfinite(gsi_omf) & np.isfinite(jedi_omf) & np.isfinite(prs)
    return gsi_omf[good], jedi_omf[good], prs[good]


def ensure_unzipped_diag(diag_file_gz):
    """Ensure a .nc4 diag exists by unzipping in place when needed, while keeping .gz."""
    archive_root = os.path.abspath(archivedir) + os.sep
    if not os.path.abspath(diag_file_gz).startswith(archive_root):
        print(f'Unexpected diag file path outside archive root: {diag_file_gz}')
        return None

    if not diag_file_gz.endswith('.gz'):
        print(f'Unsupported diag format (expected .gz): {diag_file_gz}')
        return None
    local_nc = diag_file_gz.removesuffix('.gz')

    if not os.path.exists(local_nc):
        if not os.path.exists(diag_file_gz):
            return None
        try:
            subprocess.run(
                ['gunzip', '-f', '-k', diag_file_gz],
                check=True,
                capture_output=True,
                text=True,
                timeout=GUNZIP_TIMEOUT_SECONDS,
            )
        except TimeoutExpired:
            print(f'gunzip timed out after {GUNZIP_TIMEOUT_SECONDS}s: {diag_file_gz}')
            return None
        except CalledProcessError as exc:
            print(f'gunzip failed for {diag_file_gz} (returncode={exc.returncode})')
            if exc.stdout:
                print(exc.stdout.strip())
            if exc.stderr:
                print(exc.stderr.strip())
            return None
        except Exception as exc:
            print(f'Failed to unzip diag file {diag_file_gz}: {exc}')
            return None

    if not os.path.exists(local_nc):
        return None

    return local_nc


# ---------------------------------------------------------------------------
# Time-series specific helpers
# ---------------------------------------------------------------------------

def compute_scalar_stats(omf, prs, pmin, pmax):
    """Compute bias and RMSE for observations within the given pressure range.

    Parameters
    ----------
    omf  : 1-D array of Obs-Minus-Forecast values
    prs  : 1-D array of pressure values (hPa), same length as omf
    pmin : lower pressure bound (hPa), inclusive; None = no lower bound
    pmax : upper pressure bound (hPa), inclusive; None = no upper bound

    Returns
    -------
    bias  : float (forecast minus obs, NaN if no data)
    rmse  : float (NaN if no data)
    count : int
    """
    mask = np.ones(len(omf), dtype=bool)
    if pmin is not None:
        mask &= prs >= pmin
    if pmax is not None:
        mask &= prs <= pmax

    vals = omf[mask]
    if len(vals) == 0:
        return np.nan, np.nan, 0

    # OMF is Obs-Forecast; negate to report forecast bias (Forecast-Obs)
    forecast_minus_obs = -1.0 * vals
    bias  = np.mean(forecast_minus_obs)
    rmse  = np.sqrt(np.mean(vals**2))
    return bias, rmse, len(vals)


def plot_timeseries(cycle_dts, gsi_bias, gsi_rmse, gsi_counts,
                    jedi_bias, jedi_rmse, jedi_counts,
                    idiag, cycle_label, bin_label, outpath):
    """Write one GSI/JEDI bias and RMSE time-series plot.

    Parameters
    ----------
    cycle_dts   : list of datetime objects (x-axis)
    gsi_bias    : list/array of per-cycle GSI bias values
    gsi_rmse    : list/array of per-cycle GSI RMSE values
    gsi_counts  : list/array of per-cycle GSI observation counts
    jedi_bias   : list/array of per-cycle JEDI bias values
    jedi_rmse   : list/array of per-cycle JEDI RMSE values
    jedi_counts : list/array of per-cycle JEDI observation counts
    idiag       : diagnostic name string (used for title lookup)
    cycle_label : string summarising the cycle range (used in plot title)
    bin_label   : pressure-bin label string (used in plot title)
    outpath     : full output file path
    """
    gsi_bias   = np.array(gsi_bias,   dtype=float)
    gsi_rmse   = np.array(gsi_rmse,   dtype=float)
    jedi_bias  = np.array(jedi_bias,  dtype=float)
    jedi_rmse  = np.array(jedi_rmse,  dtype=float)
    gsi_counts = np.array(gsi_counts, dtype=int)
    jedi_counts = np.array(jedi_counts, dtype=int)

    gsi_n_total  = int(np.nansum(gsi_counts))
    jedi_n_total = int(np.nansum(jedi_counts))

    fig, ax = plt.subplots(figsize=(10, 5))

    ax.plot(cycle_dts, gsi_rmse, color=GSI_COLOR, linestyle='-',
            marker='o', markersize=4, linewidth=1.8,
            label=f'GSI RMSE (N={gsi_n_total})')
    ax.plot(cycle_dts, gsi_bias, color=GSI_COLOR, linestyle='--',
            marker='o', markersize=4, linewidth=1.8,
            label=f'GSI Bias (N={gsi_n_total})')
    ax.plot(cycle_dts, jedi_rmse, color=JEDI_COLOR, linestyle='-',
            marker='o', markersize=4, linewidth=1.8,
            label=f'JEDI RMSE (N={jedi_n_total})')
    ax.plot(cycle_dts, jedi_bias, color=JEDI_COLOR, linestyle='--',
            marker='o', markersize=4, linewidth=1.8,
            label=f'JEDI Bias (N={jedi_n_total})')

    ax.axhline(0.0, color='black', linewidth=1.0)

    # Format x-axis as dates; rotate labels for readability
    ax.xaxis.set_major_formatter(mdates.DateFormatter('%m/%d\n%HZ'))
    ax.xaxis.set_major_locator(mdates.AutoDateLocator())
    fig.autofmt_xdate(rotation=0, ha='center')

    ax.set_xlabel('Cycle')
    ax.set_ylabel('Forecast RMSE (solid) / Forecast bias (dashed)')
    ax.set_title(
        f'{PLOT_NAMES.get(idiag, idiag)} bias and RMSE time series'
        f' \u2014 {bin_label}\nCycles {cycle_label}'
    )
    ax.grid(True, alpha=0.3)
    ax.legend(loc='best')
    fig.tight_layout()
    fig.savefig(outpath, dpi=150)
    plt.close(fig)
    print(f'Wrote {outpath}')


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    os.makedirs(outdir, exist_ok=True)

    cycles      = enumerate_cycles(firstcycle, lastcycle)
    cycle_label = f'{firstcycle}-{lastcycle}'
    pair_tag    = 'paired' if DO_PAIR else 'unpaired'

    # Determine which pressure bins to iterate over.
    # When PLOT_PRESSURE_BINS is False, only the all-levels bin is used.
    if PLOT_PRESSURE_BINS:
        active_bins = PRESSURE_BINS
    else:
        # Default: single all-levels pass (first element of PRESSURE_BINS)
        active_bins = [PRESSURE_BINS[0]]

    for idiag in diaglist:
        # Collect per-cycle data: one entry per cycle (may be NaN if missing)
        cycle_dts      = []
        gsi_omf_by_cyc  = []
        gsi_prs_by_cyc  = []
        jedi_omf_by_cyc = []
        jedi_prs_by_cyc = []

        for cycle in cycles:
            gsi_file  = get_diag_path(cycle, 'gsi',  idiag)
            jedi_file = get_diag_path(cycle, 'jedi', idiag)
            gsi_nc    = gsi_file.removesuffix('.gz')
            jedi_nc   = jedi_file.removesuffix('.gz')
            gsi_exists  = os.path.exists(gsi_file)  or os.path.exists(gsi_nc)
            jedi_exists = os.path.exists(jedi_file) or os.path.exists(jedi_nc)

            cycle_dt = datetime.strptime(cycle, '%Y%m%d%H')

            if DO_PAIR:
                if not gsi_exists or not jedi_exists:
                    print(f'[{cycle}] Missing one or both files for {idiag}, skipping (pair mode).')
                    continue

                try:
                    local_gsi  = ensure_unzipped_diag(gsi_file)
                    local_jedi = ensure_unzipped_diag(jedi_file)
                    if local_gsi is None or local_jedi is None:
                        print(f'[{cycle}] Failed to prepare one or both files for {idiag}, skipping.')
                        continue

                    gsi_data  = read_diag_arrays(local_gsi,  idiag)
                    jedi_data = read_diag_arrays(local_jedi, idiag)
                    gsi_omf, jedi_omf, prs = pair_omf(gsi_data, jedi_data)
                except Exception as exc:
                    print(f'[{cycle}] Failed reading/pairing {idiag}: {exc}')
                    continue

                if len(gsi_omf) == 0:
                    print(f'[{cycle}] No matched observations for {idiag}.')
                    continue

                cycle_dts.append(cycle_dt)
                gsi_omf_by_cyc.append(gsi_omf)
                gsi_prs_by_cyc.append(prs)
                jedi_omf_by_cyc.append(jedi_omf)
                jedi_prs_by_cyc.append(prs)

            else:  # unpaired
                if not gsi_exists and not jedi_exists:
                    print(f'[{cycle}] Missing both files for {idiag}, skipping.')
                    continue

                gsi_omf  = np.array([])
                gsi_prs  = np.array([])
                jedi_omf = np.array([])
                jedi_prs = np.array([])

                if gsi_exists:
                    try:
                        local_gsi = ensure_unzipped_diag(gsi_file)
                        if local_gsi is None:
                            print(f'[{cycle}] Failed to prepare GSI file for {idiag}.')
                        else:
                            gsi_data = read_diag_arrays(local_gsi, idiag)
                            gsi_omf  = gsi_data['omf']
                            gsi_prs  = gsi_data['pressure']
                    except Exception as exc:
                        print(f'[{cycle}] Failed reading GSI {idiag}: {exc}')

                if jedi_exists:
                    try:
                        local_jedi = ensure_unzipped_diag(jedi_file)
                        if local_jedi is None:
                            print(f'[{cycle}] Failed to prepare JEDI file for {idiag}.')
                        else:
                            jedi_data = read_diag_arrays(local_jedi, idiag)
                            jedi_omf  = jedi_data['omf']
                            jedi_prs  = jedi_data['pressure']
                    except Exception as exc:
                        print(f'[{cycle}] Failed reading JEDI {idiag}: {exc}')

                if len(gsi_omf) == 0 and len(jedi_omf) == 0:
                    continue

                cycle_dts.append(cycle_dt)
                gsi_omf_by_cyc.append(gsi_omf)
                gsi_prs_by_cyc.append(gsi_prs)
                jedi_omf_by_cyc.append(jedi_omf)
                jedi_prs_by_cyc.append(jedi_prs)

        if len(cycle_dts) == 0:
            print(f'No usable cycles for {idiag}, skipping plots.')
            continue

        # Produce one plot per active pressure bin
        for pmin, pmax, bin_label, bin_tag in active_bins:
            gsi_bias_ts   = []
            gsi_rmse_ts   = []
            gsi_cnt_ts    = []
            jedi_bias_ts  = []
            jedi_rmse_ts  = []
            jedi_cnt_ts   = []

            for gsi_omf, gsi_prs, jedi_omf, jedi_prs in zip(
                    gsi_omf_by_cyc, gsi_prs_by_cyc,
                    jedi_omf_by_cyc, jedi_prs_by_cyc):

                gb, gr, gc = compute_scalar_stats(gsi_omf,  gsi_prs,  pmin, pmax)
                jb, jr, jc = compute_scalar_stats(jedi_omf, jedi_prs, pmin, pmax)

                gsi_bias_ts.append(gb)
                gsi_rmse_ts.append(gr)
                gsi_cnt_ts.append(gc)
                jedi_bias_ts.append(jb)
                jedi_rmse_ts.append(jr)
                jedi_cnt_ts.append(jc)

            # Skip this bin if no valid data exists for either system
            if not any(np.isfinite(v) for v in gsi_bias_ts + jedi_bias_ts):
                print(f'No valid data for {idiag} bin "{bin_label}", skipping.')
                continue

            outfile = os.path.join(
                outdir,
                f'{idiag}_bias_rmse_timeseries_{pair_tag}_{bin_tag}_{cycle_label}.png'
            )
            plot_timeseries(
                cycle_dts,
                gsi_bias_ts, gsi_rmse_ts, gsi_cnt_ts,
                jedi_bias_ts, jedi_rmse_ts, jedi_cnt_ts,
                idiag, cycle_label, bin_label, outfile,
            )

    print('Done.')


if __name__ == '__main__':
    main()

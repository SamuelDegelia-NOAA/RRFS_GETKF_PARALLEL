import os
import subprocess
from subprocess import CalledProcessError, TimeoutExpired
from datetime import datetime, timedelta

import numpy as np
import matplotlib.pyplot as plt
from netCDF4 import Dataset

# Settings
firstcycle = '2026050601'  # YYYYMMDDHH
lastcycle = '2026050711'   # YYYYMMDDHH
archivedir = '/lfs/h2/emc/da/noscrub/samuel.degelia/PARALLEL_SAVE'
outdir = '.'

diaglist = [
    'diag_conv_t',
    'diag_conv_q',
    'diag_conv_uv',
]

DO_PAIR = True

# Pressure-bin settings (hPa)
PRESSURE_BIN_WIDTH_HPA = 50.0
PRESSURE_MIN_HPA = 25.0
PRESSURE_MAX_HPA = 1025.0
GUNZIP_TIMEOUT_SECONDS = 300

GSI_COLOR = 'red'
JEDI_COLOR = 'blue'

PLOT_NAMES = {
    'diag_conv_t': 'Temperature',
    'diag_conv_q': 'Humidity',
    'diag_conv_uv': 'Wind',
}


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
    last_dt = datetime.strptime(last, '%Y%m%d%H')
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

            u_fcst = u_obs - u_omf
            v_fcst = v_obs - v_omf

            obs_spd = np.sqrt(u_obs**2 + v_obs**2)
            fcst_spd = np.sqrt(u_fcst**2 + v_fcst**2)
            omf = obs_spd - fcst_spd
        else:
            omf = safe_read_var(ds, 'Obs_Minus_Forecast_adjusted')

    if idiag == 'diag_conv_q':
        # Match common humidity plotting units (kg/kg -> g/kg)
        omf = omf * 1000.0  # Convert kg/kg to g/kg

    keys = build_pairing_keys(lat, lon, hgt, tim)

    # Per-file quality filtering; pair_omf later applies additional joint filtering
    # on both systems after matching.
    mask = np.isfinite(prs) & np.isfinite(omf)
    keys = [keys[i] for i in np.flatnonzero(mask)]
    return {
        'keys': keys,
        'pressure': prs[mask],
        'omf': omf[mask],
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

    gsi_idx = np.array([gsi_map[key] for key in common_keys], dtype=int)
    jedi_idx = np.array([jedi_map[key] for key in common_keys], dtype=int)

    gsi_omf = gsi_data['omf'][gsi_idx]
    jedi_omf = jedi_data['omf'][jedi_idx]
    prs = gsi_data['pressure'][gsi_idx]

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


def build_pressure_bins():
    """Construct pressure bins and bin centers."""
    half_width = 0.5 * PRESSURE_BIN_WIDTH_HPA
    centers = np.arange(PRESSURE_BIN_WIDTH_HPA, 1000.0 + PRESSURE_BIN_WIDTH_HPA,
                        PRESSURE_BIN_WIDTH_HPA)
    bins = []
    for center in centers:
        low = center - half_width
        high = center + half_width
        if center == centers[0]:
            low = 0.0
        if center == centers[-1]:
            high = np.inf
        bins.append((low, high))
    return bins, centers


def compute_profile_stats(omf, prs, bins):
    """Compute pressure-binned bias/RMSE/count profiles from OMF-adjusted values."""
    bias = np.full(len(bins), np.nan)
    rmse = np.full(len(bins), np.nan)
    count = np.zeros(len(bins), dtype=int)

    for i, (plow, phigh) in enumerate(bins):
        mask = (prs >= plow) & (prs < phigh)
        vals = omf[mask]
        if len(vals) == 0:
            continue
        # OMF is Obs-Forecast; negate to report forecast bias (Forecast-Obs)
        forecast_minus_obs = -1.0 * vals
        bias[i] = np.mean(forecast_minus_obs)
        rmse[i] = np.sqrt(np.mean(vals**2))
        count[i] = len(vals)

    return bias, rmse, count


def plot_stat_profile(gsi_bias, gsi_rmse, jedi_bias, jedi_rmse, centers,
                      gsi_count, jedi_count, idiag, cycle_label, outpath):
    """Write one combined GSI/JEDI bias and RMSE vertical profile plot."""
    fig, ax = plt.subplots(figsize=(7, 9))

    ax.plot(gsi_rmse, centers, color=GSI_COLOR, linestyle='-',
            marker='o', linewidth=1.8, label=f'GSI RMSE (N={np.sum(gsi_count)})')
    ax.plot(gsi_bias, centers, color=GSI_COLOR, linestyle='--',
            marker='o', linewidth=1.8, label='GSI Bias')
    ax.plot(jedi_rmse, centers, color=JEDI_COLOR, linestyle='-',
            marker='o', linewidth=1.8, label=f'JEDI RMSE (N={np.sum(jedi_count)})')
    ax.plot(jedi_bias, centers, color=JEDI_COLOR, linestyle='--',
            marker='o', linewidth=1.8, label='JEDI Bias')
    ax.axvline(0.0, color='black', linewidth=1.0)

    ax.set_ylim(PRESSURE_MAX_HPA, PRESSURE_MIN_HPA)
    ax.set_ylabel('Pressure (hPa)')
    ax.set_xlabel('Forecast RMSE (solid) / Forecast bias (dashed)')
    ax.set_title(f'{PLOT_NAMES.get(idiag, idiag)} bias and RMSE profile\nCycles {cycle_label}')
    ax.grid(True, alpha=0.3)
    ax.legend(loc='best')
    fig.tight_layout()
    fig.savefig(outpath, dpi=150)
    plt.close(fig)
    print(f'Wrote {outpath}')


def plot_count_profile(gsi_count, jedi_count, centers, idiag, cycle_label, outpath):
    """Write count profile to help inspect per-bin sample sizes."""
    fig, ax = plt.subplots(figsize=(7, 9))

    ax.step(gsi_count, centers, where='mid', linewidth=1.5, color=GSI_COLOR,
            label=f'GSI total N={np.sum(gsi_count)}')
    ax.step(jedi_count, centers, where='mid', linewidth=1.5, color=JEDI_COLOR,
            label=f'JEDI total N={np.sum(jedi_count)}')

    ax.set_ylim(PRESSURE_MAX_HPA, PRESSURE_MIN_HPA)
    ax.set_ylabel('Pressure (hPa)')
    ax.set_xlabel('Observation count')
    ax.set_title(f'{PLOT_NAMES.get(idiag, idiag)} sample count profile\nCycles {cycle_label}')
    ax.grid(True, alpha=0.3)
    ax.legend(loc='best')
    fig.tight_layout()
    fig.savefig(outpath, dpi=150)
    plt.close(fig)
    print(f'Wrote {outpath}')


def main():
    os.makedirs(outdir, exist_ok=True)

    cycles = enumerate_cycles(firstcycle, lastcycle)
    cycle_label = f'{firstcycle}-{lastcycle}'
    bins, centers = build_pressure_bins()

    for idiag in diaglist:
        gsi_omf_all = []
        jedi_omf_all = []
        gsi_prs_all = []
        jedi_prs_all = []

        for cycle in cycles:
            gsi_file = get_diag_path(cycle, 'gsi', idiag)
            jedi_file = get_diag_path(cycle, 'jedi', idiag)
            gsi_nc = gsi_file.removesuffix('.gz')
            jedi_nc = jedi_file.removesuffix('.gz')
            gsi_exists = os.path.exists(gsi_file) or os.path.exists(gsi_nc)
            jedi_exists = os.path.exists(jedi_file) or os.path.exists(jedi_nc)

            if DO_PAIR:
                if not gsi_exists or not jedi_exists:
                    print(f'[{cycle}] Missing one or both files for {idiag}, skipping (pair mode).')
                    continue

                try:
                    local_gsi = ensure_unzipped_diag(gsi_file)
                    local_jedi = ensure_unzipped_diag(jedi_file)
                    if local_gsi is None or local_jedi is None:
                        print(f'[{cycle}] Failed to prepare one or both files for {idiag}, skipping.')
                        continue

                    gsi_data = read_diag_arrays(local_gsi, idiag)
                    jedi_data = read_diag_arrays(local_jedi, idiag)
                    gsi_omf, jedi_omf, prs = pair_omf(gsi_data, jedi_data)
                except Exception as exc:
                    print(f'[{cycle}] Failed reading/pairing {idiag}: {exc}')
                    continue

                if len(gsi_omf) == 0:
                    print(f'[{cycle}] No matched observations for {idiag}.')
                    continue

                gsi_omf_all.append(gsi_omf)
                jedi_omf_all.append(jedi_omf)
                gsi_prs_all.append(prs)
                jedi_prs_all.append(prs)
            else:
                if not gsi_exists and not jedi_exists:
                    print(f'[{cycle}] Missing both files for {idiag}, skipping.')
                    continue

                if gsi_exists:
                    try:
                        local_gsi = ensure_unzipped_diag(gsi_file)
                        if local_gsi is None:
                            print(f'[{cycle}] Failed to prepare GSI file for {idiag}.')
                            continue
                        gsi_data = read_diag_arrays(local_gsi, idiag)
                        gsi_omf_all.append(gsi_data['omf'])
                        gsi_prs_all.append(gsi_data['pressure'])
                    except Exception as exc:
                        print(f'[{cycle}] Failed reading GSI {idiag}: {exc}')

                if jedi_exists:
                    try:
                        local_jedi = ensure_unzipped_diag(jedi_file)
                        if local_jedi is None:
                            print(f'[{cycle}] Failed to prepare JEDI file for {idiag}.')
                            continue
                        jedi_data = read_diag_arrays(local_jedi, idiag)
                        jedi_omf_all.append(jedi_data['omf'])
                        jedi_prs_all.append(jedi_data['pressure'])
                    except Exception as exc:
                        print(f'[{cycle}] Failed reading JEDI {idiag}: {exc}')

        if len(gsi_omf_all) == 0 or len(jedi_omf_all) == 0:
            print(f'No usable observations for {idiag}, skipping plots.')
            continue

        gsi_omf_all = np.concatenate(gsi_omf_all)
        jedi_omf_all = np.concatenate(jedi_omf_all)
        gsi_prs_all = np.concatenate(gsi_prs_all)
        jedi_prs_all = np.concatenate(jedi_prs_all)

        gsi_bias, gsi_rmse, gsi_count = compute_profile_stats(gsi_omf_all, gsi_prs_all, bins)
        jedi_bias, jedi_rmse, jedi_count = compute_profile_stats(jedi_omf_all, jedi_prs_all, bins)

        pair_tag = 'paired' if DO_PAIR else 'unpaired'

        stat_file = os.path.join(outdir, f'{idiag}_bias_rmse_profile_{pair_tag}_{cycle_label}.png')
        cnt_file = os.path.join(outdir, f'{idiag}_count_profile_{pair_tag}_{cycle_label}.png')

        plot_stat_profile(gsi_bias, gsi_rmse, jedi_bias, jedi_rmse, centers,
                          gsi_count, jedi_count, idiag, cycle_label, stat_file)
        plot_count_profile(gsi_count, jedi_count, centers, idiag, cycle_label, cnt_file)

    print('Done.')


if __name__ == '__main__':
    main()

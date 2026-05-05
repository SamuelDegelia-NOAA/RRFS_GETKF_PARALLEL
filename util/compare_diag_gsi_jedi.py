import os
import numpy as np
from datetime import datetime
import matplotlib.pyplot as plt
from netCDF4 import Dataset

# Settings
cycletime = '2026050419'  # YYYYMMDDHH
jedibase = '/lfs/h2/emc/stmp/samuel.degelia/GETKF_PARALLEL'
gsibase = '/lfs/h1/ops/para/com/rrfs/v1.0'
diaglist = [
    'diag_conv_ps',
    'diag_conv_t',
    'diag_conv_q',
    'diag_conv_uv',
]

# ----------------------------
# Helper functions
# ----------------------------

def safe_read_var(ds, name):
    """Read a NetCDF variable and return a numpy array."""
    if name not in ds.variables:
        raise KeyError(f"Variable '{name}' not found in file")
    return np.asarray(ds.variables[name][:])


def compute_analysis_hofx(ds):
    """
    Analysis H(x) is computed as:
      Observation - Obs_Minus_Forecast_adjusted
    """
    obs = safe_read_var(ds, 'Observation')
    omf = safe_read_var(ds, 'Obs_Minus_Forecast_adjusted')
    return obs - omf


def build_pairing_keys(lat, lon, hgt, tim,
                       lat_decimals=4, lon_decimals=4,
                       hgt_decimals=1, tim_decimals=3):
    """
    Build robust pairing keys from metadata.

    We round values before constructing keys because small floating-point
    differences can occur between files even for the same observation.
    """
    lat_r = np.round(lat, lat_decimals)
    lon_r = np.round(lon, lon_decimals)
    hgt_r = np.round(hgt, hgt_decimals)
    tim_r = np.round(tim, tim_decimals)

    return list(zip(lat_r, lon_r, hgt_r, tim_r))


def extract_diag_data(ncfile):
    """Read metadata and computed analysis H(x) from a diag file."""
    with Dataset(ncfile, 'r') as ds:
        lat = safe_read_var(ds, 'Latitude')
        lon = safe_read_var(ds, 'Longitude')
        hgt = safe_read_var(ds, 'Height')
        tim = safe_read_var(ds, 'Time')
        hofx = compute_analysis_hofx(ds)

    keys = build_pairing_keys(lat, lon, hgt, tim)
    return keys, hofx, lat, lon, hgt, tim


def pair_observations(gsi_file, jedi_file):
    """
    Pair observations between GSI and JEDI using rounded metadata keys.

    If duplicate keys exist, only the first occurrence is used in each file.
    """
    gsi_keys, gsi_hofx, _, _, _, _ = extract_diag_data(gsi_file)
    jedi_keys, jedi_hofx, _, _, _, _ = extract_diag_data(jedi_file)

    gsi_map = {}
    for i, key in enumerate(gsi_keys):
        if key not in gsi_map:
            gsi_map[key] = i

    jedi_map = {}
    for i, key in enumerate(jedi_keys):
        if key not in jedi_map:
            jedi_map[key] = i

    common_keys = sorted(set(gsi_map.keys()) & set(jedi_map.keys()))

    if len(common_keys) == 0:
        return np.array([]), np.array([])

    gsi_vals = np.array([gsi_hofx[gsi_map[k]] for k in common_keys])
    jedi_vals = np.array([jedi_hofx[jedi_map[k]] for k in common_keys])

    good = np.isfinite(gsi_vals) & np.isfinite(jedi_vals)
    return gsi_vals[good], jedi_vals[good]


def one_to_one_plot(gsi_vals, jedi_vals, title, outfile):
    """Create a one-to-one scatter plot."""
    if len(gsi_vals) == 0:
        print(f'No paired observations found for {title}, skipping plot.')
        return

    vmin = min(np.min(gsi_vals), np.min(jedi_vals))
    vmax = max(np.max(gsi_vals), np.max(jedi_vals))

    # Add tiny padding so points are not on the frame
    pad = 0.02 * (vmax - vmin) if vmax > vmin else 1.0
    vmin -= pad
    vmax += pad

    corr = np.corrcoef(gsi_vals, jedi_vals)[0, 1] if len(gsi_vals) > 1 else np.nan
    bias = np.mean(jedi_vals - gsi_vals)
    rmse = np.sqrt(np.mean((jedi_vals - gsi_vals) ** 2))

    fig, ax = plt.subplots(figsize=(7, 7))
    ax.scatter(gsi_vals, jedi_vals, s=6, alpha=0.4, edgecolors='none')
    ax.plot([vmin, vmax], [vmin, vmax], 'r--', linewidth=1.5)

    ax.set_xlim(vmin, vmax)
    ax.set_ylim(vmin, vmax)
    ax.set_xlabel('GSI analysis H(x)')
    ax.set_ylabel('JEDI analysis H(x)')
    ax.set_title(title)

    stats = (
        f'N = {len(gsi_vals)}\n'
        f'Bias (JEDI-GSI) = {bias:.4f}\n'
        f'RMSE = {rmse:.4f}\n'
        f'Corr = {corr:.4f}'
    )
    ax.text(
        0.02, 0.98, stats,
        transform=ax.transAxes,
        ha='left', va='top',
        bbox=dict(facecolor='white', alpha=0.8, edgecolor='black')
    )

    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(outfile, dpi=150)
    plt.close(fig)

    print(f'Wrote {outfile}')


# ----------------------------
# Begin executable code
# ----------------------------

dateobj = datetime.strptime(cycletime, '%Y%m%d%H')
date = dateobj.strftime('%Y%m%d')
hour = dateobj.strftime('%H')
suffix = ''
if int(hour) in [7, 19]:
    suffix = '_spinup'

jedidir = f'{jedibase}/verif.{cycletime}'
gsidir = f'{gsibase}/enkfrrfs.{date}/{hour}{suffix}/ensmean/analysis'

# Create and move to a working directory
workdir = f'{jedibase}/compute_valid_{cycletime}'
if not os.path.exists(workdir):
    os.mkdir(workdir)
if not os.path.exists(f'{workdir}/gsi'):
    os.mkdir(f'{workdir}/gsi')
if not os.path.exists(f'{workdir}/jedi'):
    os.mkdir(f'{workdir}/jedi')
if not os.path.exists(f'{workdir}/plots'):
    os.mkdir(f'{workdir}/plots')

os.chdir(workdir)

# Copy diag files into the work directory
for idiag in diaglist:
    diag_file_gsi = f'{gsidir}/{idiag}_ges.{date}{hour}.nc4.gz'
    diag_file_jedi = f'{jedidir}/{idiag}_ges.{date}{hour}.nc4.gz'

    if not os.path.exists(diag_file_gsi) or not os.path.exists(diag_file_jedi):
        print('Cannot find one of:')
        print(diag_file_gsi)
        print('or')
        print(diag_file_jedi)
        print('skipping...')
        continue

    local_gsi_gz = f'gsi/{os.path.basename(diag_file_gsi)}'
    local_jedi_gz = f'jedi/{os.path.basename(diag_file_jedi)}'
    local_gsi_nc = local_gsi_gz[:-3]
    local_jedi_nc = local_jedi_gz[:-3]

    if not os.path.exists(local_gsi_nc):
        os.system(f'cp {diag_file_gsi} gsi/')
        os.system(f'gunzip -f {local_gsi_gz}')
    if not os.path.exists(local_jedi_nc):
        os.system(f'cp {diag_file_jedi} jedi/')
        os.system(f'gunzip -f {local_jedi_gz}')

# Plotting pass
plot_names = {
    'diag_conv_t': 'Temperature',
    'diag_conv_ps': 'Surface Pressure',
    'diag_conv_q': 'Humidity',
    'diag_conv_uv': 'Wind',
}

for idiag in diaglist:
    ncname = f'{idiag}_ges.{date}{hour}.nc4'
    gsi_file = f'gsi/{ncname}'
    jedi_file = f'jedi/{ncname}'

    if not os.path.exists(gsi_file) or not os.path.exists(jedi_file):
        print(f'Missing local files for {idiag}, skipping.')
        continue

    print(f'Pairing observations for {idiag}')
    gsi_vals, jedi_vals = pair_observations(gsi_file, jedi_file)

    print(f'Found {len(gsi_vals)} paired observations for {idiag}')
    title = f'{plot_names.get(idiag, idiag)} analysis H(x)\nCycle {cycletime}'
    outfile = f'plots/{idiag}_hofx_1to1_{cycletime}.png'
    one_to_one_plot(gsi_vals, jedi_vals, title, outfile)

print('Done.')

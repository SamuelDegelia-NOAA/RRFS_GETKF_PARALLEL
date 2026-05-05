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

# Pressure bins: (pmin, pmax, title_label, filename_tag)
# Bounds are inclusive (>=, <=); None means unbounded on that side.
PRESSURE_BINS = [
    (None,   None,   'All Levels',   'all'),
    (950.0, 1150.0, '1150\u2013950 hPa', '1150-950hPa'),
    (750.0,  950.0,  '950\u2013750 hPa',  '950-750hPa'),
    (550.0,  750.0,  '750\u2013550 hPa',  '750-550hPa'),
    (None,   550.0,  '<550 hPa',          'lt550hPa'),
]

# ----------------------------
# Helper functions
# ----------------------------

def safe_read_var(ds, name):
    """Read a NetCDF variable and return a numpy array."""
    if name not in ds.variables:
        raise KeyError(f"Variable '{name}' not found in file")
    return np.asarray(ds.variables[name][:])


def compute_analysis_hofx(ds, is_wind=False):
    """
    Compute analysis H(x) from a diagnostic dataset.

    For scalar variables:
        H(x) = Observation - Obs_Minus_Forecast_adjusted

    For wind (uv) files, compute wind-speed H(x) from u/v components:
        u_Hx = u_Observation - u_Obs_Minus_Forecast_adjusted
        v_Hx = v_Observation - v_Obs_Minus_Forecast_adjusted
        H(x) = sqrt(u_Hx**2 + v_Hx**2)
    """
    if is_wind:
        u_obs = safe_read_var(ds, 'u_Observation')
        u_omf = safe_read_var(ds, 'u_Obs_Minus_Forecast_adjusted')
        v_obs = safe_read_var(ds, 'v_Observation')
        v_omf = safe_read_var(ds, 'v_Obs_Minus_Forecast_adjusted')
        u_hofx = u_obs - u_omf
        v_hofx = v_obs - v_omf
        return np.sqrt(u_hofx**2 + v_hofx**2)
    else:
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


def extract_diag_data(ncfile, is_wind=False):
    """Read metadata and computed analysis H(x) from a diag file."""
    with Dataset(ncfile, 'r') as ds:
        lat = safe_read_var(ds, 'Latitude')
        lon = safe_read_var(ds, 'Longitude')
        hgt = safe_read_var(ds, 'Height')
        tim = safe_read_var(ds, 'Time')
        # Pressure for bin-filtering; may be absent in some file types
        try:
            prs = safe_read_var(ds, 'Pressure')
        except KeyError:
            prs = np.full(len(lat), np.nan)
        hofx = compute_analysis_hofx(ds, is_wind=is_wind)

    keys = build_pairing_keys(lat, lon, hgt, tim)
    return keys, hofx, lat, lon, hgt, tim, prs


def pair_observations(gsi_file, jedi_file, is_wind=False):
    """
    Pair observations between GSI and JEDI using rounded metadata keys.

    If duplicate keys exist, only the first occurrence is used in each file.

    Returns:
        gsi_vals  : paired GSI analysis H(x) values
        jedi_vals : paired JEDI analysis H(x) values
        pressures : observation pressures (hPa) from the GSI file
    """
    gsi_keys, gsi_hofx, _, _, _, _, gsi_prs = extract_diag_data(gsi_file, is_wind=is_wind)
    jedi_keys, jedi_hofx, _, _, _, _, _ = extract_diag_data(jedi_file, is_wind=is_wind)

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
        return np.array([]), np.array([]), np.array([])

    gsi_vals  = np.array([gsi_hofx[gsi_map[k]] for k in common_keys])
    jedi_vals = np.array([jedi_hofx[jedi_map[k]] for k in common_keys])
    pressures = np.array([gsi_prs[gsi_map[k]]   for k in common_keys])

    good = np.isfinite(gsi_vals) & np.isfinite(jedi_vals)
    return gsi_vals[good], jedi_vals[good], pressures[good]


def filter_by_pressure(gsi_vals, jedi_vals, pressures, pmin, pmax):
    """Return the subset of paired values within the given pressure range.

    Both bounds are inclusive; pass None for an unbounded side.
    Note: pressure values are in hPa; higher numbers correspond to lower
    altitudes (near surface).  pmin/pmax are the numerical lower and upper
    bounds of the pressure range, NOT altitude bounds.
    """
    mask = np.ones(len(gsi_vals), dtype=bool)
    if pmin is not None:
        mask &= pressures >= pmin
    if pmax is not None:
        mask &= pressures <= pmax
    return gsi_vals[mask], jedi_vals[mask]


def one_to_one_plot(gsi_vals, jedi_vals, title, outfile):
    """Create a one-to-one scatter plot.

    Features:
      - Scatter of paired GSI vs JEDI H(x) with observation count in legend
      - 1:1 reference line
      - Line of best fit with R value in legend
      - Bias and RMSE annotation box
    """
    if len(gsi_vals) == 0:
        print(f'No paired observations found for {title}, skipping plot.')
        return

    vmin = min(np.min(gsi_vals), np.min(jedi_vals))
    vmax = max(np.max(gsi_vals), np.max(jedi_vals))

    # Add tiny padding so points are not on the frame
    pad = 0.02 * (vmax - vmin) if vmax > vmin else 1.0
    vmin -= pad
    vmax += pad

    n    = len(gsi_vals)
    corr = np.corrcoef(gsi_vals, jedi_vals)[0, 1] if n > 1 else np.nan
    bias = np.mean(jedi_vals - gsi_vals)
    rmse = np.sqrt(np.mean((jedi_vals - gsi_vals) ** 2))

    fig, ax = plt.subplots(figsize=(7, 7))

    ax.scatter(gsi_vals, jedi_vals, s=6, alpha=0.4, edgecolors='none',
               label=f'Paired obs (N={n})')
    ax.plot([vmin, vmax], [vmin, vmax], 'r--', linewidth=1.5,
            label='1:1 line')

    # Line of best fit (requires at least 2 points)
    if n >= 2:
        coeffs = np.polyfit(gsi_vals, jedi_vals, 1)
        x_fit  = np.array([vmin, vmax])
        y_fit  = np.polyval(coeffs, x_fit)
        r_str  = f'{corr:.3f}' if np.isfinite(corr) else 'N/A'
        ax.plot(x_fit, y_fit, 'b-', linewidth=1.5,
                label=f'Best fit (r={r_str})')

    ax.set_xlim(vmin, vmax)
    ax.set_ylim(vmin, vmax)
    ax.set_xlabel('GSI analysis H(x)')
    ax.set_ylabel('JEDI analysis H(x)')
    ax.set_title(title)

    stats = (
        f'Bias (JEDI-GSI) = {bias:.4f}\n'
        f'RMSE = {rmse:.4f}'
    )
    ax.text(
        0.02, 0.98, stats,
        transform=ax.transAxes,
        ha='left', va='top',
        bbox=dict(facecolor='white', alpha=0.8, edgecolor='black')
    )

    ax.legend(loc='lower right')
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
    'diag_conv_t':  'Temperature',
    'diag_conv_ps': 'Surface Pressure',
    'diag_conv_q':  'Humidity',
    'diag_conv_uv': 'Wind Speed',
}

for idiag in diaglist:
    ncname    = f'{idiag}_ges.{date}{hour}.nc4'
    gsi_file  = f'gsi/{ncname}'
    jedi_file = f'jedi/{ncname}'

    if not os.path.exists(gsi_file) or not os.path.exists(jedi_file):
        print(f'Missing local files for {idiag}, skipping.')
        continue

    is_wind = 'uv' in idiag
    print(f'Pairing observations for {idiag}')
    gsi_vals, jedi_vals, pressures = pair_observations(gsi_file, jedi_file, is_wind=is_wind)
    print(f'Found {len(gsi_vals)} paired observations for {idiag}')

    varname = plot_names.get(idiag, idiag)
    for pmin, pmax, plabel, pfname in PRESSURE_BINS:
        g, j = filter_by_pressure(gsi_vals, jedi_vals, pressures, pmin, pmax)
        title   = f'{varname} analysis H(x) \u2014 {plabel}\nCycle {cycletime}'
        outfile = f'plots/{idiag}_hofx_1to1_{pfname}_{cycletime}.png'
        one_to_one_plot(g, j, title, outfile)

print('Done.')

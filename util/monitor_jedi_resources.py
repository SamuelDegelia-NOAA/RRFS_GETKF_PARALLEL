import re
import os
import numpy as np
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from datetime import datetime, timedelta

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
logdir = '/lfs/h2/emc/da/noscrub/samuel.degelia/parallel_getkf/logs'
start_cycle = '2026050503'
end_cycle   = '2026050517'
outdir      = '.'   # directory where plots are saved

# ---------------------------------------------------------------------------
# Regex patterns
# ---------------------------------------------------------------------------
# Matches lines like:
#   OOPS_STATS Run end  - Runtime:   2231.15 sec,  Memory: total: 21254.74 GB, ...
RE_RUN_END = re.compile(
    r'Run end.*Runtime:\s*([\d.]+)\s*sec.*Memory:\s*total:\s*([\d.]+)\s*GB',
    re.IGNORECASE,
)

# Matches lines like:
#   QC aircar_airTemperature_133 airTemperature: 13452 passed out of 13458 observations.
#   QC refl10cm equivalentReflectivityFactor: 644310 passed out of 644552 observations.
RE_QC_PASSED = re.compile(
    r'^QC\s+(\S+)\s+(\S+):\s+(\d+)\s+passed out of\s+\d+\s+observations',
)

# ---------------------------------------------------------------------------
# Scan cycles and parse log files
# ---------------------------------------------------------------------------
cycleobj = datetime.strptime(start_cycle, '%Y%m%d%H')
lastobj  = datetime.strptime(end_cycle,   '%Y%m%d%H')

cycles       = []   # datetime objects for x-axis labels
runtime      = []   # seconds (float or nan)
memory       = []   # total GB (float or nan)
radar_obs    = []   # int or nan
conv_obs     = []   # int or nan

while cycleobj <= lastobj:
    timestr = cycleobj.strftime('%Y%m%d%H')
    logfile = os.path.join(logdir, f'rrfs.{timestr}.jediout.tm00')

    cycles.append(cycleobj)

    if not os.path.exists(logfile):
        print(f'WARNING: log file not found for cycle {timestr}, skipping.')
        runtime.append(np.nan)
        memory.append(np.nan)
        radar_obs.append(np.nan)
        conv_obs.append(np.nan)
        cycleobj += timedelta(hours=1)
        continue

    cyc_runtime = np.nan
    cyc_memory  = np.nan
    cyc_radar   = 0
    cyc_conv    = 0

    with open(logfile) as fin:
        for line in fin:
            # --- runtime / memory ---
            m = RE_RUN_END.search(line)
            if m:
                cyc_runtime = float(m.group(1))
                cyc_memory  = float(m.group(2))
                continue

            # --- QC observation counts ---
            m = RE_QC_PASSED.match(line)
            if m:
                obs_type  = m.group(1)   # e.g. 'refl10cm' or 'aircar_airTemperature_133'
                obs_var   = m.group(2)   # e.g. 'equivalentReflectivityFactor'
                count     = int(m.group(3))
                if obs_type == 'refl10cm' and obs_var == 'equivalentReflectivityFactor':
                    cyc_radar += count
                else:
                    cyc_conv  += count

    runtime.append(cyc_runtime)
    memory.append(cyc_memory)
    radar_obs.append(cyc_radar if cyc_radar > 0 else np.nan)
    conv_obs.append(cyc_conv  if cyc_conv  > 0 else np.nan)

    cycleobj += timedelta(hours=1)

# ---------------------------------------------------------------------------
# Plotting helper
# ---------------------------------------------------------------------------
def _save_plot(fig, filename):
    path = os.path.join(outdir, filename)
    fig.savefig(path, bbox_inches='tight', dpi=300)
    print(f'Saved: {path}')


def _make_timeseries_plot(cycles, values, ylabel, title, filename, color='steelblue', yrange = None):
    fig, ax = plt.subplots(figsize=(12, 4))
    ax.plot(cycles, values, marker='o', color=color, linewidth=1.5)
    ax.set_xlabel('Cycle (UTC)')
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    if yrange:
      ax.set_ylim(yrange[0], yrange[1])
    ax.xaxis.set_major_formatter(mdates.DateFormatter('%m/%d %HZ'))
    ax.xaxis.set_major_locator(mdates.AutoDateLocator())
    plt.setp(ax.get_xticklabels(), rotation=45, ha='right')
    ax.grid(True, linestyle='--', alpha=0.5)
    fig.tight_layout()
    _save_plot(fig, filename)
    plt.show()
    plt.close(fig)

# ---------------------------------------------------------------------------
# Create plots
# ---------------------------------------------------------------------------
_make_timeseries_plot(
    cycles, runtime,
    ylabel   = 'Runtime (seconds)',
    title    = 'GETKF Runtime per Cycle',
    filename = 'getkf_runtime.png',
    color    = 'steelblue',
    yrange   = [0, 3000]
)

_make_timeseries_plot(
    cycles, memory,
    ylabel   = 'Total Memory (GB)',
    title    = 'GETKF Total Memory Usage per Cycle',
    filename = 'getkf_memory.png',
    color    = 'darkorange',
    yrange   = [0, 25000]
)

_make_timeseries_plot(
    cycles, radar_obs,
    ylabel   = 'Radar Observations Assimilated',
    title    = 'GETKF Radar (refl10cm equivalentReflectivityFactor) Obs per Cycle',
    filename = 'getkf_radar_obs.png',
    color    = 'firebrick',
)

_make_timeseries_plot(
    cycles, conv_obs,
    ylabel   = 'Conventional Observations Assimilated',
    title    = 'GETKF Conventional Obs per Cycle',
    filename = 'getkf_conv_obs.png',
    color    = 'seagreen',
)

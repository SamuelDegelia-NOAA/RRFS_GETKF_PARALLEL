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
start_cycle = '2026050406'
end_cycle   = '2026050613'
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
# Plotting helpers
# ---------------------------------------------------------------------------
def _save_plot(fig, filename):
    path = os.path.join(outdir, filename)
    fig.savefig(path, bbox_inches='tight', dpi=300)
    print(f'Saved: {path}')


def _format_time_axis(ax):
    ax.set_xlabel('Cycle (UTC)')
    ax.xaxis.set_major_formatter(mdates.DateFormatter('%m/%d %HZ'))
    ax.xaxis.set_major_locator(mdates.AutoDateLocator())
    plt.setp(ax.get_xticklabels(), rotation=45, ha='right')
    ax.grid(True, linestyle='--', alpha=0.5)


def _make_dual_axis_plot(
    cycles,
    left_values,
    right_values,
    left_ylabel,
    right_ylabel,
    title,
    filename,
    left_color='steelblue',
    right_color='darkorange',
    left_yrange=None,
    right_yrange=None,
):
    fig, ax_left = plt.subplots(figsize=(12, 4))
    ax_right = ax_left.twinx()

    line_left, = ax_left.plot(
        cycles, left_values,
        marker='o', color=left_color, linewidth=1.5, label=left_ylabel
    )
    line_right, = ax_right.plot(
        cycles, right_values,
        marker='o', color=right_color, linewidth=1.5, label=right_ylabel
    )

    ax_left.set_ylabel(left_ylabel, color=left_color)
    ax_right.set_ylabel(right_ylabel, color=right_color)
    ax_left.tick_params(axis='y', labelcolor=left_color)
    ax_right.tick_params(axis='y', labelcolor=right_color)
    ax_left.set_title(title)

    if left_yrange:
        ax_left.set_ylim(left_yrange[0], left_yrange[1])
    if right_yrange:
        ax_right.set_ylim(right_yrange[0], right_yrange[1])

    _format_time_axis(ax_left)

    lines = [line_left, line_right]
    labels = [line.get_label() for line in lines]
    ax_left.legend(lines, labels, loc='upper left')

    fig.tight_layout()
    _save_plot(fig, filename)
    plt.show()
    plt.close(fig)

# ---------------------------------------------------------------------------
# Create plots
# ---------------------------------------------------------------------------
_make_dual_axis_plot(
    cycles,
    runtime,
    memory,
    left_ylabel='Runtime (seconds)',
    right_ylabel='Total Memory (GB)',
    title='GETKF Runtime and Total Memory Usage per Cycle',
    filename='getkf_runtime_memory.png',
    left_color='steelblue',
    right_color='darkorange',
    left_yrange=[0, 3000],
    right_yrange=[0, 25000],
)

_make_dual_axis_plot(
    cycles,
    radar_obs,
    conv_obs,
    left_ylabel='Radar Observations Assimilated',
    right_ylabel='Conventional Observations Assimilated',
    title='GETKF Radar and Conventional Obs per Cycle',
    filename='getkf_obs_counts.png',
    left_color='firebrick',
    right_color='seagreen',
)

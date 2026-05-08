import glob
import re
import os
import numpy as np
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from datetime import datetime, timedelta

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
logdir = os.environ.get(
    'GETKF_MONITOR_LOGDIR',
    '/lfs/h2/emc/da/noscrub/samuel.degelia/parallel_getkf/logs',
)
start_cycle = os.environ.get('GETKF_MONITOR_START_CYCLE', '2026050406')
end_cycle   = os.environ.get('GETKF_MONITOR_END_CYCLE',   '2026050613')
outdir      = os.environ.get('GETKF_MONITOR_OUTDIR', '.')   # directory where plots are saved
overlay_gsi = os.environ.get('GETKF_MONITOR_OVERLAY_GSI', 'false').lower() in (
    '1', 'true', 'yes', 'on'
)
gsi_logdir  = os.environ.get('GETKF_MONITOR_GSI_LOGDIR', '/lfs/h1/ops/para/output')

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
RE_GSI_MEMORY = re.compile(
    r"^\d{2}/\d{2}/\d{4}\s+\d{2}:\d{2}:\d{2}\s+M\s+"
    r"(nid\d+)(?:\.\S+)?\s+cput=\d{2}:\d{2}:\d{2}\s+mem=(\d+)kb"
)
RE_GSI_START = re.compile(r"^\s*stime\s*=\s*(.+)")
RE_GSI_END   = re.compile(r"^\s*mtime\s*=\s*(.+)")
GSI_RUNTIME_LOGS = [
    'rrfs_enkf_calc_ensmean_{hour}.*',
    'rrfs_enkf_observer_gsi_ensmean_{hour}.*',
    'rrfs_enkf_observer_gsi_mem001_{hour}.*',
    'rrfs_enkf_updt_{hour}.*',
    'rrfs_enkf_radarref_{hour}.*',
]


def _get_first_glob(pattern):
    matches = glob.glob(pattern)
    if not matches:
        return None
    return matches[0]


def _parse_jedi_cycle(logfile, timestr):
    if not os.path.exists(logfile):
        print(f'WARNING: log file not found for cycle {timestr}, skipping.')
        return np.nan, np.nan, np.nan, np.nan

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

    return (
        cyc_runtime,
        cyc_memory,
        cyc_radar if cyc_radar > 0 else np.nan,
        cyc_conv  if cyc_conv  > 0 else np.nan,
    )


def _get_gsi_memory(infile):
    node_mem = {}

    with open(infile, 'r') as fin:
        for line in fin:
            match = RE_GSI_MEMORY.search(line)
            if match:
                node = match.group(1)
                mem_kb = int(match.group(2))
                node_mem[node] = mem_kb

    total_kb = sum(node_mem.values())
    return total_kb / 1024 / 1024


def _get_gsi_runtime(infile):
    start_time = None
    end_time = None

    with open(infile, 'r') as fin:
        for line in fin:
            start_match = RE_GSI_START.search(line)
            if start_match:
                start_time = datetime.strptime(
                    start_match.group(1).strip(),
                    '%a %b %d %H:%M:%S %Y',
                )

            end_match = RE_GSI_END.search(line)
            if end_match:
                end_time = datetime.strptime(
                    end_match.group(1).strip(),
                    '%a %b %d %H:%M:%S %Y',
                )

    if start_time is None or end_time is None:
        raise RuntimeError(
            f'Could not find stime and/or mtime in {infile}'
        )

    return (end_time - start_time).total_seconds()


def _parse_gsi_cycle(cycleobj):
    date = cycleobj.strftime('%Y%m%d')
    hour = cycleobj.strftime('%H')
    cycle_dir = os.path.join(gsi_logdir, date)

    memory_log = _get_first_glob(
        os.path.join(cycle_dir, f'rrfs_enkf_radarref_{hour}.*')
    )
    if memory_log is None:
        cyc_memory = np.nan
    else:
        try:
            cyc_memory = _get_gsi_memory(memory_log)
        except OSError as exc:
            print(f'WARNING: could not read GSI memory log for cycle {date}{hour}: {exc}')
            cyc_memory = np.nan

    runtime_logs = []
    for pattern in GSI_RUNTIME_LOGS:
        logfile = _get_first_glob(os.path.join(cycle_dir, pattern.format(hour=hour)))
        if logfile is None:
            print(f'WARNING: missing GSI runtime log for cycle {date}{hour}: {pattern.format(hour=hour)}')
            return np.nan, cyc_memory
        runtime_logs.append(logfile)

    try:
        cyc_runtime = sum(_get_gsi_runtime(logfile) for logfile in runtime_logs)
    except (OSError, RuntimeError, ValueError) as exc:
        print(f'WARNING: could not parse GSI runtime for cycle {date}{hour}: {exc}')
        cyc_runtime = np.nan

    return cyc_runtime, cyc_memory

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
gsi_runtime  = []   # seconds (float or nan)
gsi_memory   = []   # total GB (float or nan)

while cycleobj <= lastobj:
    timestr = cycleobj.strftime('%Y%m%d%H')
    logfile = os.path.join(logdir, f'rrfs.{timestr}.jediout.tm00')

    cycles.append(cycleobj)
    cyc_runtime, cyc_memory, cyc_radar, cyc_conv = _parse_jedi_cycle(logfile, timestr)

    runtime.append(cyc_runtime)
    memory.append(cyc_memory)
    radar_obs.append(cyc_radar)
    conv_obs.append(cyc_conv)

    if overlay_gsi:
        cyc_gsi_runtime, cyc_gsi_memory = _parse_gsi_cycle(cycleobj)
        gsi_runtime.append(cyc_gsi_runtime)
        gsi_memory.append(cyc_gsi_memory)

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
    left_label=None,
    right_label=None,
    left_overlay_values=None,
    right_overlay_values=None,
    left_overlay_label=None,
    right_overlay_label=None,
):
    fig, ax_left = plt.subplots(figsize=(12, 4))
    ax_right = ax_left.twinx()

    line_left, = ax_left.plot(
        cycles, left_values,
        marker='o', color=left_color, linewidth=1.5, label=left_label or left_ylabel
    )
    line_right, = ax_right.plot(
        cycles, right_values,
        marker='o', color=right_color, linewidth=1.5, label=right_label or right_ylabel
    )

    lines = [line_left, line_right]

    if left_overlay_values is not None:
        line_left_overlay, = ax_left.plot(
            cycles, left_overlay_values,
            marker='o', color=left_color, linewidth=1.5, linestyle='--',
            label=left_overlay_label or left_ylabel,
        )
        lines.append(line_left_overlay)

    if right_overlay_values is not None:
        line_right_overlay, = ax_right.plot(
            cycles, right_overlay_values,
            marker='o', color=right_color, linewidth=1.5, linestyle='--',
            label=right_overlay_label or right_ylabel,
        )
        lines.append(line_right_overlay)

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
    left_label='JEDI Runtime',
    right_label='JEDI Total Memory',
    left_overlay_values=gsi_runtime if overlay_gsi else None,
    right_overlay_values=gsi_memory if overlay_gsi else None,
    left_overlay_label='RRFSv1/GSI Runtime',
    right_overlay_label='RRFSv1/GSI Total Memory',
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

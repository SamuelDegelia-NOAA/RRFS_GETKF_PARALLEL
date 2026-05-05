import numpy as np
import sys, os
from datetime import datetime, timedelta

# Settings
logdir = '/lfs/h2/emc/da/noscrub/samuel.degelia/parallel_getkf/logs'
start_cycle = '2026050503'
end_cycle = '2026050517'

# Begin executable code

# Read log files to get memory and runtime
cycleobj = datetime.strptime(start_cycle, '%Y%m%d%H')
lastobj = datetime.strptime(end_cycle, '%Y%m%d%H')
runtime = []; memory = []
while cycleobj <= lastobj:
  timestr = cycleobj.strftime('%Y%m%d%H')
  logfile = f'{logdir}/rrfs.{timestr}.jediout.tm00'
  if not os.path.exists(logfile):
    runtime.append(np.nan)
    memory.append(np.nan)
  with open(logfile) as fin:
    data = fin.readlines()
    for idat in data:
      if 'Run end' in idat:
        split = idat.split()
        runtime.append(float(split[5])
        memory.append(float(split[9])
  cycleobj = cycleobj + timedelta(hours=1)


# Now create a time series plot
# One plot showing runtime by cycle
# Another plot showing memory usage by cycle

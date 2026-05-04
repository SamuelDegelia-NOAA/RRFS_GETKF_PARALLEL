import numpy as np
import sys, os, glob
from datetime import datetime

# Settings
cycletime = '2026050406' # YYYYMMDDHH
jedibase = '/lfs/h2/emc/stmp/samuel.degelia/GETKF_PARALLEL'
gsibase = '/lfs/h1/ops/para/com/rrfs/v1.0'
diaglist = ['diag_conv_ps', \
            'diag_conv_t', \
            'diag_conv_q', \
            'diag_conv_uv']

# Begin executable code
dateobj = datetime.strptime(cycletime, '%Y%m%d%H')
date = dateobj.strftime('%Y%m%d')
hour = dateobj.strftime('%H')
suffix = ''
if int(hour) in [7, 19]: suffix = '_spinup'
jedidir = f'{jedibase}/verif.{cycletime}'
gsidir = f'{gsibase}/enkfrrfs.{date}/{hour}{suffix}/ensmean/analysis'

# Create and move to a working directory
workdir = f'{jedibase}/compute_valid_{cycletime}'
if not os.path.exists(workdir):
  os.mkdir(workdir)
  os.mkdir(f'{workdir}/gsi')
  os.mkdir(f'{workdir}/jedi')
os.chdir(workdir)

# Copy diag files into the work directory
for idiag in diaglist:
  diag_file_gsi  = f'{gsidir}/{idiag}_ges.{date}{hour}.nc4.gz'
  diag_file_jedi = f'{jedidir}/{idiag}_ges.{date}{hour}.nc4.gz'
  if not os.path.exists(diag_file_gsi) or not os.path.exists(diag_file_jedi):
    print(f'Cannot find one of:')
    print(f'{diag_file_gsi}')
    print(f'or')
    print(f'{diag_file_jedi}')
    print(f'skipping...')
    continue
  os.system(f'cp {diag_file_gsi} gsi/')
  os.system(f'cp {diag_file_jedi} jedi/')
  diag_file = os.path.basename(diag_file_gsi)
  os.system(f'gunzip gsi/{diag_file}')
  os.system(f'gunzip jedi/{diag_file}')

# Now do some analysis
# For now, we will just plot 1-to-1 comparisons of hofx for the analysis
# We need to make sure that we find PAIRED observations between the GSI and JEDI diag file
# They might not have the same number of observations due to differences in QC, assimilation order, etc.
# So need to check the metadata to make sure we have PAIREd observations

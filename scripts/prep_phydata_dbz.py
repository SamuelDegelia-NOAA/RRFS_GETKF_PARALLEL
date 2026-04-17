#!/usr/bin/env python3
'''
   This script prepares phy_data.nc for ingestion in FV3-JEDI for radar DA
   Two things are done:
      1) Lower bound of refl is set to 0 dBZ
      2) Reverse vertical index so that index 0 corresponds to the model top
'''
import netCDF4 as nc
import numpy as np
import os, sys
import time

start_time = time.time()

# Copy original file
file_phydata = sys.argv[1]
file_prep = f'{file_phydata}_prepdbz'
print(f'[{time.strftime("%H:%M:%S")}] Starting processing: {file_phydata}')
copy_start = time.time()
os.system(f'cp {file_phydata} {file_prep}')
print(f'[{time.strftime("%H:%M:%S")}] Copy completed in {time.time() - copy_start:.2f}s')

# Read data
read_start = time.time()
nc_file      = nc.Dataset(file_prep, 'r+')
refl3d  = nc_file.variables['ref_f3d'][:]
print(f'[{time.strftime("%H:%M:%S")}] Read completed in {time.time() - read_start:.2f}s')

# Check if this is already been pre-processed and exit
rmin = np.nanmin(refl3d)
if rmin >= 0.0:
    sys.exit(f'Quitting early... {file_prep} seems to already be prepped.')
    sys.exit(f'    ReflMin = {rmin} dbz')

# Reverse vertical order for JEDI
proc_start = time.time()
refl3d_rev = refl3d[:,::-1,:,:]

# Set lower bound to 0 dBZ
neg_dbz = np.where(refl3d_rev<0.0)
refl3d_rev[neg_dbz] = 0.0

# Overwrite file
write_start = time.time()
nc_file.variables['ref_f3d'][:] = refl3d_rev
nc_file.close()
print(f'[{time.strftime("%H:%M:%S")}] Processing + write completed in {time.time() - write_start:.2f}s')

total_time = time.time() - start_time
print(f'[{time.strftime("%H:%M:%S")}] Total time: {total_time:.2f}s')

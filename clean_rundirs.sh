#!/bin/bash

# Small bash script to clean out the STMP directories once we are done with them

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

stmpdir="/lfs/h2/emc/stmp/samuel.degelia/GETKF_PARALLEL"
startcycle="2026050400"
endcycle="2026051900"

# ---------------------------------------------------------------------------
# Loop over hourly cycles and remove directories
# ---------------------------------------------------------------------------

current="${startcycle}"

while [[ "${current}" -le "${endcycle}" ]]; do

    # Remove analysis directories
    getkfdir=${stmpdir}/getkf.${current}
    bufrdir=${stmpdir}/bufr.${current}
    mrmsdir=${stmpdir}/mrms.${current}
    if [[ -d "${getkfdir}" ]]; then
        echo "Removing ${current} directories"
        rm -rf "${getkfdir}"
        rm -rf "${bufrdir}"
        rm -rf "${mrmsdir}"
    else
        echo "Directories at ${current} do not exist"
    fi

    # Remove verif directories
    verifdir=${stmpdir}/verif.${current}
    if [[ -d "${verifdir}" ]]; then
        echo "Removing verification ${current} directories"
        rm -rf "${verifdir}"
    else
        echo "Verification directories at ${current} do not exist"
    fi

    current=$(date -d "${current:0:8} ${current:8:2} +1 hour" +"%Y%m%d%H")

done

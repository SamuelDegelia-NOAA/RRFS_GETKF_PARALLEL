#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 <anldir> <baserundir> <YYYYMMDD> <HH> [retention_cycles]

Current cycle:
  - remove member increment files under <anldir>/mem*/*nc
  - remove prepdbz member files under <anldir>/data/inputs/mem*/*prepdbz

Older cycles:
  - remove ensemble-mean increment files inc_jedi*nc for
    getkf.YYYYMMDDHH directories <= cutoff cycle
EOF
}

if [[ $# -lt 4 || $# -gt 5 ]]; then
  usage
  exit 2
fi

anldir="$1"
baserundir="$2"
yyyymmdd="$3"
hh="$4"
retention_cycles="${5:-24}"

# Current-cycle cleanup: keep ensemble-mean increments for verification,
# remove only member-specific increment and prepdbz files.
rm -f "${anldir}"/mem*/*nc
rm -f "${anldir}"/data/inputs/mem*/*prepdbz

# Older-cycle cleanup: remove ensemble-mean increments once they are
# outside the retention window.
if ! [[ "${retention_cycles}" =~ ^[0-9]+$ ]] || ((retention_cycles < 1)); then
  echo "WARNING: clean_ensmean_retention_cycles='${retention_cycles}' is invalid; using 24"
  retention_cycles=24
fi

if ! [[ "${yyyymmdd}" =~ ^[0-9]{8}$ && "${hh}" =~ ^[0-9]{2}$ ]]; then
  echo "WARNING: invalid cycle timestamp YYYYMMDD='${yyyymmdd}' HH='${hh}'; skipping older-cycle ensemble-mean cleanup"
  exit 0
fi

if [[ -z "${baserundir}" ]]; then
  echo "WARNING: baserundir is not set; skipping older-cycle ensemble-mean cleanup"
  exit 0
fi

if ! current_cycle_epoch=$(date -u -d "${yyyymmdd:0:4}-${yyyymmdd:4:2}-${yyyymmdd:6:2} ${hh}:00:00" +%s); then
  echo "WARNING: unable to parse cycle timestamp ${yyyymmdd}${hh}; skipping older-cycle ensemble-mean cleanup"
  exit 0
fi

cutoff_cycle=$(date -u -d "@$((current_cycle_epoch - retention_cycles * 3600))" +%Y%m%d%H)
echo "Removing ensemble-mean increment files from cycles <= ${cutoff_cycle} (keeping last ${retention_cycles} hourly cycles)"

shopt -s nullglob
for old_cycle_dir in "${baserundir}"/getkf.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]; do
  old_cycle=${old_cycle_dir##*.}
  if [[ "${old_cycle}" =~ ^[0-9]{10}$ ]] && ((10#${old_cycle} <= 10#${cutoff_cycle})); then
    rm -f "${old_cycle_dir}"/inc_jedi*nc
  fi
done
shopt -u nullglob

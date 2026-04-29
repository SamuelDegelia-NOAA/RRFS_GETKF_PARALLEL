#!/bin/bash

compute_valid_cycle_from_enspath() {
    local enspath="$1"
    local hh="${enspath##*/}"
    local tmp="${enspath%/*}"
    local yyyymmdd="${tmp##*.}"
    local cycle_epoch

    cycle_epoch=$(date -u -d "${yyyymmdd:0:4}-${yyyymmdd:4:2}-${yyyymmdd:6:2} ${hh}:00:00" +%s) || return 1
    local timestamp
    timestamp=$(date -u -d "@$((cycle_epoch + 3600))" +%Y%m%d%H) || return 1

    VALID_YYYYMMDD=${timestamp:0:8}
    VALID_HH=${timestamp:8:2}
    VALID_YYYY=${VALID_YYYYMMDD:0:4}
    VALID_MM=${VALID_YYYYMMDD:4:2}
    VALID_DD=${VALID_YYYYMMDD:6:2}
    VALID_RESTART_PREFIX=$(date -u -d "@$((cycle_epoch + 3600))" +%Y%m%d.%H0000) || return 1
    return 0
}

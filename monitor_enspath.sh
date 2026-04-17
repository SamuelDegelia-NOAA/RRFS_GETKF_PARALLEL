#!/bin/bash

script_dir=$(cd "$(dirname "$0")" && pwd)
exec "${script_dir}/DRIVER_analysis_auto.sh" "$@"

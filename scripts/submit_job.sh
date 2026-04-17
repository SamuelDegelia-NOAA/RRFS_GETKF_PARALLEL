#!/bin/bash
# Builds and submits a PBS job that executes an exrrfs_* task script.
# All PBS resource settings are supplied as arguments so that DRIVER scripts
# own resource configuration rather than the individual task scripts.
#
# Usage:
#   submit_job.sh [options] <target_script>
#
# Options:
#   -N <name>           Job name                              (required)
#   -A <account>        PBS account string                    (required)
#   -q <queue>          PBS queue                             (default: dev)
#   -l select=<spec>    Node selection specification          (required)
#   -l walltime=<hms>   Wall-clock limit                      (required)
#   -l place=<str>      Placement directive                   (optional)
#   -o <logfile>        Output/error log file path            (required)
#   -v <key=val,...>    Variables to pass via qsub -v         (optional, repeatable)
#   -W depend=<dep>     PBS dependency string                 (optional)
#   --dry-run           Print the generated job script; do not submit
#
# Prints the qsub job ID to stdout on success.

set -euo pipefail

job_name=""
account=""
queue="dev"
select_spec=""
walltime=""
place=""
logfile=""
vars=()
depend=""
dry_run=0
target_script=""

usage() {
    sed -n 's/^# \{0,1\}//p' "$0" | sed -n '/^Usage:/,/^Prints/p'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -N) job_name="$2"; shift 2 ;;
        -A) account="$2"; shift 2 ;;
        -q) queue="$2"; shift 2 ;;
        -l)
            case "$2" in
                select=*)   select_spec="${2#select=}" ;;
                walltime=*) walltime="${2#walltime=}" ;;
                place=*)    place="${2#place=}" ;;
                *) echo "WARNING: unrecognized -l directive: $2" >&2 ;;
            esac
            shift 2 ;;
        -o) logfile="$2"; shift 2 ;;
        -v) vars+=("$2"); shift 2 ;;
        -W)
            case "$2" in
                depend=*) depend="${2#depend=}" ;;
                *) echo "WARNING: unrecognized -W option: $2" >&2 ;;
            esac
            shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        --) shift; break ;;
        -*) echo "ERROR: unknown option: $1" >&2; usage ;;
        *) break ;;
    esac
done

[[ $# -gt 0 ]] && target_script="$1"

# Validate required arguments
errors=0
[[ -z "$job_name" ]]      && { echo "ERROR: -N <job_name> is required" >&2;      errors=1; }
[[ -z "$account" ]]       && { echo "ERROR: -A <account> is required" >&2;       errors=1; }
[[ -z "$select_spec" ]]   && { echo "ERROR: -l select=<spec> is required" >&2;   errors=1; }
[[ -z "$walltime" ]]      && { echo "ERROR: -l walltime=<hms> is required" >&2;  errors=1; }
[[ -z "$logfile" ]]       && { echo "ERROR: -o <logfile> is required" >&2;       errors=1; }
[[ -z "$target_script" ]] && { echo "ERROR: <target_script> is required" >&2;    errors=1; }
[[ "$errors" -ne 0 ]] && exit 1

# Resolve target script to an absolute path
if [[ "${target_script}" != /* ]]; then
    target_script="$(pwd)/${target_script}"
fi
if [[ "$dry_run" -eq 0 && ! -f "$target_script" ]]; then
    echo "ERROR: target script not found: ${target_script}" >&2
    exit 1
fi

# Build qsub arguments
qsub_args=()
if [[ "${#vars[@]}" -gt 0 ]]; then
    combined_vars=$(IFS=,; echo "${vars[*]}")
    qsub_args+=(-v "$combined_vars")
fi
[[ -n "$depend" ]] && qsub_args+=(-W "depend=${depend}")

# Write the PBS job wrapper to a temp file
tmpjob=$(mktemp /tmp/pbs_job_XXXXXXXX.sh)
trap 'rm -f "${tmpjob}"' EXIT

{
    echo "#!/bin/bash"
    echo "#PBS -A ${account}"
    echo "#PBS -q ${queue}"
    echo "#PBS -l select=${select_spec}"
    echo "#PBS -l walltime=${walltime}"
    echo "#PBS -N ${job_name}"
    echo "#PBS -j oe -o ${logfile}"
    [[ -n "$place" ]] && echo "#PBS -l place=${place}"
    echo ""
    echo "cd \"\${PBS_O_WORKDIR}\""
    echo "exec bash \"${target_script}\""
} > "${tmpjob}"
chmod +x "${tmpjob}"

if [[ "$dry_run" -eq 1 ]]; then
    echo "--- BEGIN PBS JOB SCRIPT ---"
    cat "${tmpjob}"
    echo "--- END PBS JOB SCRIPT ---"
    echo ""
    if [[ "${#qsub_args[@]}" -gt 0 ]]; then
        echo "qsub command: qsub ${qsub_args[*]} ${tmpjob}"
    else
        echo "qsub command: qsub ${tmpjob}"
    fi
    exit 0
fi

# Submit and return the job ID
qsub "${qsub_args[@]}" "${tmpjob}"

#!/bin/bash
#
# Copyright 2021 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
#You may obtain a copy of the License at
#
#  https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
#limitations under the License.
#
# Runs a full monthly backup of the Perforce versioned (archived) files.
# Needs to execute as the user that runs p4d.

USAGE="usage: $(basename $0) p4_backup_bucket [options]
  options:
    [-d|--dry_run]    (dry run, do not backup) <default '$DRY_RUN'>
    [--logs_root]    (sets the logs root) <default '$LOGS_ROOT'>
    [-e|--is_edge]    (is Helix Server an Edge) <default '$IS_EDGE'>"

TODAY=$(date --iso-8601)
LOGS_ROOT="${HOME}/backup_logs"
MONTHLY_BACKUP_LOGS_TO_KEEP=7
PERFORCE_LOCAL_USER="perforce"

readonly TODAY

err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: ERROR: $*" >&2
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: ERROR: $*" >> "${CURRENT_LOG}"
}

log() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" | tee -a "${CURRENT_LOG}"
}

function usercheck () {
  # Validate script is executed as privileged user
  if [[ $(whoami) != "${PERFORCE_LOCAL_USER}" ]]; then
    echo "$0 must be ran as ${PERFORCE_LOCAL_USER} user, exiting"
    exit 2
  fi
}

#######################################
# Parses options and optionally prints usage.
# Globals:
#   USAGE
# Arguments:
#   Commnand-line arguments
#######################################
parse_options() {
  set +e
  OPTS="$(getopt -o "d,e" --long "dry_run,logs_root:,is_edge,help" -n "$(basename "$0")" -- "$@")"
  if [[ $? != 0 ]]; then
    echo -e "\n$USAGE"
    exit 1
  fi
  set -e

  eval set -- "$OPTS"
  while true ; do
    case "$1" in
      -d|--dry_run)    DRY_RUN=1; shift ;;
      -e|--is_edge)    IS_EDGE=1; shift ;;
      --logs_root)     LOGS_ROOT="$2"; shift 2 ;;
      --help)          echo "$USAGE"; exit 1 ;;
      --)              shift; break ;;
    esac
  done

  if [[ "$#" -lt "1" ]]; then
    echo "$USAGE"
    echo "Missing the required p4_backup_bucket parameter."
    exit 1
  fi

  shift $((OPTIND-1))
  P4_BACKUP_BUCKET=$1
}

#######################################
# Validates the Perforce environment prior to running the backup.
# Globals:
#   None
# Arguments:
#   Perforce Server ID string
#   Dry run flag
#######################################
validate_environment() {
  local server_id=$1
  local dry_run=$2

  if [[ ! -n "${P4PORT}" ]]; then
    err "P4PORT cannot be empty"
    exit 1
  fi

  if [[ ! -n "${server_id}" ]]; then
    err "Server ID cannot be empty"
    exit 1
  fi

  if [[ $dry_run -eq 1 ]]; then
    log "Executing in dry-run mode"
  fi
}

cleanup () {
  logs=$(find "${LOGS_ROOT}"/full_backup_log_* -type f -printf '%T@ %p\n' | sort -rn | cut -d" " -f 2 | tail -n +$((${MONTHLY_BACKUP_LOGS_TO_KEEP} + 1)))
  for i in ${logs}; do
    log "rm -rf ${i}"
    rm -rf "$i"
  done
}

main() {
  # Load the profile to pick up p4 client settings
  source "${HOME}/.profile"

  # Parse command-line options
  parse_options "$@"

  mkdir -p "${LOGS_ROOT}"

  CURRENT_LOG=${LOGS_ROOT}/full_backup_log_${TODAY}.txt

  readonly CURRENT_LOG
  readonly DRY_RUN
  readonly IS_EDGE
  readonly LOGS_ROOT
  readonly P4_BACKUP_BUCKET

  if [[ "${DRY_RUN}" -ne 1 ]]; then
    usercheck
  fi

  local server_id
  server_id=$(/usr/bin/p4 info | grep ServerID | awk '{print $2}')
  if [[ ! -n "${server_id}" && "${DRY_RUN}" -eq 1 ]]; then
    server_id=default
  fi

  local server_root
  server_root=$(/usr/bin/p4 info | grep "Server root:"  | awk '{print $3}')
  if [[ ! -d "${server_root}" ]]; then
    err "Could not find the Helix Core server root"
    exit 1
  fi

  local depot_root
  depot_root=$(p4d -r "${server_root}" -cshow | grep "server.depot.root = " | awk '{print $4}')

  local depot_path="${server_root}"/"${depot_root}"
  if [[ ! -d "${depot_path}" ]]; then
    err "Could not find the depot root"
    exit 1
  fi


  log "Beginning backup for server ${server_id}..."

  validate_environment "${server_id}" "${DRY_RUN}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "Will execute perform_backup ${server_id} ${depot_path} ${DRY_RUN} ${IS_EDGE}"
  else
    perform_backup "${server_id}" "${depot_path}" "${DRY_RUN}" "${IS_EDGE}"
    cleanup
  fi

  log "Backup of ${server_id} complete"
}

#######################################
# Executes the backup by copying all required files to GCS.
# Globals:
#   TODAY
# Arguments:
#   Perforce Server ID string
#   Dry run flag
#   Edge flag
#######################################
perform_backup() {
  set +e
  local server_id=$1
  local depot_path=$2
  local dry_run=$3
  local is_edge=$4

  # Backing up versioned files
  log "Backing up the versioned files at ${depot_path}"

  if [[ "${is_edge}" -eq 0 ]]; then
    gsutil \
      -m cp -r "${depot_path}" \
      gs://"${P4_BACKUP_BUCKET}"/"${TODAY}"/ 2>&1 \
      | tee -a "${CURRENT_LOG}"
  else
    gsutil \
      -m cp -r "${depot_path}/spec" \
      gs://"${P4_BACKUP_BUCKET}"/"${TODAY}"/"${server_id}"/spec 2>&1 \
      | tee -a "${CURRENT_LOG}"
  fi
  if [[ $? -ne 0 ]] ; then
    err "Could not backup archived files from ${depot_path}"
  fi
  set -e
}

main "$@"
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
# Runs a nightly backup of the Perforce instance.
# Needs to execute as the user that runs p4d.

USAGE="usage: $(basename "$0") p4_backup_bucket p4_incremental_backup_bucket offline_root [options]
  options:
    [-d|--dry_run]    (dry run, do not backup) <default '$DRY_RUN'>
    [--logs_root]    (sets the logs root) <default '$LOGS_ROOT'>
    [-e|--is_edge]    (is Helix Server an Edge) <default '$IS_EDGE'>"

TODAY=$(date --iso-8601)
LOGS_ROOT="${HOME}/backup_logs"
CHECKPOINTS_AND_JOURNALS_TO_KEEP=7
DAILY_BACKUP_LOGS_TO_KEEP=28
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

get_latest_checkpoint () {
  local server_id=$1
  local checkpoints_path=$2
  echo "$(find "${checkpoints_path}" -name "${server_id}.ckp.*" -type f -printf '%T@ %p\n' | sort -n | grep -v ".md5$" | tail -1 | cut -f2- -d" ")"
}

get_latest_journal () {
  local server_id=$1
  local checkpoints_path=$2
  echo "$(find "${checkpoints_path}" -name "${server_id}.jnl.*" -type f -printf '%T@ %p\n' | sort -n | grep -v ".md5$" | tail -1 | cut -f2- -d" ")"
}

get_free_space () {
  local file_path=$1
  local kb_size
  kb_size=$(df -k "${file_path}" | tail -1 | awk '{print $4}')
  echo $((${kb_size} * 1024))
}

get_file_size() {
  local file_path=$1
  ls -l "${file_path}" | awk '{print $5}'
}

cleanup () {
  local checkpoints_path=$1
  ckps=$(find "${checkpoints_path}" -name "*.ckp.*" -type f -printf '%T@ %p\n' | sort -rn | cut -d" " -f 2 | tail -n +$(((${CHECKPOINTS_AND_JOURNALS_TO_KEEP} * 2) + 1)))
  for i in ${ckps}; do
    log "rm -rf ${i}"
    rm -rf "$i"
  done

  jnls=$(find "${checkpoints_path}" -name "*.jnl.*" -type f -printf '%T@ %p\n' | sort -rn | cut -d" " -f 2 | tail -n +$((${CHECKPOINTS_AND_JOURNALS_TO_KEEP} + 1)))
  for i in ${jnls}; do
    log "rm -rf ${i}"
    rm -rf "$i"
  done

  logs=$(find "${LOGS_ROOT}"/backup_log_* -type f -printf '%T@ %p\n' | sort -rn | cut -d" " -f 2 | tail -n +$((${DAILY_BACKUP_LOGS_TO_KEEP} + 1)))
  for i in ${logs}; do
    log "rm -rf ${i}"
    rm -rf "$i"
  done
}

#######################################
# Parses options and optionally prints usage.
# Globals:
#   USAGE
# Arguments:
#   Command-line arguments
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

  if [[ "$#" -lt "3" ]]; then
    echo "$USAGE"
    echo "Missing required parameters p4_backup_bucket, p4_backup_bucket_incremental or offline_root."
    exit 1
  fi

  shift $((OPTIND-1))
  P4_BACKUP_BUCKET=$1
  shift
  P4_BACKUP_BUCKET_INCREMENTAL=$1
  shift
  OFFLINE_ROOT=$1
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
  local checkpoints_path=$2
  local dry_run=$3

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

  local previous_checkpoint
  previous_checkpoint=$(get_latest_checkpoint "${server_id}" "${checkpoints_path}")
  log "Previous checkpoint: ${previous_checkpoint}"
  if [[ ! -n "${previous_checkpoint}" ]]; then
    err "Previous checkpoint cannot be empty"
    exit 1
  fi

  log "Checking free space..."
  local free_space
  free_space=$(get_free_space "${previous_checkpoint}")
  local previous_checkpoint_size
  previous_checkpoint_size=$(get_file_size "${previous_checkpoint}")

  #TODO(/b150483841) Review the 20% threshold with Perforce Support.
  local free_percentage
  free_percentage=$(echo "${free_space}" "${previous_checkpoint_size}" | awk '{ printf "%0.0f", 100.0 * ($1 - $2 * 1.2) / $1 }')
  log "Free disk percentage estimated at ${free_percentage}%"
  if [[ "${free_percentage}" -lt 20 ]] ; then
    err "Estimated free space below 20% (${free_percentage}), exiting..."
    exit 1
  fi
}

#######################################
# Truncates the running journal and applies it to the offline_root.
# Globals:
#   None
# Arguments:
#   Perforce Server ID string
#   Path to previous truncated journal
#   Dry run flag
#######################################
rotate_journal() {
  local server_id=$1
  local server_root=$2
  local previous_journal=$3
  local dry_run=$4
  local is_edge=$5
  local sentinel=0
  local latest_journal

  if [[ -f /"${OFFLINE_ROOT}"/"${server_id}"/last_backed_up_journal ]] && [[ "${is_edge}" -eq 1 ]]; then
    previous_journal=$(cat "${OFFLINE_ROOT}"/"${server_id}"/last_backed_up_journal)
  elif [[ ! -f "${OFFLINE_ROOT}"/"${server_id}"/last_backed_up_journal ]] && [[ "${is_edge}" -eq 1 ]]; then
    sentinel=1
  fi

  # Rotate live journal and apply it to offline root database files.
  if [[ "${dry_run}" -eq 1 ]] && [[ "${is_edge}" -eq 0 ]]; then
    log "Will execute /usr/sbin/p4d -r ${server_root} -jj"
  elif [[ "${dry_run}" -eq 0 ]] && [[ "${is_edge}" -eq 0 ]]; then
    log "Current truncated journal: ${latest_journal}"
    /usr/sbin/p4d -r "${server_root}" -jj 2>&1 | tee -a "${CURRENT_LOG}"
  fi

  latest_journal=$(get_latest_journal "${server_id}" "${checkpoints_path}")

  if [[ ! -n "${latest_journal}" ]]; then
    err "Current truncated journal cannot be empty"
    exit 1
  fi

  if [[ "${previous_journal}" == "${latest_journal}" && "${dry_run}" -ne 1 && "${sentinel}" -eq 0 ]]; then
    err "Previous truncated journal cannot be equal to latest truncated journal"
    exit 1
  fi

  /usr/sbin/p4d -r "${OFFLINE_ROOT}"/"${server_id}" -jr "${latest_journal}" 2>&1 | tee -a "${CURRENT_LOG}"

  echo "${latest_journal}" > "${OFFLINE_ROOT}"/"${server_id}"/last_backed_up_journal
}

#######################################
# Validates the Perforce environment prior to running the backup.
# Globals:
#   None
# Arguments:
#   Perforce Server ID string
#   Path to previous checkpoint
#   Dry run flag
#######################################
create_checkpoint() {
  local server_id=$1
  local checkpoints_path=$2
  local previous_checkpoint=$3
  local dry_run=$4

  ckp_num=$(echo "${previous_checkpoint}" | sed 's/\.gz$//' | awk -F'.' '{print $NF}')
  new_num=$(((${ckp_num} + 1)))

  # Create a checkpoint
  if [[ "${dry_run}" -eq 1 ]]; then
    log "Will execute /usr/sbin/p4d -r ${OFFLINE_ROOT}/${server_id} -jd"
  else
    /usr/sbin/p4d -r "${OFFLINE_ROOT}"/"${server_id}" -jd "${server_id}.ckp.${new_num}" 2>&1 | tee -a "${CURRENT_LOG}"
    mv "${OFFLINE_ROOT}"/"${server_id}"/"${server_id}.ckp.${new_num}" "${checkpoints_path}"
    mv "${OFFLINE_ROOT}"/"${server_id}"/"${server_id}.ckp.${new_num}.md5" "${checkpoints_path}"
  fi

  local latest_checkpoint
  latest_checkpoint=$(get_latest_checkpoint "${server_id}" "${checkpoints_path}")
  log "Current checkpoint: ${latest_checkpoint}"

  if [[ ! -n "${latest_checkpoint}" ]]; then
    err "Current checkpoint cannot be empty"
    exit 1
  fi

  if [[ "${previous_checkpoint}" == "${latest_checkpoint}" && "${dry_run}" -ne 1 ]]; then
    err "Previous checkpoint cannot be equal to latest checkpoint"
    exit 1
  fi
}

#######################################
# Executes the backup by copying all required files to GCS.
# Globals:
#   TODAY
# Arguments:
#   Perforce Server ID string
#   Dry run flag
#######################################
perform_backup() {
  set +e
  local server_id=$1
  local checkpoints_path=$2
  local depot_path=$3
  local dry_run=$4
  local is_edge=$5

  local latest_checkpoint
  latest_checkpoint=$(get_latest_checkpoint "${server_id}" "${checkpoints_path}")

  # Validate the checkpoint
  log "Validating the checkpoint ${latest_checkpoint}"
  /usr/sbin/p4d -jv "$latest_checkpoint"
  if [[ $? -ne 0 ]] ; then
    err "Checkpoint validation failed, exiting..."
    exit 1
  fi

  local latest_journal
  latest_journal=$(get_latest_journal "${server_id}" "${checkpoints_path}")
  log "Current journal: ${latest_journal}"

  # Backup the checkpoint
  log "Backing up the checkpoint ${latest_checkpoint}"
  gsutil \
    cp "${latest_checkpoint}" \
    gs://"${P4_BACKUP_BUCKET}"/"${TODAY}"/ 2>&1 \
    | tee -a "${CURRENT_LOG}"
  if [[ $? -ne 0 ]] ; then
    err "Could not backup the checkpoint ${latest_checkpoint}"
  fi

  # Backup the checkpoint md5
  log "Backing up the checkpoint md5 ${latest_checkpoint}.md5"
  gsutil \
    cp "${latest_checkpoint}".md5 \
    gs://"${P4_BACKUP_BUCKET}"/"${TODAY}"/ 2>&1 \
    | tee -a "${CURRENT_LOG}"
  if [[ $? -ne 0 ]] ; then
    err "Could not backup the checkpoint md5 ${latest_checkpoint}.md5"
  fi

  # Backup the journal
  log "Backing up the journal ${latest_journal}"
  gsutil \
    cp "${latest_journal}" \
    gs://"${P4_BACKUP_BUCKET}"/"${TODAY}"/ 2>&1 \
    | tee -a "${CURRENT_LOG}"
  if [[ $? -ne 0 ]] ; then
    err "Could not backup the journal ${latest_journal}"
  fi

  # Backing up versioned files
  log "Backing up the versioned files at ${depot_path} to gs://${P4_BACKUP_BUCKET_INCREMENTAL}/${server_id}"

  if [[ "${is_edge}" -eq 0 ]]; then
    gsutil \
      -m rsync -d -r "${depot_path}" 2>&1 \
      gs://"${P4_BACKUP_BUCKET_INCREMENTAL}"/"${server_id}"/ 2>&1 \
      | tee -a "${CURRENT_LOG}"
  else
    gsutil \
      -m rsync -d -r "${depot_path}"/spec 2>&1 \
      gs://"${P4_BACKUP_BUCKET_INCREMENTAL}"/"${server_id}"/spec 2>&1 \
      | tee -a "${CURRENT_LOG}"
  fi

  if [[ $? -ne 0 ]] ; then
    err "Could not backup archived files from ${depot_path}"
  fi
  set -e
}

main() {
  # Load the profile to pick up p4 client settings
  source "${HOME}/.profile"

  # Parse command-line options
  parse_options "$@"

  mkdir -p "${LOGS_ROOT}"

  CURRENT_LOG=${LOGS_ROOT}/backup_log_${TODAY}.txt

  readonly CURRENT_LOG
  readonly DRY_RUN
  readonly LOGS_ROOT
  readonly P4_BACKUP_BUCKET
  readonly P4_BACKUP_BUCKET_INCREMENTAL
  readonly OFFLINE_ROOT
  readonly IS_EDGE

  if [[ "${DRY_RUN}" -ne 1 ]]; then
    usercheck
  fi

  if [[ ! -d "${OFFLINE_ROOT}" ]]; then
    err "Offline root does not exist at ${OFFLINE_ROOT}"
    exit 1
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

  local journal_path
  journal_path=$(p4d -r "${server_root}" -cshow | grep "P4JOURNAL = " | awk '{print $4}')
  if [[ ! -n "${journal_path}" ]]; then
    err "Could not find the journal path"
    exit 1
  fi

  local checkpoints_path
  checkpoints_path=$(dirname "${server_root}"/"${journal_path}")
  if [[ ! -d "${checkpoints_path}" ]]; then
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
  log "CURRENT_LOG: ${CURRENT_LOG}"
  log "DRY_RUN: ${DRY_RUN}"
  log "LOGS_ROOT: ${LOGS_ROOT}"
  log "P4_BACKUP_BUCKET: ${P4_BACKUP_BUCKET}"
  log "P4_BACKUP_BUCKET_INCREMENTAL: ${P4_BACKUP_BUCKET_INCREMENTAL}"
  log "OFFLINE_ROOT: ${OFFLINE_ROOT}"
  log "IS_EDGE: ${IS_EDGE}"
  log "checkpoints_path: ${checkpoints_path}"
  log "depot_path: ${depot_path}"  

  validate_environment "${server_id}" "${checkpoints_path}" "${DRY_RUN}"
  local previous_checkpoint
  local previous_journal
  previous_checkpoint=$(get_latest_checkpoint "${server_id}" "${checkpoints_path}")
  previous_journal=$(get_latest_journal "${server_id}" "${checkpoints_path}")
  rotate_journal "${server_id}" "${server_root}" "${previous_journal}" "${DRY_RUN}" "${IS_EDGE}"
  create_checkpoint "${server_id}" "${checkpoints_path}" "${previous_checkpoint}" "${DRY_RUN}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "Will execute perform_backup ${server_id} ${checkpoints_path} ${DRY_RUN} ${IS_EDGE}"
  else
    perform_backup "${server_id}" "${checkpoints_path}" "${depot_path}" "${DRY_RUN}" "${IS_EDGE}"
    cleanup "${checkpoints_path}"
  fi

  log "Backup of ${server_id} complete"
}

main "$@"

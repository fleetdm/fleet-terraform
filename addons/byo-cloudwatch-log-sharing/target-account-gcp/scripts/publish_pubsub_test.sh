#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID=""
TOPIC_ID=""
SERVICE_ACCOUNT_KEY_FILE=""
DATA_FILE=""
DEBUG=false

declare -a USER_MESSAGES=()

debug() {
  if [[ "${DEBUG}" == "true" ]]; then
    printf '[DEBUG] %s\n' "$1"
  fi
}

log() {
  printf '%s\n' "$1"
}

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") --project-id <project-id> --topic-id <topic-id> --service-account-key-file <path> [options]

Required:
  --project-id <value>                GCP project ID.
  --topic-id <value>                  Pub/Sub topic ID.
  --service-account-key-file <path>   Path to service account JSON key file.

Optional:
  --message <value>                   Add a message payload (repeatable).
  --data-file <path>                  NDJSON/plain-text file with one message per line.
  --debug                             Enable verbose diagnostics.
  --help                              Show this help.

Behavior:
  - If no --message or --data-file is provided, a built-in default dataset is published.
  - This script uses an isolated gcloud config directory and does not modify your active gcloud profile.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)
      PROJECT_ID="${2:-}"
      shift 2
      ;;
    --topic-id)
      TOPIC_ID="${2:-}"
      shift 2
      ;;
    --service-account-key-file)
      SERVICE_ACCOUNT_KEY_FILE="${2:-}"
      shift 2
      ;;
    --message)
      USER_MESSAGES+=("${2:-}")
      shift 2
      ;;
    --data-file)
      DATA_FILE="${2:-}"
      shift 2
      ;;
    --debug)
      DEBUG=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${PROJECT_ID}" || -z "${TOPIC_ID}" || -z "${SERVICE_ACCOUNT_KEY_FILE}" ]]; then
  printf 'Missing required arguments.\n\n' >&2
  usage >&2
  exit 1
fi

if [[ ! -f "${SERVICE_ACCOUNT_KEY_FILE}" ]]; then
  printf 'Service account key file not found: %s\n' "${SERVICE_ACCOUNT_KEY_FILE}" >&2
  exit 1
fi

if [[ -n "${DATA_FILE}" && ! -f "${DATA_FILE}" ]]; then
  printf 'Data file not found: %s\n' "${DATA_FILE}" >&2
  exit 1
fi

if ! command -v gcloud >/dev/null 2>&1; then
  printf 'gcloud is required but not installed or not in PATH.\n' >&2
  exit 1
fi

declare -a MESSAGES=()

if [[ -n "${DATA_FILE}" ]]; then
  debug "Loading messages from ${DATA_FILE}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    if [[ -z "${trimmed}" ]]; then
      continue
    fi
    MESSAGES+=("${line}")
  done < "${DATA_FILE}"
fi

if [[ ${#USER_MESSAGES[@]} -gt 0 ]]; then
  debug "Appending ${#USER_MESSAGES[@]} CLI-provided message(s)"
  MESSAGES+=("${USER_MESSAGES[@]}")
fi

if [[ ${#MESSAGES[@]} -eq 0 ]]; then
  debug "Using built-in default test dataset"
  MESSAGES=(
    '{"test_case":"default-1","source":"fleet-terraform","message":"hello from fleet cloudwatch log sharing","severity":"INFO"}'
    '{"test_case":"default-2","source":"fleet-terraform","message":"simulated warning log","severity":"WARN","component":"pubsub-bridge"}'
    '{"test_case":"default-3","source":"fleet-terraform","message":"simulated error log","severity":"ERROR","component":"pubsub-bridge"}'
  )
fi

TMP_GCLOUD_CONFIG_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_GCLOUD_CONFIG_DIR}"
}
trap cleanup EXIT

export CLOUDSDK_CONFIG="${TMP_GCLOUD_CONFIG_DIR}"

declare -a GCLOUD_VERBOSE_FLAG=()
if [[ "${DEBUG}" == "true" ]]; then
  GCLOUD_VERBOSE_FLAG=(--verbosity=debug)
  set -x
fi

log "Authenticating service account for project ${PROJECT_ID}"
gcloud "${GCLOUD_VERBOSE_FLAG[@]}" --quiet auth activate-service-account --key-file "${SERVICE_ACCOUNT_KEY_FILE}" --project "${PROJECT_ID}" >/dev/null

ACTIVE_ACCOUNT="$(gcloud "${GCLOUD_VERBOSE_FLAG[@]}" auth list --filter=status:ACTIVE --format='value(account)')"
log "Active gcloud account: ${ACTIVE_ACCOUNT}"
log "Publishing ${#MESSAGES[@]} message(s) to topic ${TOPIC_ID}"

PUBLISHED_COUNT=0
for idx in "${!MESSAGES[@]}"; do
  message="${MESSAGES[$idx]}"
  sequence="$((idx + 1))"
  debug "Publishing message ${sequence}: ${message}"

  gcloud "${GCLOUD_VERBOSE_FLAG[@]}" --project "${PROJECT_ID}" pubsub topics publish "${TOPIC_ID}" \
    --message "${message}" \
    --attribute "source=fleet-terraform-pubsub-test,sequence=${sequence}" >/dev/null

  PUBLISHED_COUNT="$((PUBLISHED_COUNT + 1))"
done

log "Published ${PUBLISHED_COUNT} message(s) successfully."

#!/usr/bin/env bash
#
# check-provider-bids.sh — Akash provider self-healing bid monitor
#
# Purpose:
#   Detect when the Akash provider pod is stuck (accumulating "incorrect account
#   sequence" errors while producing zero bids) and restart it as a self-heal.
#
# When to run:
#   Cron every 5-10 minutes. Example crontab entry:
#     */10 * * * * /path/to/check-provider-bids.sh
#
# Assumptions:
#   - Kubectl is on PATH and has access to the cluster
#   - The provider is deployed as a StatefulSet with a single pod
#   - The pod name matches the PROVIDER_POD variable below
#   - Log directory is writable
#
# Behaviour flags:
#   DRY_RUN=true   Log detections but do NOT delete the pod. Recommended for
#                  first-run validation on a new setup.
#   DRY_RUN=false  Actually delete the pod when detection fires. This is a
#                  destructive operation — the provider pod will restart and
#                  briefly reject bids during the restart window.
#
# Attribution:
#   Sanitized from production use at an Akash provider in the au-syd region.
#   See top-level README for context. PRs welcome.
#
set -euo pipefail

# --- Tunables ---
# Kubernetes identifiers — adjust for your setup
NAMESPACE="akash-services"
PROVIDER_POD="akash-provider-0"
PROVIDER_CONTAINER="provider"

# Log destination
LOGFILE="/var/log/provider-restart.log"

# Grace period before a young pod is eligible for restart (seconds).
# Prevents restart loops after a legitimate deployment or upgrade.
MIN_POD_AGE_SECONDS=300

# Log-scan windows
BID_LOOKBACK="30m"
SEQ_ERROR_LOOKBACK="10m"

# Detection thresholds
SEQ_ERROR_THRESHOLD=20   # sequence errors in the lookback window
BID_THRESHOLD=0          # bid completions expected (zero == stuck)

# Safety flag — set to "true" to run in monitor-only mode
DRY_RUN="${DRY_RUN:-false}"

# --- Setup ---
mkdir --parents "$(dirname "${LOGFILE}")"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "${LOGFILE}"
}

# --- Pod age check ---
# Skip if the pod is too young to have meaningful log history.
AGE_RAW=$(kubectl get pod "${PROVIDER_POD}" -n "${NAMESPACE}" --no-headers 2>/dev/null | awk '{print $5}' || echo "")
AGE_SECONDS=$(echo "${AGE_RAW}" | sed 's/m//' | awk -F: '{if(NF==1) print $1*60; else print $1*3600+$2*60}')

if [[ "${AGE_SECONDS:-0}" -lt "${MIN_POD_AGE_SECONDS}" ]]; then
  log "skip: pod too young (age=${AGE_SECONDS}s, min=${MIN_POD_AGE_SECONDS}s)"
  exit 0
fi

# --- Signal collection ---
BIDS=$(kubectl logs -n "${NAMESPACE}" "${PROVIDER_POD}" -c "${PROVIDER_CONTAINER}" \
  --since="${BID_LOOKBACK}" 2>/dev/null | grep --count "bid complete" || true)

SEQ_ERRORS=$(kubectl logs -n "${NAMESPACE}" "${PROVIDER_POD}" -c "${PROVIDER_CONTAINER}" \
  --since="${SEQ_ERROR_LOOKBACK}" 2>/dev/null | grep --count "incorrect account sequence" || true)

log "check: bids=${BIDS} seq_errors=${SEQ_ERRORS}"

# --- Decision ---
if [[ "${SEQ_ERRORS}" -gt "${SEQ_ERROR_THRESHOLD}" ]] && [[ "${BIDS}" -eq "${BID_THRESHOLD}" ]]; then
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DETECT (dry-run): would restart pod (seq=${SEQ_ERRORS}, bids=${BIDS})"
  else
    log "RESTART: seq=${SEQ_ERRORS} bids=${BIDS} — deleting pod ${PROVIDER_POD}"
    kubectl delete pod "${PROVIDER_POD}" -n "${NAMESPACE}" --force --grace-period=0 2>/dev/null || true
  fi
fi

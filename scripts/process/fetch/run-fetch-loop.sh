#!/bin/bash
# =============================================================================
# PRECISE Hub - Fetch (Request) Loop Runner
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROCESS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROCESS_DIR}/config.sh"
source "${PROCESS_DIR}/logging.sh"

cleanup() {
  log_info "Stopping fetch loop..."
  rm -f "${FETCH_LOCK_FILE}"
  exit 0
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM

# Check if already running
if [[ -f "${FETCH_LOCK_FILE}" ]]; then
  pid=$(cat "${FETCH_LOCK_FILE}" 2>/dev/null)
  if kill -0 "$pid" 2>/dev/null; then
    log_error "Fetch processor is already running (PID: ${pid})"
    exit 1
  else
    log_warn "Stale lock file found, removing..."
    rm -f "${FETCH_LOCK_FILE}"
  fi
fi

# Create lock file
echo $$ > "${FETCH_LOCK_FILE}"

log_info "=== PRECISE Hub Fetch Processor Started ==="
log_info "Loop interval: ${FETCH_LOOP_INTERVAL} seconds"
log_info "Max package size: ${FETCH_MAX_SIZE}"
log_info "Download expiry: ${FETCH_EXPIRY_DAYS} days"
log_info "Organizations: ${ORGANIZATIONS}"
log_info "Press Ctrl+C to stop"

# Main loop
while true; do
  "${SCRIPT_DIR}/process-fetch-requests.sh" || {
    log_error "Fetch processing cycle failed, continuing..."
  }

  sleep "${FETCH_LOOP_INTERVAL}"
done

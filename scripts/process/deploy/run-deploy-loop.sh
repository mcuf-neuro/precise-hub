#!/bin/bash
# =============================================================================
# PRECISE Hub - Deploy (Upload) Loop Runner
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROCESS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROCESS_DIR}/config.sh"
source "${PROCESS_DIR}/logging.sh"

cleanup() {
  log_info "Stopping deploy loop..."
  rm -f "${DEPLOY_LOCK_FILE}"
  exit 0
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM

# Check if already running
if [[ -f "${DEPLOY_LOCK_FILE}" ]]; then
  pid=$(cat "${DEPLOY_LOCK_FILE}" 2>/dev/null)
  if kill -0 "$pid" 2>/dev/null; then
    log_error "Deploy processor is already running (PID: ${pid})"
    exit 1
  else
    log_warn "Stale lock file found, removing..."
    rm -f "${DEPLOY_LOCK_FILE}"
  fi
fi

# Create lock file
echo $$ > "${DEPLOY_LOCK_FILE}"

log_info "=== PRECISE Hub Deploy Processor Started ==="
log_info "Loop interval: ${DEPLOY_LOOP_INTERVAL} seconds"
log_info "Stability threshold: ${STABILITY_THRESHOLD} seconds"
log_info "Organizations: ${ORGANIZATIONS}"
log_info "Upload sources: ${UPLOAD_SOURCES}"
log_info "Press Ctrl+C to stop"

# Main loop
while true; do
  "${SCRIPT_DIR}/process-uploads.sh" || {
    log_error "Deploy processing cycle failed, continuing..."
  }

  sleep "${DEPLOY_LOOP_INTERVAL}"
done

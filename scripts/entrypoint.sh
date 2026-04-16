#!/bin/bash
set -euo pipefail

PROCESS_DIR="/opt/precise-hub/process"

echo "=== PRECISE Hub Starting ==="

echo "Checking bind-mounted volumes..."
for mnt in /mnt/deg /mnt/data-lake; do
  if [[ ! -d "$mnt" ]] || [[ -z "$(ls -A "$mnt" 2>/dev/null)" ]]; then
    echo "ERROR: ${mnt} is missing or empty. Mount it on the host first."
    exit 1
  fi
  echo "  ${mnt} — OK"
done

# Forschungsspeicher is optional (for manual imports)
if [[ -d /mnt/forschungsspeicher ]] && [[ -n "$(ls -A /mnt/forschungsspeicher 2>/dev/null)" ]]; then
  echo "  /mnt/forschungsspeicher — OK"
else
  echo "  /mnt/forschungsspeicher — not mounted (optional)"
fi

# Start both processing loops in the background
"${PROCESS_DIR}/deploy/run-deploy-loop.sh" &
DEPLOY_PID=$!

"${PROCESS_DIR}/fetch/run-fetch-loop.sh" &
FETCH_PID=$!

# If either loop exits, stop everything and let the orchestrator restart us
wait -n "$DEPLOY_PID" "$FETCH_PID" 2>/dev/null
echo "ERROR: A processing loop exited unexpectedly. Shutting down."
kill "$DEPLOY_PID" "$FETCH_PID" 2>/dev/null
wait
exit 1

#!/bin/bash
# =============================================================================
# PRECISE Hub - Check Mounts (run on the host VM, not in the container)
# Verifies that all storage volumes are currently mounted and accessible.
# Does NOT mount anything — use mount-all.sh for that.
# Usage: sudo ./scripts/host/test-mounts.sh
# =============================================================================
set -euo pipefail

PASS=0
FAIL=0

check_mount() {
  local name="$1"
  local mount_point="$2"

  echo ""
  echo "--- ${name} (${mount_point}) ---"

  if ! mountpoint -q "$mount_point" 2>/dev/null; then
    echo "  FAIL: not mounted"
    FAIL=$((FAIL + 1))
    return
  fi

  echo "  $(df -h "$mount_point" | tail -1)"

  if ls "$mount_point" >/dev/null 2>&1; then
    local count=$(ls -1 "$mount_point" 2>/dev/null | wc -l)
    echo "  Contents: ${count} items in root directory"
  else
    echo "  WARN: mounted but could not list directory contents"
  fi

  echo "  PASS"
  PASS=$((PASS + 1))
}

echo "=== PRECISE Hub - Mount Status ==="

check_mount "Forschungsspeicher (CIFS/AD)" "/mnt/forschungsspeicher"
check_mount "Data Exchange Gateway (WebDAV)" "/mnt/deg"
check_mount "Data Lake (TrueNAS/CIFS)" "/mnt/data-lake"

echo ""
echo "=== Results: ${PASS} mounted, ${FAIL} not mounted ==="

if [[ $FAIL -gt 0 ]]; then
  echo "Run mount-all.sh to mount missing volumes."
  exit 1
fi

echo "All mounts OK. Ready to run the container."

#!/bin/bash
# =============================================================================
# PRECISE Hub - Mount All Shares
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Mounting all shares..."
"${SCRIPT_DIR}/mount-forschungsspeicher.sh"
"${SCRIPT_DIR}/mount-deg.sh"
"${SCRIPT_DIR}/mount-data-lake.sh"
echo ""
echo "All shares mounted successfully:"
df -h | grep /mnt

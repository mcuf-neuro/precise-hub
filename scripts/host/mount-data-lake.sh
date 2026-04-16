#!/bin/bash
# =============================================================================
# PRECISE Hub - Mount Data Lake (TrueNAS via CIFS)
# =============================================================================
set -e

: "${TRUENAS_USERNAME:?TRUENAS_USERNAME not set}"
: "${TRUENAS_PASSWORD:?TRUENAS_PASSWORD not set}"
: "${TRUENAS_PATH:?TRUENAS_PATH not set}"

MOUNT_POINT="/mnt/data-lake"

CRED_FILE=$(mktemp)
cat > "$CRED_FILE" <<EOF
username=$TRUENAS_USERNAME
password=$TRUENAS_PASSWORD
EOF
chmod 600 "$CRED_FILE"

# UID/GID of the user that will run the container (default: 1000 = first non-root user)
MOUNT_UID=${MOUNT_UID:-1000}
MOUNT_GID=${MOUNT_GID:-1000}

mkdir -p "$MOUNT_POINT"
mount -t cifs "$TRUENAS_PATH" "$MOUNT_POINT" \
  -o credentials="$CRED_FILE",vers=3.0,uid=$MOUNT_UID,gid=$MOUNT_GID,noperm

rm -f "$CRED_FILE"

echo "Data Lake mounted successfully at ${MOUNT_POINT}"

#!/bin/bash
# =============================================================================
# PRECISE Hub - Mount Backup Storage (iCAS archive pool via CIFS/AD)
#
# Write-once archive with autocommit: a file is immutable once it is written,
# and an interrupted transfer leaves a file that cannot be removed. Do not use
# this mount for anything but the backup process.
# =============================================================================
set -e

: "${BACKUP_USERNAME:?BACKUP_USERNAME not set}"
: "${BACKUP_PASSWORD:?BACKUP_PASSWORD not set}"
: "${BACKUP_PATH:?BACKUP_PATH not set}"
BACKUP_DOMAIN="${BACKUP_DOMAIN:-ad.uniklinik-freiburg.de}"

MOUNT_POINT="/mnt/backup"

CRED_FILE=$(mktemp)
trap 'rm -f "$CRED_FILE"' EXIT
chmod 600 "$CRED_FILE"
cat > "$CRED_FILE" <<EOF
username=$BACKUP_USERNAME
password=$BACKUP_PASSWORD
domain=$BACKUP_DOMAIN
EOF

MOUNT_UID=${MOUNT_UID:-1000}
MOUNT_GID=${MOUNT_GID:-1000}

mkdir -p "$MOUNT_POINT"
# seal: SMB3 encryption in transit (the mount fails if the server does not support it)
mount -t cifs "$BACKUP_PATH" "$MOUNT_POINT" \
  -o credentials="$CRED_FILE",vers=3.1.1,sec=ntlmssp,seal,uid=$MOUNT_UID,gid=$MOUNT_GID,noperm

echo "Backup storage mounted successfully at ${MOUNT_POINT}"

#!/bin/bash
# =============================================================================
# PRECISE Hub - Mount Forschungsspeicher (UKF local research storage via CIFS)
# =============================================================================
set -e

: "${LDAP_USERNAME:?LDAP_USERNAME not set}"
: "${LDAP_PASSWORD:?LDAP_PASSWORD not set}"
: "${LDAP_PATH:?LDAP_PATH not set}"

MOUNT_POINT="/mnt/forschungsspeicher"

MOUNT_UID=${MOUNT_UID:-1000}
MOUNT_GID=${MOUNT_GID:-1000}

mkdir -p "$MOUNT_POINT"
mount -t cifs "$LDAP_PATH" "$MOUNT_POINT" \
  -o username="$LDAP_USERNAME",password="$LDAP_PASSWORD",domain=AD,vers=3.0,sec=ntlmssp,seal,uid=$MOUNT_UID,gid=$MOUNT_GID,ro

echo "Forschungsspeicher mounted successfully at ${MOUNT_POINT}"

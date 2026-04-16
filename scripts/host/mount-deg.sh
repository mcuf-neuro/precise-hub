#!/bin/bash
# =============================================================================
# PRECISE Hub - Mount Data Exchange Gateway (DEG via WebDAV)
# =============================================================================
set -e

: "${WEBDAV_USERNAME:?WEBDAV_USERNAME not set}"
: "${WEBDAV_PASSWORD:?WEBDAV_PASSWORD not set}"
: "${WEBDAV_PATH:?WEBDAV_PATH not set}"

MOUNT_POINT="/mnt/deg"

MOUNT_UID=${MOUNT_UID:-1000}
MOUNT_GID=${MOUNT_GID:-1000}

mkdir -p "$MOUNT_POINT"
mount -t davfs "$WEBDAV_PATH" "$MOUNT_POINT" \
  -o uid=$MOUNT_UID,gid=$MOUNT_GID,file_mode=0664,dir_mode=0775,username="$WEBDAV_USERNAME",password="$WEBDAV_PASSWORD"

echo "Data Exchange Gateway mounted successfully at ${MOUNT_POINT}"

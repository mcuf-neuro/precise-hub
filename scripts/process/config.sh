#!/bin/bash
# =============================================================================
# PRECISE Hub - Configuration
# =============================================================================

# Organization codes (3-letter uppercase)
ORGANIZATIONS="UKK MUV UKF UHD MUI UKE FAU"

# Mount points (override via environment for testing, e.g. DEG_PATH=/tmp/deg)
DEG_PATH="${DEG_PATH:-/mnt/deg}"
FORSCHUNGSSPEICHER_PATH="${FORSCHUNGSSPEICHER_PATH:-/mnt/forschungsspeicher}"
DATA_LAKE_PATH="${DATA_LAKE_PATH:-/mnt/data-lake}"

# Upload sources: the processor scans these paths for ORG/upload/ folders.
# DEG: external partners (all organizations)
# Forschungsspeicher: UKF local imports (same package format as DEG)
UPLOAD_SOURCES="${DEG_PATH} ${FORSCHUNGSSPEICHER_PATH}"

# Derived paths (all on the Data Lake)
TMP_PATH="${DATA_LAKE_PATH}/tmp"
LOG_PATH="${DATA_LAKE_PATH}/logs"
DATA_PATH="${DATA_LAKE_PATH}/Data"

# Local staging area (on the hub VM, avoids network round-trips during processing).
# Each loop owns a subdirectory and only ever cleans its own.
LOCAL_STAGING_PATH="${LOCAL_STAGING_PATH:-/var/tmp/precise-hub}"
DEPLOY_STAGING_PATH="${LOCAL_STAGING_PATH}/deploy"
FETCH_STAGING_PATH="${LOCAL_STAGING_PATH}/fetch"
STATE_PATH="${LOCAL_STAGING_PATH}/state"   # small bookkeeping files, survives restarts

# Timing (in seconds)
DEPLOY_LOOP_INTERVAL=10    # How often to check for new uploads (10s for testing)
STABILITY_THRESHOLD=60     # File must be unchanged for this long (60s for testing)

# Fetch settings
FETCH_LOOP_INTERVAL=30     # How often to check for new fetch requests (seconds)
FETCH_MAX_SIZE="20G"       # Maximum total (uncompressed) size of one fetch request
FETCH_MAX_CASE_SIZE="4G"   # Maximum (uncompressed) size of a single case package; larger cases are skipped
DOWNLOAD_EXPIRY_HOURS=48   # Hours after which download packages are auto-deleted

# Disk space
# DEG capacity for the free-space check. Leave empty to trust "df" on the DEG mount
# (only correct if the WebDAV server reports quota); otherwise set e.g. "500G" and
# the hub computes free space as capacity minus the files in all upload/download folders.
DEG_CAPACITY_BYTES=""
DEG_SPACE_MARGIN="1G"      # Always keep at least this much free on the DEG
STAGING_SPACE_FACTOR=4     # Local staging must have this many times the archive size free

# Supported archive extensions
ARCHIVE_EXTENSIONS="zip tar.gz tar.zst"

# Lock files
DEPLOY_LOCK_FILE="${DEPLOY_LOCK_FILE:-/tmp/precise-deploy.lock}"
FETCH_LOCK_FILE="${FETCH_LOCK_FILE:-/tmp/precise-fetch.lock}"

# Shard size (number of examination folders per shard)
SHARD_SIZE=100

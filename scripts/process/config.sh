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
INDEX_PATH="${DATA_LAKE_PATH}/index"
INDEX_FILE="${INDEX_PATH}/index.json"   # leading copy; published to DEG [ORG]/index.json + index.csv

# Local staging area (on the hub VM, avoids network round-trips during processing).
# Each loop owns a subdirectory and only ever cleans its own.
LOCAL_STAGING_PATH="${LOCAL_STAGING_PATH:-/var/tmp/precise-hub}"
DEPLOY_STAGING_PATH="${LOCAL_STAGING_PATH}/deploy"
FETCH_STAGING_PATH="${LOCAL_STAGING_PATH}/fetch"
STATE_PATH="${LOCAL_STAGING_PATH}/state"   # small bookkeeping files, survives restarts

# Timing (in seconds)
DEPLOY_LOOP_INTERVAL=10    # How often to check for new uploads (10s for testing)
STABILITY_THRESHOLD="${STABILITY_THRESHOLD:-60}"     # File must be unchanged for this long (60s for testing)

# Integrity: archives are only processed once a matching .sha256 file is present.
# An archive that stays without checksum file is rejected after the timeout.
# Set REQUIRE_CHECKSUM=0 to fall back to processing stable archives without checksum.
REQUIRE_CHECKSUM="${REQUIRE_CHECKSUM:-1}"
MISSING_CHECKSUM_TIMEOUT_MINUTES=60

# Fetch settings
FETCH_LOOP_INTERVAL=30     # How often to check for new fetch requests (seconds)
FETCH_MAX_SIZE="${FETCH_MAX_SIZE:-20G}"       # Maximum total (uncompressed) size of one fetch request
FETCH_MAX_CASE_SIZE="${FETCH_MAX_CASE_SIZE:-4G}"   # Maximum (uncompressed) size of a single case package; larger cases are skipped

# DEG cleanup (scripts/process/cleanup/cleanup-deg.sh, run from the fetch loop)
UPLOAD_EXPIRY_HOURS=48         # Remove files in [ORG]/upload/ older than this (stale, rejected, mismatched)
DOWNLOAD_EXPIRY_HOURS=48       # Remove files in [ORG]/download/ older than this
EMPTY_FOLDER_EXPIRY_MINUTES=60 # Remove empty package folders older than this
CLEANUP_INTERVAL=600           # Seconds between cleanup runs

# Disk space
# DEG space allotted to the hub. Free space is the smaller of "df" on the DEG mount
# (the server reports its overall free space) and this capacity minus the files
# currently in all upload/download folders. Leave empty to trust "df" alone.
DEG_CAPACITY_BYTES="${DEG_CAPACITY_BYTES:-500G}"
DEG_SPACE_MARGIN="${DEG_SPACE_MARGIN:-1G}"      # Always keep at least this much free on the DEG
STAGING_SPACE_FACTOR=4     # Local staging must have this many times the archive size free

# Supported archive extensions
ARCHIVE_EXTENSIONS="zip tar.gz tar.zst"

# Lock files
DEPLOY_LOCK_FILE="${DEPLOY_LOCK_FILE:-/tmp/precise-deploy.lock}"
FETCH_LOCK_FILE="${FETCH_LOCK_FILE:-/tmp/precise-fetch.lock}"

# Shard size (number of examination folders per shard)
SHARD_SIZE=100

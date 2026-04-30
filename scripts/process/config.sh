#!/bin/bash
# =============================================================================
# PRECISE Hub - Configuration
# =============================================================================

# Organization codes (3-letter uppercase)
ORGANIZATIONS="UKK MUV UKF UHD MUI UKE FAU"

# Mount points
DEG_PATH="/mnt/deg"
FORSCHUNGSSPEICHER_PATH="/mnt/forschungsspeicher"
DATA_LAKE_PATH="/mnt/data-lake"

# Upload sources: the processor scans these paths for ORG/upload/ folders.
# DEG: external partners (all organizations)
# Forschungsspeicher: UKF local imports (same package format as DEG)
UPLOAD_SOURCES="${DEG_PATH} ${FORSCHUNGSSPEICHER_PATH}"

# Derived paths (all on the Data Lake)
TMP_PATH="${DATA_LAKE_PATH}/tmp"
LOG_PATH="${DATA_LAKE_PATH}/logs"
DATA_PATH="${DATA_LAKE_PATH}/Data"

# Local staging area (on the hub VM, avoids network round-trips during processing)
LOCAL_STAGING_PATH="/var/tmp/precise-hub"

# Timing (in seconds)
DEPLOY_LOOP_INTERVAL=10    # How often to check for new uploads (10s for testing)
STABILITY_THRESHOLD=60     # File must be unchanged for this long (60s for testing)

# Fetch settings
FETCH_LOOP_INTERVAL=30     # How often to check for new fetch requests (seconds)
FETCH_MAX_SIZE="20G"       # Maximum total size of a single download package
FETCH_EXPIRY_DAYS=2        # Days after which download packages are auto-deleted

# Supported archive extensions
ARCHIVE_EXTENSIONS="zip tar.gz tar.zst"

# Lock files
DEPLOY_LOCK_FILE="/tmp/precise-deploy.lock"
FETCH_LOCK_FILE="/tmp/precise-fetch.lock"

# Shard size (number of examination folders per shard)
SHARD_SIZE=100

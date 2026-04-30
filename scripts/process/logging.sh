#!/bin/bash
# =============================================================================
# PRECISE Hub - Logging Functions
# =============================================================================

# Log levels
LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARN=2
LOG_LEVEL_ERROR=3

CURRENT_LOG_LEVEL=${LOG_LEVEL_INFO}

# Current package log file (set per-package)
PACKAGE_LOG_FILE=""

# Initialize logging for a package
init_package_log() {
  local package_name="$1"
  local timestamp=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
  PACKAGE_LOG_FILE="${LOG_PATH}/${timestamp}__${package_name}.json.log"
  mkdir -p "${LOG_PATH}"
  echo "{ \"log_start\": \"${timestamp}\", \"package\": \"${package_name}\" }" >> "${PACKAGE_LOG_FILE}"
}

# Generic log function
_log() {
  local level="$1"
  local level_name="$2"
  local message="$3"
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  if [[ ${level} -ge ${CURRENT_LOG_LEVEL} ]]; then
    local log_entry="{ \"time\": \"${timestamp}\", \"level\": \"${level_name}\", \"message\": \"${message}\" }"
    echo "${log_entry}"
    if [[ -n "${PACKAGE_LOG_FILE}" ]]; then
      echo "${log_entry}" >> "${PACKAGE_LOG_FILE}"
    fi
  fi
}

log_debug() { _log ${LOG_LEVEL_DEBUG} "DEBUG" "$1"; }
log_info()  { _log ${LOG_LEVEL_INFO}  "INFO"  "$1"; }
log_warn()  { _log ${LOG_LEVEL_WARN}  "WARN"  "$1"; }
log_error() { _log ${LOG_LEVEL_ERROR} "ERROR" "$1"; }

log_json() {
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local json_data="$1"
  local log_entry="{ \"time\": \"${timestamp}\", ${json_data} }"
  echo "${log_entry}"
  if [[ -n "${PACKAGE_LOG_FILE}" ]]; then
    echo "${log_entry}" >> "${PACKAGE_LOG_FILE}"
  fi
}

finalize_package_log() {
  local status="$1"
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  if [[ -n "${PACKAGE_LOG_FILE}" ]]; then
    echo "{ \"log_end\": \"${timestamp}\", \"final_status\": \"${status}\" }" >> "${PACKAGE_LOG_FILE}"
  fi
  PACKAGE_LOG_FILE=""
}

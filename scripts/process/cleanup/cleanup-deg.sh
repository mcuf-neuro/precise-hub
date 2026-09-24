#!/bin/bash
# =============================================================================
# PRECISE Hub - DEG cleanup: remove stale partner data from upload/ and download/
#
# Usage: cleanup-deg.sh [--dry-run] [--force]
#   --dry-run  only report what would be removed
#   --force    ignore CLEANUP_INTERVAL throttle
#
# Called from the fetch loop every cycle (self-throttled), or by hand.
# Only ever touches ${DEG_PATH}/${ORG}/upload and ${DEG_PATH}/${ORG}/download
# for the configured organizations, at most two levels deep, never symlinks.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROCESS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROCESS_DIR}/config.sh"
source "${PROCESS_DIR}/logging.sh"
source "${PROCESS_DIR}/messages.sh"

DRY_RUN=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# --- Throttle ---------------------------------------------------------------
mkdir -p "${STATE_PATH}"
STAMP="${STATE_PATH}/last-cleanup"
if [[ $FORCE -eq 0 && $DRY_RUN -eq 0 && -f "$STAMP" ]]; then
  last=$(stat -c %Y "$STAMP")
  if (( $(date +%s) - last < CLEANUP_INTERVAL )); then
    exit 0
  fi
fi

# --- Safety -----------------------------------------------------------------
if [[ "${DEG_REQUIRE_MOUNTPOINT:-1}" == "1" ]] && ! mountpoint -q "${DEG_PATH}"; then
  log_error "Cleanup refused: ${DEG_PATH} is not a mountpoint"
  exit 1
fi
case "${DEG_PATH}" in
  ""|"/"|"/mnt"|"/home"|"/tmp"|"/var") log_error "Cleanup refused: unsafe DEG_PATH '${DEG_PATH}'"; exit 1 ;;
esac

log_info "DEG cleanup started (upload: ${UPLOAD_EXPIRY_HOURS}h, download: ${DOWNLOAD_EXPIRY_HOURS}h, empty folders: ${EMPTY_FOLDER_EXPIRY_MINUTES}min, dry-run: ${DRY_RUN})"

remove_file() {
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] would remove file: $1"
  else
    rm -f -- "$1"
  fi
}

remove_dir() {
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] would remove empty folder: $1"
  else
    rmdir -- "$1" 2>/dev/null || true
  fi
}

# clean_area ORG AREA EXPIRY_MINUTES MSG_TYPE
clean_area() {
  local org="$1" area="$2" expiry_min="$3" msg_type="$4"
  local dir="${DEG_PATH}/${org}/${area}"
  [[ -d "$dir" && ! -L "$dir" ]] || return 0

  local removed=()
  local -A touched_dirs=()
  local f
  # Files: directly in the area or inside one package folder
  while IFS= read -r -d '' f; do
    remove_file "$f"
    removed+=("${f#"${dir}/"}")
    touched_dirs["$(dirname "$f")"]=1
  done < <(find "$dir" -mindepth 1 -maxdepth 2 -type f -mmin +"${expiry_min}" -print0 2>/dev/null)

  # Package folders emptied by the removals above
  for f in "${!touched_dirs[@]}"; do
    if [[ "$f" != "$dir" && -d "$f" ]] && [[ $DRY_RUN -eq 1 || -z "$(ls -A "$f")" ]]; then
      remove_dir "$f"
    fi
  done

  # Empty package folders that were never filled (e.g. abandoned uploads)
  while IFS= read -r -d '' f; do
    remove_dir "$f"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -empty -mmin +"${EMPTY_FOLDER_EXPIRY_MINUTES}" -print0 2>/dev/null)

  if [[ ${#removed[@]} -gt 0 ]]; then
    local names_json
    names_json=$(printf '%s\n' "${removed[@]}" | jq -R . | jq -sc .)
    log_info "Removed ${#removed[@]} stale file(s) from ${org}/${area}"
    log_json "\"action\": \"deg_cleanup\", \"org\": \"${org}\", \"area\": \"${area}\", \"dry_run\": ${DRY_RUN}, \"files_removed\": ${#removed[@]}, \"files\": ${names_json}"
    if [[ $DRY_RUN -eq 0 ]]; then
      write_message "$org" "$(jq -n \
        --arg area "$area" \
        --argjson files "$names_json" \
        --arg hours "$((expiry_min / 60))" \
        --arg ts "$(now_iso)" \
        '{type: $area, status: "expired", files_removed: ($files | length), files: $files, message: ("Removed from " + $area + "/ after " + $hours + " hours"), timestamp: $ts}' \
        | sed 's/"type": "download"/"type": "fetch"/')" \
        "$msg_type" "expired"
    fi
  fi
}

for org in ${ORGANIZATIONS}; do
  clean_area "$org" "upload" "$((UPLOAD_EXPIRY_HOURS * 60))" "upload"
  clean_area "$org" "download" "$((DOWNLOAD_EXPIRY_HOURS * 60))" "fetch"
done

if [[ $DRY_RUN -eq 0 ]]; then
  touch "$STAMP"
fi
log_info "DEG cleanup complete"

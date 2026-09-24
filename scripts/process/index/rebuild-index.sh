#!/bin/bash
# =============================================================================
# PRECISE Hub - Rebuild the data index from the data lake content
#
# Usage: rebuild-index.sh [--no-publish]
# Walks Data/ORG/SHARD/ORG_NNNNN, keeps added_at/source/package of cases already
# in the index, uses the folder mtime for cases the index does not know
# (e.g. injected directly from local mass storage). Run by hand after direct
# injections, or nightly via a systemd timer.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROCESS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROCESS_DIR}/config.sh"
source "${PROCESS_DIR}/logging.sh"
source "${PROCESS_DIR}/validation.sh"
source "${PROCESS_DIR}/messages.sh"
source "${PROCESS_DIR}/index.sh"

PUBLISH=1
[[ "${1:-}" == "--no-publish" ]] && PUBLISH=0

log_info "Rebuilding data index from ${DATA_PATH}"

known='{}'
if [[ -s "${INDEX_FILE}" ]]; then
  known=$(jq -c '(.cases // []) | map({key: .id, value: .}) | from_entries' "${INDEX_FILE}")
fi

entries_file=$(mktemp)
trap 'rm -f "$entries_file"' EXIT
count=0

shopt -s nullglob
for case_dir in "${DATA_PATH}"/*/*/*/; do
  case_dir="${case_dir%/}"
  id=$(basename "$case_dir")
  [[ "$id" =~ ^[A-Z]{3}_[0-9]{5}$ ]] || continue

  added_at=$(echo "$known" | jq -r --arg id "$id" '.[$id].added_at // empty')
  source=$(echo "$known" | jq -r --arg id "$id" '.[$id].source // "unknown"')
  package=$(echo "$known" | jq -r --arg id "$id" '.[$id].package // "unknown"')
  if [[ -z "$added_at" ]]; then
    added_at=$(date -u -d "@$(stat -c %Y "$case_dir")" +"%Y-%m-%dT%H:%M:%SZ")
  fi

  index_entry_from_folder "$case_dir" "$id" "$source" "$package" "$added_at" >> "$entries_file"
  count=$((count + 1))
done
shopt -u nullglob

index_replace "$(jq -sc . "$entries_file")"
log_info "Index rebuilt: ${count} cases"

if [[ $PUBLISH -eq 1 ]]; then
  index_publish
fi

#!/bin/bash
# =============================================================================
# PRECISE Hub - Rebuild the data index from the data lake content
#
# Usage: rebuild-index.sh [--no-publish]
# Walks Data/ORG/SHARD/ORG_NNNNN. added_at/source/package come, in this order,
# from the index (cases it already knows), from the package logs in LOG_PATH
# (cases the deploy loop stored) or from the folder mtime with source "unknown"
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

# id -> {added_at, source, package} of every case the deploy loop stored, from the
# package logs (first "stored" entry per case wins).
added_from_logs() {
  [[ -d "${LOG_PATH}" ]] || { echo '{}'; return; }
  find "${LOG_PATH}" -maxdepth 1 -name '*__upload_*.json.log' -print0 \
    | xargs -0 -r jq -R -c '
        (fromjson? // empty) as $e | input_filename as $f
        | if $e.action == "start_processing" then
            {f: $f, kind: "start", package: ($e.file | split("/") | last), source: $e.source}
          elif $e.action == "store_exam_folder" and $e.result == "stored" then
            {f: $f, kind: "stored", id: $e.folder, added_at: $e.time}
          else empty end' 2>/dev/null \
    | jq -s -c '
        group_by(.f) | map(
          (map(select(.kind == "start")) | first) as $start
          | .[] | select(.kind == "stored")
          | {id, added_at, source: ($start.source // "unknown"), package: ($start.package // "unknown")})
        | sort_by(.added_at) | unique_by(.id)
        | map({key: .id, value: .}) | from_entries'
}

# Cases known to the index win, except those with source "unknown", for which the
# logs may know better.
known=$(added_from_logs)
if [[ -s "${INDEX_FILE}" ]]; then
  known=$(jq -c --slurpfile idx "${INDEX_FILE}" '
    . as $logs
    | ($idx[0].cases // []) | map(select(.source != "unknown")) | map({key: .id, value: .}) | from_entries
    | $logs + .' <<< "$known")
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

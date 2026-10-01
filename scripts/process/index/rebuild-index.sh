#!/bin/bash
# =============================================================================
# PRECISE Hub - Rebuild the data index from the data lake content
#
# Usage: rebuild-index.sh [--no-publish] [--recount]
# Walks Data/ORG/SHARD/ORG_NNNNN. added_at/source/package come, in this order,
# from the index (cases it already knows), from the package logs in LOG_PATH
# (cases the deploy loop stored) or from the folder mtime with source "unknown"
# (e.g. injected directly from local mass storage). Cases are immutable once
# stored, so size and file count are only measured for cases the index does not
# know (--recount: measure all). The index is only rewritten and republished if
# something changed. Run by hand after direct injections, or nightly via a
# systemd timer.
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
RECOUNT=0
for arg in "$@"; do
  case "$arg" in
    --no-publish) PUBLISH=0 ;;
    --recount) RECOUNT=1 ;;
    *) echo "Usage: $0 [--no-publish] [--recount]" >&2; exit 2 ;;
  esac
done

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
measured=0

# One lookup table instead of one jq call per case
declare -A k_added k_source k_package k_entry
while IFS=$'\t' read -r id added_at source package entry; do
  k_added[$id]=$added_at; k_source[$id]=$source; k_package[$id]=$package; k_entry[$id]=$entry
done < <(jq -r 'to_entries[] | [.key, .value.added_at, .value.source, .value.package,
  (if .value.size_bytes != null then (.value | tojson) else "" end)] | @tsv' <<< "$known")

shopt -s nullglob
for case_dir in "${DATA_PATH}"/*/*/*/; do
  case_dir="${case_dir%/}"
  id=$(basename "$case_dir")
  [[ "$id" =~ ^[A-Z]{3}_[0-9]{5}$ ]] || continue
  count=$((count + 1))

  # Known from the index with size and file count: reuse the entry as is
  if [[ $RECOUNT -eq 0 && -n "${k_entry[$id]:-}" ]]; then
    echo "${k_entry[$id]}" >> "$entries_file"
    continue
  fi

  added_at="${k_added[$id]:-}"
  source="${k_source[$id]:-unknown}"
  package="${k_package[$id]:-unknown}"
  if [[ -z "$added_at" ]]; then
    added_at=$(date -u -d "@$(stat -c %Y "$case_dir")" +"%Y-%m-%dT%H:%M:%SZ")
  fi

  index_entry_from_folder "$case_dir" "$id" "$source" "$package" "$added_at" >> "$entries_file"
  measured=$((measured + 1))
done
shopt -u nullglob

# Rewrite only if the set of cases or any entry changed
if [[ -s "${INDEX_FILE}" ]] && jq -e --slurpfile idx "${INDEX_FILE}" \
     '(sort_by(.id) | map(del(.updated_at))) == ($idx[0].cases | sort_by(.id) | map(del(.updated_at)))' \
     <(jq -sc . "$entries_file") >/dev/null; then
  log_info "Index unchanged: ${count} cases (${measured} measured)"
  exit 0
fi

index_replace "$(jq -sc . "$entries_file")"
log_info "Index rebuilt: ${count} cases (${measured} measured)"

if [[ $PUBLISH -eq 1 ]]; then
  index_publish
fi

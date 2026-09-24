#!/bin/bash
# =============================================================================
# PRECISE Hub - Data index: one entry per case stored in the data lake
#
# Leading copy: ${INDEX_FILE} on the data lake (JSON). Published copies:
# ${DEG_PATH}/${ORG}/index.json and index.csv for every organization.
# Writers: the deploy loop (incremental, after each stored package) and
# index/rebuild-index.sh (full walk). Both serialize through a local flock.
# =============================================================================

# Build one index entry from a case folder (local staging or data lake)
# Usage: index_entry_from_folder FOLDER ID SOURCE PACKAGE [ADDED_AT]
index_entry_from_folder() {
  local folder="$1" id="$2" source="$3" package="$4" added_at="${5:-$(now_iso)}"
  local size files
  size=$(du -sb "$folder" 2>/dev/null | awk '{print $1+0}')
  files=$(find "$folder" -type f 2>/dev/null | wc -l)
  jq -nc \
    --arg id "$id" \
    --arg org "${id:0:3}" \
    --arg shard "$(get_shard_dir "$id")" \
    --argjson size "${size:-0}" \
    --argjson files "${files:-0}" \
    --arg added "$added_at" \
    --arg source "$source" \
    --arg package "$package" \
    '{id: $id, org: $org, shard: $shard, size_bytes: $size, file_count: $files, added_at: $added, updated_at: null, source: $source, package: $package}'
}

# Merge entries (JSON array) into the index. Existing ids keep their added_at and
# get updated_at set; new ids are appended. The index is rewritten atomically.
# Usage: index_merge ENTRIES_JSON
index_merge() {
  local entries="$1"
  mkdir -p "${INDEX_PATH}" "${STATE_PATH}"
  (
    flock -w 60 9 || { log_error "Index lock timeout"; exit 1; }
    local current='{"cases": []}'
    if [[ -s "${INDEX_FILE}" ]]; then
      current=$(cat "${INDEX_FILE}")
    fi
    local tmp="${INDEX_FILE}.tmp.$$"
    jq -n \
      --argjson current "$current" \
      --argjson new "$entries" \
      --arg ts "$(now_iso)" '
      ($current.cases // []) as $old
      | ($old | map({key: .id, value: .}) | from_entries) as $byid
      | ($new | map(
          . as $e
          | if $byid[$e.id] then
              $byid[$e.id] + ($e | del(.added_at)) + {added_at: $byid[$e.id].added_at, updated_at: $ts}
            else $e end
        )) as $merged
      | ($merged | map({key: .id, value: .}) | from_entries) as $mbyid
      | (($old | map(select($mbyid[.id] | not))) + $merged | sort_by(.id)) as $cases
      | {generated: $ts, case_count: ($cases | length), total_bytes: ($cases | map(.size_bytes) | add // 0), cases: $cases}
    ' > "$tmp" && mv -f "$tmp" "${INDEX_FILE}"
    touch "${STATE_PATH}/index-dirty"
  ) 9> "${STATE_PATH}/index.lock"
}

# Replace the whole index (used by the rebuild). Usage: index_replace ENTRIES_JSON
index_replace() {
  local entries="$1"
  mkdir -p "${INDEX_PATH}" "${STATE_PATH}"
  (
    flock -w 60 9 || { log_error "Index lock timeout"; exit 1; }
    local tmp="${INDEX_FILE}.tmp.$$"
    jq -n --argjson new "$entries" --arg ts "$(now_iso)" '
      ($new | sort_by(.id)) as $cases
      | {generated: $ts, case_count: ($cases | length), total_bytes: ($cases | map(.size_bytes) | add // 0), cases: $cases}
    ' > "$tmp" && mv -f "$tmp" "${INDEX_FILE}"
    touch "${STATE_PATH}/index-dirty"
  ) 9> "${STATE_PATH}/index.lock"
}

# Copy the index as JSON and CSV to every organization folder on the DEG.
# With "if-dirty", only when the index changed since the last publish.
index_publish() {
  local mode="${1:-always}"
  if [[ "$mode" == "if-dirty" && ! -f "${STATE_PATH}/index-dirty" ]]; then
    return 0
  fi
  if [[ ! -s "${INDEX_FILE}" ]]; then
    return 0
  fi
  local csv="${STATE_PATH}/index.csv"
  jq -r '
    ["id","org","shard","size_bytes","file_count","added_at","updated_at","source","package"],
    (.cases[] | [.id, .org, .shard, .size_bytes, .file_count, .added_at, (.updated_at // ""), .source, .package])
    | @csv' "${INDEX_FILE}" > "$csv"
  local org published=0
  for org in ${ORGANIZATIONS}; do
    [[ -d "${DEG_PATH}/${org}" ]] || continue
    cp -f "${INDEX_FILE}" "${DEG_PATH}/${org}/index.json.tmp" && mv -f "${DEG_PATH}/${org}/index.json.tmp" "${DEG_PATH}/${org}/index.json" || continue
    cp -f "$csv" "${DEG_PATH}/${org}/index.csv" || true
    published=$((published + 1))
  done
  rm -f "${STATE_PATH}/index-dirty"
  log_info "Published data index to ${published} organization folder(s) ($(jq -r '.case_count' "${INDEX_FILE}") cases)"
}

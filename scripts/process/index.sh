#!/bin/bash
# =============================================================================
# PRECISE Hub - Data index: one entry per case stored in the data lake
#
# Leading copy: ${INDEX_FILE} on the data lake (JSON). Published copies:
# ${DEG_PATH}/${ORG}/index.json, index.csv and overview.html for every organization.
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

# jq: the index document for a list of cases, with a per-organization overview.
# Every configured organization is listed, also those without any case yet.
INDEX_JQ_DEFS='
def index_doc($cases; $ts; $orgs; $recent_since):
  (($orgs | split(" ") | map(select(. != ""))) + ($cases | map(.org)) | unique) as $all
  | ($cases | group_by(.org) | map({key: .[0].org, value: .}) | from_entries) as $byorg
  | {generated: $ts,
     case_count: ($cases | length),
     total_bytes: ($cases | map(.size_bytes) | add // 0),
     by_org: ($all | map(. as $o | ($byorg[$o] // []) as $c
       | {org: $o,
          case_count: ($c | length),
          total_bytes: ($c | map(.size_bytes) | add // 0),
          added_last_30d: ($c | map(select(.added_at >= $recent_since)) | length),
          last_added_at: ($c | map(.added_at) | max)})
       | sort_by(.org)),
     cases: $cases};
'

# Cutoff timestamp for the "added in the last 30 days" column of the overview
index_recent_since() {
  date -u -d '30 days ago' +"%Y-%m-%dT%H:%M:%SZ"
}

# Merge entries (JSON array) into the index. Existing ids keep their added_at and
# get updated_at set; new ids are appended. The index is rewritten atomically.
# Usage: index_merge ENTRIES_JSON
index_merge() {
  local entries="$1"
  mkdir -p "${INDEX_PATH}" "${STATE_PATH}"
  (
    flock -w 60 9 || { log_error "Index lock timeout"; exit 1; }
    # The index and the entries are read from file/stdin, never passed as
    # arguments: a single argument is limited to 128 KB, the index outgrows that.
    local current_file="${INDEX_FILE}"
    [[ -s "$current_file" ]] || current_file=/dev/null
    local tmp="${INDEX_FILE}.tmp.$$"
    if ! jq \
      --slurpfile current "$current_file" \
      --arg ts "$(now_iso)" \
      --arg orgs "${ORGANIZATIONS}" \
      --arg since "$(index_recent_since)" "${INDEX_JQ_DEFS}"'
      . as $new
      | ($current[0].cases // []) as $old
      | ($old | map({key: .id, value: .}) | from_entries) as $byid
      | ($new | map(
          . as $e
          | if $byid[$e.id] then
              $byid[$e.id] + ($e | del(.added_at)) + {added_at: $byid[$e.id].added_at, updated_at: $ts}
            else $e end
        )) as $merged
      | ($merged | map({key: .id, value: .}) | from_entries) as $mbyid
      | (($old | map(select($mbyid[.id] | not))) + $merged | sort_by(.id)) as $cases
      | index_doc($cases; $ts; $orgs; $since)
    ' <<< "$entries" > "$tmp" || ! mv -f "$tmp" "${INDEX_FILE}"; then
      rm -f "$tmp"
      log_error "Index merge failed, index left unchanged"
      exit 1
    fi
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
    if ! jq --arg ts "$(now_iso)" --arg orgs "${ORGANIZATIONS}" --arg since "$(index_recent_since)" "${INDEX_JQ_DEFS}"'
      index_doc(sort_by(.id); $ts; $orgs; $since)
    ' <<< "$entries" > "$tmp" || ! mv -f "$tmp" "${INDEX_FILE}"; then
      rm -f "$tmp"
      log_error "Index replace failed, index left unchanged"
      exit 1
    fi
    touch "${STATE_PATH}/index-dirty"
  ) 9> "${STATE_PATH}/index.lock"
}

# Render the overview (totals and contributions per organization) as a
# self-contained HTML page, alphabetical and only organizations that contributed
# (no ranking for now). Usage: index_render_html OUTPUT_FILE
index_render_html() {
  local out="$1"
  jq -r '
    def human: if . >= 1099511627776 then "\(. / 1099511627776 * 10 | round / 10) TB"
      elif . >= 1073741824 then "\(. / 1073741824 * 10 | round / 10) GB"
      elif . >= 1048576 then "\(. / 1048576 | round) MB"
      else "\(. / 1024 | round) KB" end;
    def day: if . then .[0:10] else "–" end;
    (.by_org | map(select(.case_count > 0))) as $orgs
    | ([$orgs[].case_count] | max // 0) as $max
    | "<!DOCTYPE html>
<html lang=\"en\"><head><meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<title>PRECISE Data Lake Overview</title>
<style>
  :root { --bg: #fff; --fg: #1a1f26; --muted: #66707c; --line: #dfe3e8; --bar: #2f6fb3; --card: #f4f6f8; }
  @media (prefers-color-scheme: dark) { :root { --bg: #14181d; --fg: #e6e9ec; --muted: #98a2ad; --line: #2c333b; --bar: #5b9bdc; --card: #1d232a; } }
  body { background: var(--bg); color: var(--fg); font: 16px/1.5 system-ui, sans-serif; max-width: 860px; margin: 0 auto; padding: 32px 16px; }
  h1 { margin: 0 0 4px; font-size: 28px; } h2 { font-size: 18px; margin: 32px 0 8px; }
  .muted { color: var(--muted); font-size: 14px; }
  .tiles { display: flex; flex-wrap: wrap; gap: 12px; margin: 24px 0 0; }
  .tile { background: var(--card); border-radius: 8px; padding: 14px 18px; flex: 1 1 160px; }
  .tile b { display: block; font-size: 28px; line-height: 1.2; }
  .scroll { overflow-x: auto; }
  table { border-collapse: collapse; width: 100%; font-variant-numeric: tabular-nums; }
  th, td { padding: 8px 10px; border-bottom: 1px solid var(--line); text-align: right; white-space: nowrap; }
  th { font-size: 13px; color: var(--muted); font-weight: 600; }
  th:first-child, td:first-child { text-align: left; font-weight: 600; }
  td.bar { width: 35%; text-align: left; }
  td.bar span { display: block; height: 12px; min-width: 2px; border-radius: 3px; background: var(--bar); }
  @media print { body { padding: 0; } }
</style></head><body>
<h1>PRECISE Data Lake Overview</h1>
<div class=\"muted\">As of \(.generated | @html) (UTC)</div>
<div class=\"tiles\">
  <div class=\"tile\"><b>\(.case_count)</b>datasets</div>
  <div class=\"tile\"><b>\(.total_bytes | human)</b>stored</div>
  <div class=\"tile\"><b>\($orgs | length)</b>institutions contributing</div>
</div>
<h2>Contributions by institution</h2>
<div class=\"scroll\"><table>
<tr><th>Institution</th><th>Datasets</th><th></th><th>Share</th><th>Data</th><th>Last 30 days</th><th>Latest</th></tr>",
      (. as $idx | $orgs[]
        | "<tr><td>\(.org | @html)</td><td>\(.case_count)</td>"
        + "<td class=\"bar\"><span style=\"width: \(if $max > 0 then (.case_count / $max * 100 | floor) else 0 end)%\"></span></td>"
        + "<td>\(if $idx.case_count > 0 then (.case_count / $idx.case_count * 100 | round) else 0 end)%</td>"
        + "<td>\(.total_bytes | human)</td><td>\(if .added_last_30d > 0 then "+\(.added_last_30d)" else "–" end)</td><td>\(.last_added_at | day)</td></tr>"),
      "</table></div>
<p class=\"muted\">One dataset is one case folder (ORG_NNNNN); sizes are uncompressed as stored. The full list of cases is in index.csv and index.json next to this file.</p>
</body></html>"
  ' "${INDEX_FILE}" > "$out"
}

# Copy the index as JSON, CSV and HTML overview to every organization folder on the DEG.
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
  local html="${STATE_PATH}/overview.html"
  index_render_html "$html" || { log_error "Rendering the index overview failed"; rm -f "$html"; }
  local org published=0
  for org in ${ORGANIZATIONS}; do
    [[ -d "${DEG_PATH}/${org}" ]] || continue
    cp -f "${INDEX_FILE}" "${DEG_PATH}/${org}/index.json.tmp" && mv -f "${DEG_PATH}/${org}/index.json.tmp" "${DEG_PATH}/${org}/index.json" || continue
    cp -f "$csv" "${DEG_PATH}/${org}/index.csv" || true
    [[ -s "$html" ]] && { cp -f "$html" "${DEG_PATH}/${org}/overview.html" || true; }
    published=$((published + 1))
  done
  rm -f "${STATE_PATH}/index-dirty"
  log_info "Published data index to ${published} organization folder(s) ($(jq -r '.case_count' "${INDEX_FILE}") cases)"
}

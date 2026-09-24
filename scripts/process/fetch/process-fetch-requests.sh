#!/bin/bash
# =============================================================================
# PRECISE Hub - Fetch Request Processing Script
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROCESS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROCESS_DIR}/config.sh"
source "${PROCESS_DIR}/logging.sh"
source "${PROCESS_DIR}/validation.sh"
source "${PROCESS_DIR}/messages.sh"
source "${PROCESS_DIR}/space.sh"

ensure_directories() {
  mkdir -p "${FETCH_STAGING_PATH}"
  mkdir -p "${LOG_PATH}"
}

# Move a processed request out of requests/ into archived-requests/ (partner-visible)
# and copy it to the data lake logs. A request is archived whether it succeeded or
# failed, otherwise it would be picked up again every cycle. Failed requests carry a
# FAILED marker in the archived name; the error message in messages/ has the details.
archive_request() {
  local request_file="$1"
  local org="$2"
  local outcome="$3"   # "ok" or "failed"
  local filename
  filename=$(basename "$request_file")

  local archive_dir="${DEG_PATH}/${org}/archived-requests"
  local archive_ts
  archive_ts=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
  local archived_name="${archive_ts}__${filename}"
  if [[ "$outcome" != "ok" ]]; then
    archived_name="${archive_ts}__FAILED__${filename}"
  fi
  mkdir -p "$archive_dir"
  mv -f "$request_file" "${archive_dir}/${archived_name}"
  cp "${archive_dir}/${archived_name}" "${LOG_PATH}/" || true

  log_json "\"action\": \"archive_request\", \"file\": \"${filename}\", \"outcome\": \"${outcome}\", \"archived_to\": \"${archive_dir}/${archived_name}\""
}

# Process a single fetch request file
process_request() {
  local request_file="$1"
  local org="$2"
  local filename=$(basename "$request_file")

  init_package_log "fetch_${filename%.json}"

  log_json "\"action\": \"start_fetch\", \"file\": \"${request_file}\", \"org\": \"${org}\""

  # Step 1: Parse and validate the request
  local request_json
  if ! request_json=$(jq '.' "$request_file" 2>/dev/null); then
    log_error "Invalid JSON in request file: ${filename}"
    write_message "$org" "$(jq -n \
      --arg file "$filename" \
      --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      '{type: "fetch", status: "error", request_file: $file, error: "Invalid JSON", timestamp: $ts}')" \
      "fetch" "error" "${filename%.json}"
    log_json "\"action\": \"validate_request\", \"file\": \"${filename}\", \"result\": \"invalid_json\""
    archive_request "$request_file" "$org" "failed"
    finalize_package_log "failed_validation"
    return 1
  fi

  local req_org
  req_org=$(echo "$request_json" | jq -r '.organization // empty')
  local requested_ids
  requested_ids=$(echo "$request_json" | jq -r '.requested_ids[]? // empty' 2>/dev/null)

  # Validate organization code
  if [[ -z "$req_org" ]] || ! echo "${ORGANIZATIONS}" | grep -qw "$req_org"; then
    log_error "Unknown or missing organization in request: ${req_org:-<empty>}"
    write_message "$org" "$(jq -n \
      --arg file "$filename" \
      --arg req_org "${req_org:-<empty>}" \
      --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      '{type: "fetch", status: "error", request_file: $file, error: ("Unknown organization: " + $req_org), timestamp: $ts}')" \
      "fetch" "error" "${filename%.json}"
    log_json "\"action\": \"validate_request\", \"file\": \"${filename}\", \"result\": \"unknown_org\", \"org\": \"${req_org:-<empty>}\""
    archive_request "$request_file" "$org" "failed"
    finalize_package_log "failed_validation"
    return 1
  fi

  # Validate requested IDs exist
  if [[ -z "$requested_ids" ]]; then
    log_error "No requested_ids in request: ${filename}"
    write_message "$org" "$(jq -n \
      --arg file "$filename" \
      --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      '{type: "fetch", status: "error", request_file: $file, error: "No requested_ids specified", timestamp: $ts}')" \
      "fetch" "error" "${filename%.json}"
    log_json "\"action\": \"validate_request\", \"file\": \"${filename}\", \"result\": \"no_ids\""
    archive_request "$request_file" "$org" "failed"
    finalize_package_log "failed_validation"
    return 1
  fi

  local missing_ids=()
  local valid_ids=()
  local invalid_format_ids=()

  while IFS= read -r exam_id; do
    # Validate format: ORG_NNNNN
    if ! [[ "$exam_id" =~ ^[A-Z]{3}_[0-9]{5}$ ]]; then
      invalid_format_ids+=("$exam_id")
      continue
    fi

    # Check if exam folder exists in the data lake
    local exam_org="${exam_id:0:3}"
    local shard_dir
    shard_dir=$(get_shard_dir "$exam_id") || true
    if [[ -n "$shard_dir" ]] && [[ -d "${DATA_PATH}/${exam_org}/${shard_dir}/${exam_id}" ]]; then
      valid_ids+=("$exam_id")
    else
      missing_ids+=("$exam_id")
    fi
  done <<< "$requested_ids"

  if [[ ${#invalid_format_ids[@]} -gt 0 ]]; then
    local bad_ids_str
    bad_ids_str=$(printf '%s, ' "${invalid_format_ids[@]}")
    bad_ids_str="${bad_ids_str%, }"
    log_error "Invalid ID format in request ${filename}: ${bad_ids_str}"
    write_message "$org" "$(jq -n \
      --arg file "$filename" \
      --arg bad_ids "$bad_ids_str" \
      --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      '{type: "fetch", status: "error", request_file: $file, error: ("Invalid ID format: " + $bad_ids), timestamp: $ts}')" \
      "fetch" "error" "${filename%.json}"
    log_json "\"action\": \"validate_request\", \"file\": \"${filename}\", \"result\": \"invalid_id_format\", \"ids\": \"${bad_ids_str}\""
    archive_request "$request_file" "$org" "failed"
    finalize_package_log "failed_validation"
    return 1
  fi

  # Reject only if ALL IDs are missing — partial fulfillment is OK
  if [[ ${#valid_ids[@]} -eq 0 ]]; then
    local missing_str
    missing_str=$(printf '%s, ' "${missing_ids[@]}")
    missing_str="${missing_str%, }"
    log_error "No requested IDs found in data lake: ${missing_str}"
    write_message "$org" "$(jq -n \
      --arg file "$filename" \
      --arg missing "$missing_str" \
      --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      '{type: "fetch", status: "error", request_file: $file, error: ("No requested IDs found in data lake: " + $missing), timestamp: $ts}')" \
      "fetch" "error" "${filename%.json}"
    log_json "\"action\": \"validate_request\", \"file\": \"${filename}\", \"result\": \"ids_not_found\", \"missing\": \"${missing_str}\""
    archive_request "$request_file" "$org" "failed"
    finalize_package_log "failed_validation"
    return 1
  fi

  local missing_str=""
  local missing_json="[]"
  if [[ ${#missing_ids[@]} -gt 0 ]]; then
    missing_str=$(printf '%s, ' "${missing_ids[@]}")
    missing_str="${missing_str%, }"
    missing_json=$(printf '%s\n' "${missing_ids[@]}" | jq -R . | jq -s .)
    log_warn "Some requested IDs not found in data lake (skipped): ${missing_str}"
  fi

  local base_name="${filename%.json}"
  local package_name="${org}_fetch_${base_name#request_}"
  local staging_dir="${FETCH_STAGING_PATH}/${package_name}"
  local download_dir="${DEG_PATH}/${org}/download/${package_name}"

  # Helper: report an error, archive the request, give up
  fail_request() {
    local reason="$1" status="$2" extra="${3:-{\}}"
    log_error "${reason}"
    write_message "$org" "$(jq -n \
      --arg file "$filename" \
      --arg reason "$reason" \
      --argjson extra "$extra" \
      --arg ts "$(now_iso)" \
      '{type: "fetch", status: "error", request_file: $file, error: $reason, timestamp: $ts} + $extra')" \
      "fetch" "error" "${base_name}"
    rm -rf "$staging_dir"
    archive_request "$request_file" "$org" "failed"
    finalize_package_log "$status"
  }

  # Step 2: Size checks from the data lake folder sizes, before anything is copied
  local max_case_bytes max_total_bytes
  max_case_bytes=$(numfmt --from=iec "${FETCH_MAX_CASE_SIZE}")
  max_total_bytes=$(numfmt --from=iec "${FETCH_MAX_SIZE}")

  local included_ids=() too_large_ids=()
  local total_bytes=0 largest_bytes=0
  declare -A case_bytes
  for exam_id in "${valid_ids[@]}"; do
    local src size
    src="${DATA_PATH}/${exam_id:0:3}/$(get_shard_dir "$exam_id")/${exam_id}"
    size=$(dir_bytes "$src")
    if [[ "$size" -gt "$max_case_bytes" ]]; then
      log_warn "Case exceeds per-case limit, skipped: ${exam_id} ($(human "$size") > ${FETCH_MAX_CASE_SIZE})"
      too_large_ids+=("$exam_id")
      continue
    fi
    case_bytes[$exam_id]=$size
    included_ids+=("$exam_id")
    total_bytes=$((total_bytes + size))
    [[ "$size" -gt "$largest_bytes" ]] && largest_bytes=$size
  done

  local too_large_json
  too_large_json=$(printf '%s\n' "${too_large_ids[@]}" | grep -v '^$' | jq -R . | jq -sc .)
  local extra_json
  extra_json=$(jq -nc --argjson skipped "$missing_json" --argjson large "$too_large_json" '{skipped_ids: $skipped, too_large_ids: $large}')

  if [[ ${#included_ids[@]} -eq 0 ]]; then
    fail_request "All requested cases exceed the per-case limit of ${FETCH_MAX_CASE_SIZE}" "failed_size_limit" "$extra_json"
    return 1
  fi
  if [[ "$total_bytes" -gt "$max_total_bytes" ]]; then
    fail_request "Request too large: $(human "$total_bytes") exceeds the limit of ${FETCH_MAX_SIZE}. Split it into several requests." "failed_size_limit" "$extra_json"
    return 1
  fi

  # DEG free space (see space.sh: real "df" or configured capacity)
  local deg_free margin
  deg_free=$(deg_free_bytes)
  margin=$(numfmt --from=iec "${DEG_SPACE_MARGIN}")
  if [[ $((total_bytes + margin)) -gt "$deg_free" ]]; then
    fail_request "Not enough space on the DEG for this request: needs $(human "$total_bytes"), free $(human "$deg_free"). Download and delete existing packages, or resubmit later." "failed_deg_space" "$extra_json"
    log_json "\"action\": \"space_check\", \"file\": \"${filename}\", \"result\": \"deg_full\", \"needed\": ${total_bytes}, \"free\": ${deg_free}"
    return 1
  fi

  # Local staging: one case at a time (folder copy + archive)
  local local_free
  local_free=$(free_bytes "${FETCH_STAGING_PATH}")
  if [[ $((largest_bytes * 2 + margin)) -gt "$local_free" ]]; then
    fail_request "Hub staging area is full ($(human "$local_free") free), please resubmit later" "failed_local_space" "$extra_json"
    log_json "\"action\": \"space_check\", \"file\": \"${filename}\", \"result\": \"staging_full\", \"needed\": $((largest_bytes * 2)), \"free\": ${local_free}"
    return 1
  fi

  # Acknowledge request
  local ids_json
  ids_json=$(printf '%s\n' "${included_ids[@]}" | jq -R . | jq -sc .)
  write_message "$org" "$(jq -n \
    --arg file "$filename" \
    --argjson ids "$ids_json" \
    --argjson skipped "$missing_json" \
    --argjson large "$too_large_json" \
    --arg ts "$(now_iso)" \
    '{type: "fetch", status: "received", request_file: $file, requested_ids: $ids, skipped_ids: $skipped, too_large_ids: $large, timestamp: $ts}')" \
    "fetch" "received" "${base_name}"

  log_json "\"action\": \"validate_request\", \"file\": \"${filename}\", \"org\": \"${req_org}\", \"ids\": ${ids_json}, \"skipped\": ${missing_json}, \"too_large\": ${too_large_json}, \"total_bytes\": ${total_bytes}, \"result\": \"valid\", \"ack\": \"written\""

  # Step 3: One package per case: copy from data lake, archive, checksum, transfer.
  # Processing case by case keeps local staging usage at about two cases.
  mkdir -p "$staging_dir"
  mkdir -p "$download_dir"

  local manifest_entries=()
  local transfer_start
  transfer_start=$(date +%s)

  for exam_id in "${included_ids[@]}"; do
    local src archive_name archive_path archive_size
    src="${DATA_PATH}/${exam_id:0:3}/$(get_shard_dir "$exam_id")/${exam_id}"
    archive_name="${exam_id}.tar.zst"
    archive_path="${staging_dir}/${archive_name}"

    if ! rsync -a "$src" "${staging_dir}/"; then
      rm -rf "$download_dir"
      fail_request "Could not read ${exam_id} from the data lake, please resubmit the request later" "failed_transfer" "$extra_json"
      return 1
    fi
    if ! tar -cf "$archive_path" --use-compress-program=zstd -C "$staging_dir" "$exam_id"; then
      rm -rf "$download_dir"
      fail_request "Could not create package for ${exam_id}" "failed_archive" "$extra_json"
      return 1
    fi
    rm -rf "${staging_dir:?}/${exam_id}"
    (cd "$staging_dir" && sha256sum "$archive_name") > "${archive_path}.sha256"
    archive_size=$(stat -c %s "$archive_path")

    if ! rsync -a "$archive_path" "${download_dir}/${archive_name}" || ! cp "${archive_path}.sha256" "${download_dir}/${archive_name}.sha256"; then
      rm -rf "$download_dir"
      fail_request "Transfer of ${archive_name} to the DEG failed, please resubmit the request later" "failed_transfer" "$extra_json"
      log_json "\"action\": \"transfer_to_deg\", \"file\": \"${archive_name}\", \"result\": \"failed\""
      return 1
    fi

    manifest_entries+=("$(jq -nc \
      --arg id "$exam_id" \
      --arg file "$archive_name" \
      --argjson stored "${case_bytes[$exam_id]}" \
      --argjson archive "$archive_size" \
      --arg sha "$(awk '{print $1}' "${archive_path}.sha256")" \
      '{id: $id, file: $file, size_bytes: $stored, archive_bytes: $archive, sha256: $sha}')")
    rm -f "$archive_path" "${archive_path}.sha256"

    log_json "\"action\": \"transfer_to_deg\", \"file\": \"${archive_name}\", \"result\": \"success\", \"size_bytes\": ${archive_size}, \"size\": \"$(human "$archive_size")\""
  done

  local transfer_duration=$(( $(date +%s) - transfer_start ))
  local manifest_json
  manifest_json=$(printf '%s\n' "${manifest_entries[@]}" | jq -s .)
  jq -n \
    --arg pkg "$package_name" \
    --arg file "$filename" \
    --argjson cases "$manifest_json" \
    --argjson skipped "$missing_json" \
    --argjson large "$too_large_json" \
    --arg ts "$(now_iso)" \
    '{package: $pkg, request_file: $file, created: $ts, cases: $cases, skipped_ids: $skipped, too_large_ids: $large}' \
    > "${download_dir}/manifest.json"
  rm -rf "$staging_dir"

  log_json "\"action\": \"assemble_package\", \"package\": \"${package_name}\", \"result\": \"success\", \"cases\": ${#included_ids[@]}, \"total_bytes\": ${total_bytes}, \"duration_s\": ${transfer_duration}"

  # Step 4: Notify partner and archive request
  write_message "$org" "$(jq -n \
    --arg file "$filename" \
    --arg folder "download/${package_name}" \
    --argjson ids "$ids_json" \
    --argjson skipped "$missing_json" \
    --argjson large "$too_large_json" \
    --arg ts "$(now_iso)" \
    '{type: "fetch", status: "ready", request_file: $file, download_folder: $folder, included_ids: $ids, skipped_ids: $skipped, too_large_ids: $large, timestamp: $ts}')" \
    "fetch" "ready" "${base_name}"

  archive_request "$request_file" "$org" "ok"

  finalize_package_log "success"
  return 0
}

# Scan all organizations for fetch requests
run_fetch_cycle() {
  log_info "Starting fetch processing cycle..."
  ensure_directories

  for org in ${ORGANIZATIONS}; do
    local requests_dir="${DEG_PATH}/${org}/requests"
    if [[ ! -d "$requests_dir" ]]; then
      continue
    fi

    shopt -s nullglob
    for request_file in "${requests_dir}"/*.json; do
      if [[ ! -f "$request_file" ]]; then
        continue
      fi

      process_request "$request_file" "$org" || true
    done
    shopt -u nullglob
  done

  # Stale data on the DEG (self-throttled, see CLEANUP_INTERVAL)
  "${PROCESS_DIR}/cleanup/cleanup-deg.sh" || log_error "DEG cleanup failed"

  log_info "Fetch processing cycle complete"
}

# Entry point
main() {
  run_fetch_cycle
}

main "$@"

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

ensure_directories() {
  mkdir -p "${TMP_PATH}"
  mkdir -p "${LOG_PATH}"
}

# Write a JSON status message to [ORG]/messages/
write_message() {
  local org="$1"
  local json_content="$2"
  local msg_type="$3"
  local msg_status="$4"

  local timestamp=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
  local msg_file="${DEG_PATH}/${org}/messages/msg_${timestamp}_${msg_type}_${msg_status}.json"
  mkdir -p "${DEG_PATH}/${org}/messages"
  echo "$json_content" > "$msg_file"
}

# Process a single fetch request file
process_request() {
  local request_file="$1"
  local org="$2"
  local filename=$(basename "$request_file")

  init_package_log "fetch_${filename}"

  log_json "\"action\": \"start_fetch\", \"file\": \"${request_file}\", \"org\": \"${org}\""

  # Step 1: Parse and validate the request
  local request_json
  if ! request_json=$(jq '.' "$request_file" 2>/dev/null); then
    log_error "Invalid JSON in request file: ${filename}"
    write_message "$org" "$(jq -n \
      --arg file "$filename" \
      --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      '{type: "fetch", status: "error", request_file: $file, error: "Invalid JSON", timestamp: $ts}')" \
      "fetch" "error"
    log_json "\"action\": \"validate_request\", \"file\": \"${filename}\", \"result\": \"invalid_json\""
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
      "fetch" "error"
    log_json "\"action\": \"validate_request\", \"file\": \"${filename}\", \"result\": \"unknown_org\", \"org\": \"${req_org:-<empty>}\""
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
      "fetch" "error"
    log_json "\"action\": \"validate_request\", \"file\": \"${filename}\", \"result\": \"no_ids\""
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
      "fetch" "error"
    log_json "\"action\": \"validate_request\", \"file\": \"${filename}\", \"result\": \"invalid_id_format\", \"ids\": \"${bad_ids_str}\""
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
      "fetch" "error"
    log_json "\"action\": \"validate_request\", \"file\": \"${filename}\", \"result\": \"ids_not_found\", \"missing\": \"${missing_str}\""
    finalize_package_log "failed_validation"
    return 1
  fi

  local ids_str
  ids_str=$(printf '%s, ' "${valid_ids[@]}")
  ids_str="${ids_str%, }"

  local missing_str=""
  local missing_json="[]"
  if [[ ${#missing_ids[@]} -gt 0 ]]; then
    missing_str=$(printf '%s, ' "${missing_ids[@]}")
    missing_str="${missing_str%, }"
    missing_json=$(printf '%s\n' "${missing_ids[@]}" | jq -R . | jq -s .)
    log_warn "Some requested IDs not found in data lake (skipped): ${missing_str}"
  fi

  # Acknowledge request
  local ids_json
  ids_json=$(printf '%s\n' "${valid_ids[@]}" | jq -R . | jq -s .)
  write_message "$org" "$(jq -n \
    --arg file "$filename" \
    --argjson ids "$ids_json" \
    --argjson skipped "$missing_json" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{type: "fetch", status: "received", request_file: $file, requested_ids: $ids, skipped_ids: $skipped, timestamp: $ts}')" \
    "fetch" "received"

  log_json "\"action\": \"validate_request\", \"file\": \"${filename}\", \"org\": \"${req_org}\", \"ids\": \"${ids_str}\", \"skipped\": \"${missing_str}\", \"result\": \"valid\", \"ack\": \"written\""

  # Step 2: Assemble package
  local base_name="${filename%.json}"
  local archive_name="${org}_fetch_${base_name#request_}.tar.zst"
  local staging_dir="${TMP_PATH}/fetch_${base_name}"
  local archive_path="${TMP_PATH}/${archive_name}"

  mkdir -p "$staging_dir"

  for exam_id in "${valid_ids[@]}"; do
    local exam_org="${exam_id:0:3}"
    local shard_dir
    shard_dir=$(get_shard_dir "$exam_id")
    local src="${DATA_PATH}/${exam_org}/${shard_dir}/${exam_id}"
    cp -a "$src" "$staging_dir/"
  done

  # Create archive
  tar -cf "$archive_path" --use-compress-program=zstd -C "$staging_dir" .
  rm -rf "$staging_dir"

  # Check size limit
  local archive_size
  archive_size=$(stat -c %s "$archive_path" 2>/dev/null || echo 0)
  local max_bytes
  max_bytes=$(numfmt --from=iec "${FETCH_MAX_SIZE}" 2>/dev/null || echo 0)

  if [[ "$archive_size" -gt "$max_bytes" ]]; then
    local human_size
    human_size=$(numfmt --to=iec "$archive_size")
    log_error "Package too large (${human_size} > ${FETCH_MAX_SIZE}): ${archive_name}"
    write_message "$org" "$(jq -n \
      --arg file "$filename" \
      --arg size "$human_size" \
      --arg max "${FETCH_MAX_SIZE}" \
      --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      '{type: "fetch", status: "error", request_file: $file, error: ("Package too large: " + $size + " exceeds limit " + $max), timestamp: $ts}')" \
      "fetch" "error"
    log_json "\"action\": \"assemble_package\", \"file\": \"${archive_name}\", \"result\": \"too_large\", \"size\": \"${archive_size}\", \"max\": \"${max_bytes}\""
    rm -f "$archive_path"
    finalize_package_log "failed_size_limit"
    return 1
  fi

  # Generate checksum (format: "hash  filename" for sha256sum -c compatibility)
  (cd "$TMP_PATH" && sha256sum "$archive_name") > "${archive_path}.sha256"

  local human_size
  human_size=$(numfmt --to=iec "$archive_size")

  log_json "\"action\": \"assemble_package\", \"file\": \"${archive_name}\", \"result\": \"success\", \"size_bytes\": ${archive_size}, \"size\": \"${human_size}\", \"exams\": ${#valid_ids[@]}"

  # Step 3: Transfer to DEG
  local download_dir="${DEG_PATH}/${org}/download"
  mkdir -p "$download_dir"

  local transfer_start
  transfer_start=$(date +%s)

  if ! rsync -a "$archive_path" "${download_dir}/${archive_name}"; then
    log_error "Transfer to DEG failed: ${archive_name}"
    log_json "\"action\": \"transfer_to_deg\", \"file\": \"${archive_name}\", \"result\": \"failed\""
    rm -f "$archive_path" "${archive_path}.sha256"
    finalize_package_log "failed_transfer"
    return 1
  fi
  cp "${archive_path}.sha256" "${download_dir}/${archive_name}.sha256"

  local transfer_end
  transfer_end=$(date +%s)
  local transfer_duration=$((transfer_end - transfer_start))

  log_json "\"action\": \"transfer_to_deg\", \"file\": \"${archive_name}\", \"result\": \"success\", \"duration_s\": ${transfer_duration}, \"size_bytes\": ${archive_size}, \"size\": \"${human_size}\""

  # Step 4: Notify partner and archive request
  write_message "$org" "$(jq -n \
    --arg file "$filename" \
    --arg dl_file "$archive_name" \
    --argjson ids "$ids_json" \
    --argjson skipped "$missing_json" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{type: "fetch", status: "ready", request_file: $file, download_file: $dl_file, included_ids: $ids, skipped_ids: $skipped, timestamp: $ts}')" \
    "fetch" "ready"

  # Archive request on DEG (partner-visible) — timestamp prefix avoids overwrites on reuse
  local archive_dir="${DEG_PATH}/${org}/archived-requests"
  local archive_ts
  archive_ts=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
  mkdir -p "$archive_dir"
  mv "$request_file" "${archive_dir}/${archive_ts}__${filename}"

  # Copy request to data lake logs (hub-side audit)
  cp "${archive_dir}/${filename}" "${LOG_PATH}/"

  log_json "\"action\": \"notify_and_archive\", \"file\": \"${filename}\", \"result\": \"success\", \"message\": \"ready\", \"archived_to\": \"${archive_dir}\""

  # Step 5: Finalize — clean up temp files
  rm -f "$archive_path" "${archive_path}.sha256"

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

  # Download expiry cleanup — only remove fetch archives we created
  for org in ${ORGANIZATIONS}; do
    local download_dir="${DEG_PATH}/${org}/download"
    if [[ ! -d "$download_dir" ]]; then
      continue
    fi

    local expired_count=0
    local expired_names=()
    while IFS= read -r expired_file; do
      expired_names+=("$(basename "$expired_file")")
      rm -f "$expired_file"
      # Also remove the companion .sha256 if the archive is being removed, or vice versa
      if [[ "$expired_file" == *.tar.zst ]]; then
        rm -f "${expired_file}.sha256"
      fi
      ((expired_count++))
    done < <(find "$download_dir" -maxdepth 1 -type f \( -name '*_fetch_*.tar.zst' -o -name '*_fetch_*.tar.zst.sha256' \) -mtime +"${FETCH_EXPIRY_DAYS}")

    if [[ "$expired_count" -gt 0 ]]; then
      local names_str
      names_str=$(printf '%s, ' "${expired_names[@]}")
      names_str="${names_str%, }"
      log_info "Removed ${expired_count} expired download(s) for ${org}"
      write_message "$org" "$(jq -n \
        --arg count "$expired_count" \
        --arg days "${FETCH_EXPIRY_DAYS}" \
        --arg files "$names_str" \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{type: "fetch", status: "expired", files_removed: ($count | tonumber), files: $files, message: ("Removed after " + $days + " days"), timestamp: $ts}')" \
        "fetch" "expired"
      log_json "\"action\": \"expiry_cleanup\", \"org\": \"${org}\", \"files_removed\": ${expired_count}, \"files\": \"${names_str}\""
    fi
  done

  log_info "Fetch processing cycle complete"
}

# Entry point
main() {
  run_fetch_cycle
}

main "$@"

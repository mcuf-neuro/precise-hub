#!/bin/bash
# =============================================================================
# PRECISE Hub - Main Upload Processing Script
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROCESS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROCESS_DIR}/config.sh"
source "${PROCESS_DIR}/logging.sh"
source "${PROCESS_DIR}/validation.sh"
source "${PROCESS_DIR}/messages.sh"
source "${PROCESS_DIR}/space.sh"
source "${PROCESS_DIR}/index.sh"

ensure_directories() {
  mkdir -p "${DEPLOY_STAGING_PATH}"
  mkdir -p "${STATE_PATH}/checksum-failed"
  mkdir -p "${LOG_PATH}"
}

# Strip any supported archive extension from a file name
strip_archive_ext() {
  local name="$1"
  for ext in ${ARCHIVE_EXTENSIONS}; do
    name="${name%.${ext}}"
  done
  echo "$name"
}

# JSON array from a bash array (empty array if no elements)
json_array() {
  if [[ $# -eq 0 ]]; then
    echo "[]"
  else
    printf '%s\n' "$@" | jq -R . | jq -sc .
  fi
}

# Reject an upload permanently: rename archive (+ checksum) so it drops out of the
# scan, notify the partner. The DEG cleanup removes rejected files later.
reject_upload() {
  local archive_file="$1"
  local org="$2"
  local source_label="$3"
  local reason="$4"
  local details_json="${5:-[]}"
  local filename
  filename=$(basename "$archive_file")

  mv -f "$archive_file" "${archive_file}.rejected"
  if [[ -f "${archive_file}.sha256" ]]; then
    mv -f "${archive_file}.sha256" "${archive_file}.sha256.rejected"
  fi

  log_error "Rejected upload ${filename}: ${reason}"
  log_json "\"action\": \"reject_upload\", \"file\": \"${filename}\", \"source\": \"${source_label}\", \"reason\": \"${reason}\", \"details\": ${details_json}"

  write_message "$org" "$(jq -n \
    --arg file "$filename" \
    --arg source "$source_label" \
    --arg reason "$reason" \
    --argjson details "$details_json" \
    --arg ts "$(now_iso)" \
    '{type: "upload", status: "rejected", file: $file, source: $source, error: $reason, details: $details, timestamp: $ts}')" \
    "upload" "rejected" "$(strip_archive_ext "$filename")"
}

# Checksum mismatch on a stable (finished) upload: rename the checksum file to
# NAME.sha256.mismatch, so the archive is skipped until the partner uploads a new
# checksum file (or the cleanup removes it). The archive itself is kept, so a wrong
# checksum file can be fixed without re-uploading the archive.
mark_checksum_mismatch() {
  local archive_file="$1"
  local org="$2"
  local source_label="$3"
  local filename
  filename=$(basename "$archive_file")

  mv -f "${archive_file}.sha256" "${archive_file}.sha256.mismatch"
  rm -f "${STATE_PATH}/checksum-failed/${filename}"

  log_error "Checksum mismatch on finished upload, marked: ${filename}"
  log_json "\"action\": \"checksum_verify\", \"file\": \"${filename}\", \"source\": \"${source_label}\", \"result\": \"mismatch_marked\""

  write_message "$org" "$(jq -n \
    --arg file "$filename" \
    --arg source "$source_label" \
    --arg ts "$(now_iso)" \
    '{type: "upload", status: "rejected", file: $file, source: $source, error: "SHA-256 checksum mismatch. The archive was kept; upload a correct .sha256 file to retry, or re-upload both files.", timestamp: $ts}')" \
    "upload" "rejected" "$(strip_archive_ext "$filename")"
}

# Process a single archive file
process_archive() {
  local archive_file="$1"
  local org="$2"
  local source_label="$3"
  local kind="${4:-batch}"   # "batch" (ORG_YYYY-MM-DD_NN) or "case" (ORG_NNNNN)
  local filename
  filename=$(basename "$archive_file")
  local base_name
  base_name=$(strip_archive_ext "$filename")

  local archive_size
  archive_size=$(stat -c %s "$archive_file" 2>/dev/null || echo 0)

  # Local staging needs room for the archive copy plus its extracted content.
  # Not enough: leave the archive on the DEG and try again next cycle.
  local needed=$((archive_size * STAGING_SPACE_FACTOR))
  local avail
  avail=$(free_bytes "${DEPLOY_STAGING_PATH}")
  if [[ "$avail" -lt "$needed" ]]; then
    log_error "Not enough local staging space for ${filename}: need $(human "$needed"), have $(human "$avail"). Waiting."
    return 1
  fi

  init_package_log "upload_${base_name}"

  log_json "\"action\": \"start_processing\", \"file\": \"${archive_file}\", \"source\": \"${source_label}\", \"kind\": \"${kind}\", \"size\": \"${archive_size}\""

  # Step 1: Copy archive from source (DEG/FS) to local hub staging
  local local_archive="${DEPLOY_STAGING_PATH}/${filename}"
  log_info "Transferring archive to hub: ${archive_file} -> ${local_archive}"
  mkdir -p "${DEPLOY_STAGING_PATH}"
  if ! rsync -a "$archive_file" "$local_archive"; then
    log_error "rsync transfer failed: ${archive_file}"
    rm -f "$local_archive"
    finalize_package_log "failed_transfer"
    return 1
  fi
  log_json "\"action\": \"transfer_to_hub\", \"result\": \"success\", \"dest\": \"${local_archive}\""

  # Step 2: Extract archive locally on the hub
  local staging_dir="${DEPLOY_STAGING_PATH}/${base_name}"
  log_info "Staging to: ${staging_dir}"

  if [[ -d "$staging_dir" ]]; then
    log_warn "Staging directory already exists, cleaning: ${staging_dir}"
    rm -rf "$staging_dir"
  fi
  mkdir -p "$staging_dir"

  log_info "Extracting archive..."
  if ! extract_archive "$local_archive" "$staging_dir"; then
    log_error "Extraction failed: ${local_archive}"
    rm -rf "$staging_dir"
    rm -f "$local_archive"
    reject_upload "$archive_file" "$org" "$source_label" "Archive could not be extracted (corrupt or unsupported format)"
    finalize_package_log "failed_extraction"
    return 1
  fi
  log_json "\"action\": \"extraction\", \"result\": \"success\", \"staging_dir\": \"${staging_dir}\""

  # Clean up the local archive copy (extracted content is in staging_dir)
  rm -f "$local_archive"

  # Step 3: Transfer extracted examination folders from hub to data lake
  local stored=() skipped=() invalid=() failed=()
  local index_entries=()

  for exam_folder in "${staging_dir}"/*; do
    if [[ ! -d "$exam_folder" ]]; then
      continue
    fi

    local exam_name
    exam_name=$(basename "$exam_folder")

    if ! [[ "$exam_name" =~ ^[A-Z]{3}_[0-9]{5}$ ]]; then
      log_warn "Skipping invalid folder name: ${exam_name} (expected: ORG_NNNNN, e.g., UKF_00123)"
      log_json "\"action\": \"store_exam_folder\", \"folder\": \"${exam_name}\", \"result\": \"invalid_name\""
      invalid+=("$exam_name")
      continue
    fi

    # Extract ORG from folder name
    local folder_org="${exam_name:0:3}"

    # Calculate shard directory
    local shard_dir
    shard_dir=$(get_shard_dir "$exam_name") || true
    if [[ -z "$shard_dir" ]]; then
      log_warn "Could not calculate shard for: ${exam_name}"
      invalid+=("$exam_name")
      continue
    fi

    local dest_shard_path="${DATA_PATH}/${folder_org}/${shard_dir}"
    local dest_folder="${dest_shard_path}/${exam_name}"
    local partial_folder="${dest_shard_path}/.partial_${exam_name}"

    if [[ -d "$dest_folder" ]]; then
      log_warn "Destination folder already exists, skipping: ${dest_folder}"
      log_json "\"action\": \"store_exam_folder\", \"folder\": \"${exam_name}\", \"result\": \"skipped_existing\""
      skipped+=("$exam_name")
      continue
    fi

    # rsync into a hidden partial folder, then rename atomically. An interrupted
    # transfer never leaves a half-filled folder under the final name.
    mkdir -p "$dest_shard_path"
    rm -rf "$partial_folder"
    if ! rsync -a "${exam_folder}/" "${partial_folder}/" || ! mv "$partial_folder" "$dest_folder"; then
      log_error "rsync to data lake failed: ${exam_name}"
      log_json "\"action\": \"store_exam_folder\", \"folder\": \"${exam_name}\", \"result\": \"failed_transfer\""
      rm -rf "$partial_folder"
      failed+=("$exam_name")
      continue
    fi
    log_json "\"action\": \"store_exam_folder\", \"folder\": \"${exam_name}\", \"shard\": \"${shard_dir}\", \"result\": \"stored\""
    stored+=("$exam_name")
    # Index entry from the local copy (same content, no data lake round-trip)
    index_entries+=("$(index_entry_from_folder "$exam_folder" "$exam_name" "$source_label" "$filename")")
  done

  if [[ ${#index_entries[@]} -gt 0 ]]; then
    if index_merge "$(printf '%s\n' "${index_entries[@]}" | jq -sc .)"; then
      log_json "\"action\": \"index_update\", \"cases\": ${#index_entries[@]}, \"result\": \"success\""
    else
      log_error "Index update failed for ${filename} (data is stored; run index/rebuild-index.sh)"
    fi
  fi

  log_info "Processing complete: ${#stored[@]} stored, ${#skipped[@]} skipped (existing), ${#invalid[@]} invalid, ${#failed[@]} failed"

  # A per-case package is expected to contain exactly the case it is named after.
  # Anything else is still stored (the content decides), but flagged.
  if [[ "$kind" == "case" ]]; then
    local found
    found=$(printf '%s\n' "${stored[@]}" "${skipped[@]}" | grep -v '^$' | sort | tr '\n' ' ')
    if [[ "$found" != "${base_name} " ]]; then
      log_warn "Case package ${filename} contains [${found% }] instead of ${base_name}"
      log_json "\"action\": \"case_package_check\", \"file\": \"${filename}\", \"result\": \"content_mismatch\", \"found\": \"${found% }\""
    fi
  fi

  # Step 4: Clean up staging directory
  rm -rf "$staging_dir"

  local stored_json skipped_json invalid_json failed_json
  stored_json=$(json_array "${stored[@]}")
  skipped_json=$(json_array "${skipped[@]}")
  invalid_json=$(json_array "${invalid[@]}")
  failed_json=$(json_array "${failed[@]}")

  # Step 5a: Transfer to the data lake failed for some folder: keep the source
  # archive on the DEG so the next cycle retries (already stored folders are then
  # skipped as existing). Never delete a source whose content is not safely stored.
  if [[ ${#failed[@]} -gt 0 ]]; then
    log_error "Keeping source archive for retry, ${#failed[@]} folder(s) failed: ${filename}"
    log_json "\"action\": \"cleanup_source\", \"file\": \"${filename}\", \"result\": \"kept_for_retry\", \"failed\": ${failed_json}"
    finalize_package_log "failed_store"
    return 1
  fi

  # Step 5b: Nothing usable inside: reject so the partner is told and the file is
  # not silently discarded.
  if [[ ${#stored[@]} -eq 0 && ${#skipped[@]} -eq 0 ]]; then
    reject_upload "$archive_file" "$org" "$source_label" \
      "No examination folders (ORG_NNNNN) found at the top level of the archive" "$invalid_json"
    finalize_package_log "rejected_empty"
    return 1
  fi

  # Step 5c: Delete the source archive from DEG (data is now in the data lake)
  rm -f "$archive_file"
  local checksum_file="${archive_file}.sha256"
  if [[ -f "$checksum_file" ]]; then
    rm -f "$checksum_file"
  fi

  log_json "\"action\": \"cleanup_source\", \"file\": \"${filename}\", \"result\": \"deleted\""

  write_message "$org" "$(jq -n \
    --arg file "$filename" \
    --arg source "$source_label" \
    --argjson stored "$stored_json" \
    --argjson skipped "$skipped_json" \
    --argjson invalid "$invalid_json" \
    --arg ts "$(now_iso)" \
    '{type: "upload", status: "stored", file: $file, source: $source, stored_ids: $stored, skipped_existing_ids: $skipped, invalid_folders: $invalid, timestamp: $ts}')" \
    "upload" "stored" "$base_name"

  finalize_package_log "success"
  return 0
}

# Verify checksum, but avoid re-hashing a still-growing file every cycle: remember
# size+mtime of the last failed attempt and skip while they are unchanged.
checksum_ok_or_wait() {
  local archive_file="$1"
  local filename
  filename=$(basename "$archive_file")
  local state_file="${STATE_PATH}/checksum-failed/${filename}"
  local sig
  sig=$(stat -c '%s %Y' "$archive_file" 2>/dev/null || echo "")

  if [[ -f "$state_file" ]] && [[ "$(cat "$state_file")" == "$sig" ]]; then
    return 1
  fi
  if verify_checksum "$archive_file"; then
    rm -f "$state_file"
    return 0
  fi
  echo "$sig" > "$state_file"
  return 1
}

# Scan a single upload source path for archives of a given organization
process_org_source() {
  local org="$1"
  local source_base="$2"
  local source_label="$3"
  local upload_path="${source_base}/${org}/upload"

  if [[ ! -d "$upload_path" ]]; then
    return 0
  fi

  # Archives directly in upload/ and inside one level of package folders
  # (upload/ORG_YYYY-MM-DD_NN/ORG_NNNNN.tar.zst). Package folders are only a
  # grouping convenience; every archive is handled on its own.
  shopt -s nullglob
  for ext in ${ARCHIVE_EXTENSIONS}; do
    for archive_file in "${upload_path}"/*.${ext} "${upload_path}"/*/*.${ext}; do
      if [[ ! -f "$archive_file" ]]; then
        continue
      fi

      local filename
      filename=$(basename "$archive_file")
      local base_check
      base_check=$(strip_archive_ext "$filename")

      local kind=""
      if [[ "$base_check" =~ ^[A-Z]{3}_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}$ ]]; then
        kind="batch"
      elif [[ "$base_check" =~ ^[A-Z]{3}_[0-9]{5}$ ]]; then
        kind="case"
      fi

      if [[ -z "$kind" ]]; then
        if is_file_stable "$archive_file"; then
          reject_upload "$archive_file" "$org" "$source_label" \
            "Invalid file name: ${filename} (expected: ORG_NNNNN.tar.zst for one case, or ORG_YYYY-MM-DD_NN.tar.zst for a batch)"
        else
          log_debug "Invalid name, still uploading: ${filename}"
        fi
        continue
      fi

      local checksum_file="${archive_file}.sha256"

      # Branch 1: Checksum file exists
      if [[ -f "$checksum_file" ]]; then
        if checksum_ok_or_wait "$archive_file"; then
          log_info "Found archive with valid checksum: ${filename} (${source_label})"
          log_json "\"action\": \"checksum_verify\", \"file\": \"${filename}\", \"source\": \"${source_label}\", \"result\": \"pass\""
          rm -f "${archive_file}.sha256.mismatch"
          process_archive "$archive_file" "$org" "$source_label" "$kind" || true
        elif is_file_stable "$archive_file"; then
          mark_checksum_mismatch "$archive_file" "$org" "$source_label"
        else
          log_debug "Checksum does not match yet, archive still uploading: ${filename}"
        fi
        continue
      fi

      # Branch 2: Earlier checksum mismatch, waiting for a new checksum file
      if [[ -f "${archive_file}.sha256.mismatch" ]]; then
        log_debug "Skipping archive with checksum mismatch marker: ${filename}"
        continue
      fi

      # Branch 3: No checksum - check file stability
      if is_file_stable "$archive_file"; then
        log_info "Found stable archive (no checksum): ${filename} (${source_label})"
        log_json "\"action\": \"stability_check\", \"file\": \"${filename}\", \"source\": \"${source_label}\", \"result\": \"stable\""
        process_archive "$archive_file" "$org" "$source_label" "$kind" || true
      else
        log_debug "Archive still uploading (not stable): ${filename}"
      fi
    done
  done
  shopt -u nullglob
}

run_processing_cycle() {
  log_info "Starting processing cycle..."
  ensure_directories

  for source_base in ${UPLOAD_SOURCES}; do
    # Derive a human-readable label from the mount path
    local source_label
    source_label=$(basename "$source_base")

    for org in ${ORGANIZATIONS}; do
      process_org_source "$org" "$source_base" "$source_label"
    done
  done

  # Publish the index to the DEG if it changed during this cycle
  index_publish if-dirty || log_error "Index publish failed"

  log_info "Processing cycle complete"
}

# Entry point
main() {
  run_processing_cycle
}

main "$@"

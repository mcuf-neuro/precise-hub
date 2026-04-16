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

ensure_directories() {
  mkdir -p "${TMP_PATH}"
  mkdir -p "${LOG_PATH}"
}

# Process a single archive file
process_archive() {
  local archive_file="$1"
  local org="$2"
  local source_label="$3"
  local filename=$(basename "$archive_file")

  local base_name="${filename}"
  for ext in ${ARCHIVE_EXTENSIONS}; do
    base_name="${base_name%.${ext}}"
  done

  init_package_log "${filename}"

  log_json "\"action\": \"start_processing\", \"file\": \"${archive_file}\", \"source\": \"${source_label}\", \"size\": \"$(stat -c %s "$archive_file" 2>/dev/null || echo 0)\""

  # Step 1: Copy archive from source (DEG/WebDAV) to data lake via rsync
  local local_archive="${TMP_PATH}/${filename}"
  log_info "Transferring archive to data lake: ${archive_file} -> ${local_archive}"
  mkdir -p "${TMP_PATH}"
  if ! rsync -a "$archive_file" "$local_archive"; then
    log_error "rsync transfer failed: ${archive_file}"
    rm -f "$local_archive"
    finalize_package_log "failed_transfer"
    return 1
  fi
  log_json "\"action\": \"transfer\", \"result\": \"success\", \"dest\": \"${local_archive}\""

  # Step 2: Extract archive locally on the data lake volume
  local staging_dir="${TMP_PATH}/${base_name}"
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
    finalize_package_log "failed_extraction"
    return 1
  fi
  log_json "\"action\": \"extraction\", \"result\": \"success\", \"staging_dir\": \"${staging_dir}\""

  # Clean up the local archive copy (extracted content is in staging_dir)
  rm -f "$local_archive"

  # Step 3: Process extracted examination folders (all local on data lake now)
  local folders_stored=0
  local folders_skipped=0
  local folders_invalid=0

  for exam_folder in "${staging_dir}"/*; do
    if [[ ! -d "$exam_folder" ]]; then
      continue
    fi

    local exam_name=$(basename "$exam_folder")

    if ! [[ "$exam_name" =~ ^[A-Z]{3}_[0-9]{5}$ ]]; then
      log_warn "Skipping invalid folder name: ${exam_name} (expected: ORG_NNNNN, e.g., UKF_00123)"
      log_json "\"action\": \"move_exam_folder\", \"folder\": \"${exam_name}\", \"result\": \"invalid_name\""
      ((folders_invalid++))
      continue
    fi

    # Extract ORG from folder name
    local folder_org="${exam_name:0:3}"

    # Calculate shard directory
    local shard_dir=$(get_shard_dir "$exam_name")
    if [[ -z "$shard_dir" ]]; then
      log_warn "Could not calculate shard for: ${exam_name}"
      ((folders_invalid++))
      continue
    fi

    local dest_shard_path="${DATA_PATH}/${folder_org}/${shard_dir}"
    local dest_folder="${dest_shard_path}/${exam_name}"

    if [[ -d "$dest_folder" ]]; then
      log_warn "Destination folder already exists, skipping: ${dest_folder}"
      log_json "\"action\": \"move_exam_folder\", \"folder\": \"${exam_name}\", \"result\": \"skipped_existing\""
      ((folders_skipped++))
      continue
    fi

    # mv is safe here: both source and dest are on the same CIFS mount (data lake)
    mkdir -p "$dest_shard_path"
    mv "$exam_folder" "$dest_folder"
    log_json "\"action\": \"move_exam_folder\", \"folder\": \"${exam_name}\", \"shard\": \"${shard_dir}\", \"result\": \"stored\""
    ((folders_stored++))
  done

  log_info "Processing complete: ${folders_stored} stored, ${folders_skipped} skipped (existing), ${folders_invalid} invalid"

  # Step 4: Clean up staging directory
  rm -rf "$staging_dir"

  # Step 5: Delete the source archive from DEG (data is now in the data lake)
  rm -f "$archive_file"
  local checksum_file="${archive_file}.sha256"
  if [[ -f "$checksum_file" ]]; then
    rm -f "$checksum_file"
  fi

  log_json "\"action\": \"cleanup_source\", \"file\": \"${filename}\""

  finalize_package_log "success"
  return 0
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

  shopt -s nullglob
  for ext in ${ARCHIVE_EXTENSIONS}; do
    for archive_file in "${upload_path}"/*.${ext}; do
      if [[ ! -f "$archive_file" ]]; then
        continue
      fi

      local filename=$(basename "$archive_file")

      local base_check="${filename}"
      for check_ext in ${ARCHIVE_EXTENSIONS}; do
        base_check="${base_check%.${check_ext}}"
      done

      if ! [[ "$base_check" =~ ^[A-Z]{3}_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}$ ]]; then
        log_warn "Skipping file with invalid name format: ${filename} (expected: ORG_YYYY-MM-DD_NN.ext)"
        log_json "\"action\": \"filename_validation\", \"file\": \"${filename}\", \"source\": \"${source_label}\", \"result\": \"invalid_format\""
        continue
      fi

      local checksum_file="${archive_file}.sha256"

      # Branch 1: Checksum file exists
      if [[ -f "$checksum_file" ]]; then
        log_info "Found archive with checksum: ${filename} (${source_label})"

        if verify_checksum "$archive_file"; then
          log_json "\"action\": \"checksum_verify\", \"file\": \"${filename}\", \"source\": \"${source_label}\", \"result\": \"pass\""
          process_archive "$archive_file" "$org" "$source_label" || true
        else
          log_error "Checksum verification failed: ${filename}"
          log_json "\"action\": \"checksum_verify\", \"file\": \"${filename}\", \"source\": \"${source_label}\", \"result\": \"fail\""
        fi
        continue
      fi

      # Branch 2: No checksum - check file stability
      if is_file_stable "$archive_file"; then
        log_info "Found stable archive (no checksum): ${filename} (${source_label})"
        log_json "\"action\": \"stability_check\", \"file\": \"${filename}\", \"source\": \"${source_label}\", \"result\": \"stable\""
        process_archive "$archive_file" "$org" "$source_label" || true
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
    local source_label=$(basename "$source_base")

    for org in ${ORGANIZATIONS}; do
      process_org_source "$org" "$source_base" "$source_label"
    done
  done

  log_info "Processing cycle complete"
}

# Entry point
main() {
  run_processing_cycle
}

main "$@"

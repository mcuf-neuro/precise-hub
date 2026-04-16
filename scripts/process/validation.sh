#!/bin/bash
# =============================================================================
# PRECISE Hub - Validation Functions
# =============================================================================

get_archive_type() {
  local file="$1"
  if [[ "$file" == *.tar.zst ]]; then
    echo "tar.zst"
  elif [[ "$file" == *.tar.gz ]]; then
    echo "tar.gz"
  elif [[ "$file" == *.zip ]]; then
    echo "zip"
  else
    echo ""
  fi
}

validate_archive() {
  local file="$1"
  local archive_type=$(get_archive_type "$file")

  case "$archive_type" in
    "tar.zst")
      tar -tf "$file" --use-compress-program=zstd >/dev/null 2>&1
      ;;
    "tar.gz")
      tar -tzf "$file" >/dev/null 2>&1
      ;;
    "zip")
      unzip -t "$file" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

verify_checksum() {
  local archive_file="$1"
  local checksum_file="${archive_file}.sha256"

  if [[ ! -f "$checksum_file" ]]; then
    return 1
  fi

  local expected_checksum=$(awk '{print $1}' "$checksum_file" | tr -d '\r')
  local actual_checksum=$(sha256sum "$archive_file" | awk '{print $1}')

  [[ "$expected_checksum" == "$actual_checksum" ]]
}

is_file_stable() {
  local file="$1"
  local threshold="${2:-${STABILITY_THRESHOLD}}"

  local now=$(date +%s)
  local mtime=$(stat -c %Y "$file" 2>/dev/null)

  if [[ -z "$mtime" ]]; then
    return 1
  fi

  local age=$((now - mtime))
  [[ $age -ge $threshold ]]
}

extract_archive() {
  local archive_file="$1"
  local dest_dir="$2"
  local archive_type=$(get_archive_type "$archive_file")

  mkdir -p "$dest_dir"

  case "$archive_type" in
    "tar.zst")
      tar -xf "$archive_file" --use-compress-program=zstd -C "$dest_dir"
      ;;
    "tar.gz")
      tar -xzf "$archive_file" -C "$dest_dir"
      ;;
    "zip")
      unzip -q "$archive_file" -d "$dest_dir"
      ;;
    *)
      return 1
      ;;
  esac
}

# Calculate shard directory for an examination folder
get_shard_dir() {
  local folder_name="$1"

  # Extract the 5-digit number from ORG_NNNNN
  local exam_number=$(echo "$folder_name" | sed -n 's/^[A-Z]\{3\}_\([0-9]\{5\}\)$/\1/p')

  if [[ -z "$exam_number" ]]; then
    return 1
  fi

  # Remove leading zeros for arithmetic
  local num=$((10#$exam_number))

  # Calculate shard base (floor division by SHARD_SIZE, then multiply)
  local shard_base=$(( (num / SHARD_SIZE) * SHARD_SIZE ))

  # Format with leading zeros (5 digits)
  printf "%05d" $shard_base
}

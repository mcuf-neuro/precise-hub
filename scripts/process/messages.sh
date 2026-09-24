#!/bin/bash
# =============================================================================
# PRECISE Hub - Partner-visible status messages (written to DEG [ORG]/messages/)
# =============================================================================

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Write a JSON status message to ${DEG_PATH}/${org}/messages/
# Usage: write_message ORG JSON TYPE STATUS [SUBJECT]
# The file name carries a timestamp, type, status and optional subject (e.g. the
# request or package name). A numeric suffix is added if the name already exists,
# so several messages written within the same second never overwrite each other.
write_message() {
  local org="$1"
  local json_content="$2"
  local msg_type="$3"
  local msg_status="$4"
  local subject="${5:-}"

  local msg_dir="${DEG_PATH}/${org}/messages"
  mkdir -p "$msg_dir"

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
  local base="msg_${timestamp}_${msg_type}_${msg_status}"
  if [[ -n "$subject" ]]; then
    base="${base}_${subject}"
  fi

  local msg_file="${msg_dir}/${base}.json"
  local n=1
  while [[ -e "$msg_file" ]]; do
    msg_file="${msg_dir}/${base}_${n}.json"
    n=$((n + 1))
  done

  echo "$json_content" > "$msg_file"
}

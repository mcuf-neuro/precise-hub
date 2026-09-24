#!/bin/bash
# =============================================================================
# PRECISE Hub - Disk space helpers
# =============================================================================

# Free bytes on the filesystem holding PATH (0 if unknown)
free_bytes() {
  local path="$1"
  df --output=avail -B1 "$path" 2>/dev/null | tail -n 1 | tr -d ' ' || echo 0
}

# Bytes used by partner data on the DEG: every file below [ORG]/upload and
# [ORG]/download. Directory listings only, no file content is read.
deg_used_bytes() {
  local total=0 org dir size
  for org in ${ORGANIZATIONS}; do
    for dir in "${DEG_PATH}/${org}/upload" "${DEG_PATH}/${org}/download"; do
      [[ -d "$dir" ]] || continue
      size=$(find "$dir" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}')
      total=$((total + size))
    done
  done
  echo "$total"
}

# Free bytes on the DEG: the smaller of what "df" reports for the mount (the
# server's overall free space, only meaningful if the WebDAV server supports quota
# properties) and the hub's own allotment DEG_CAPACITY_BYTES minus the files
# currently in all upload/download folders.
deg_free_bytes() {
  local df_free
  df_free=$(free_bytes "${DEG_PATH}")
  if [[ -z "${DEG_CAPACITY_BYTES:-}" ]]; then
    echo "${df_free:-0}"
    return
  fi
  local capacity used
  capacity=$(numfmt --from=iec "${DEG_CAPACITY_BYTES}" 2>/dev/null || echo "${DEG_CAPACITY_BYTES}")
  used=$(deg_used_bytes)
  local free=$((capacity - used))
  [[ $free -lt 0 ]] && free=0
  if [[ "${df_free:-0}" -gt 0 && "$df_free" -lt "$free" ]]; then
    free=$df_free
  fi
  echo "$free"
}

# Total size in bytes of a directory tree (as stored, uncompressed)
dir_bytes() {
  du -sb "$1" 2>/dev/null | awk '{print $1+0}'
}

human() { numfmt --to=iec "${1:-0}" 2>/dev/null || echo "${1:-0}"; }

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

# Free bytes on the DEG. davfs2 only reports real numbers when the WebDAV server
# supports quota properties; otherwise DEG_CAPACITY_BYTES must be configured and
# the free space is derived from the capacity minus the files currently stored.
deg_free_bytes() {
  if [[ -n "${DEG_CAPACITY_BYTES:-}" ]]; then
    local capacity used
    capacity=$(numfmt --from=iec "${DEG_CAPACITY_BYTES}" 2>/dev/null || echo "${DEG_CAPACITY_BYTES}")
    used=$(deg_used_bytes)
    local free=$((capacity - used))
    [[ $free -lt 0 ]] && free=0
    echo "$free"
  else
    free_bytes "${DEG_PATH}"
  fi
}

# Total size in bytes of a directory tree (as stored, uncompressed)
dir_bytes() {
  du -sb "$1" 2>/dev/null | awk '{print $1+0}'
}

human() { numfmt --to=iec "${1:-0}" 2>/dev/null || echo "${1:-0}"; }

#!/bin/bash

LAST_RUN_FILE="/var/log/automover_last_run.log"
CFG_PATH="/boot/config/plugins/automover/settings.cfg"
AUTOMOVER_LOG="/var/log/automover_files_moved.log"

# Load settings
if [[ -f "$CFG_PATH" ]]; then
  source "$CFG_PATH"
else
  echo "Config file not found: $CFG_PATH" >> "$LAST_RUN_FILE"
  exit 1
fi

MOUNT_POINT="/mnt/${POOL_NAME}"

# Log header
start_time=$(date +%s)
echo "------------------------------------------------" >> "$LAST_RUN_FILE"
echo "Automover session started - $(date '+%Y-%m-%d %H:%M:%S')" >> "$LAST_RUN_FILE"

# Session end function
log_session_end() {
  end_time=$(date +%s)
  duration=$((end_time - start_time))
  mins=$((duration / 60))
  secs=$((duration % 60))
  if (( mins > 0 )); then
    echo "Duration: ${mins}m ${secs}s" >> "$LAST_RUN_FILE"
  else
    echo "Duration: ${secs}s" >> "$LAST_RUN_FILE"
  fi
  echo "Automover session finished - $(date '+%Y-%m-%d %H:%M:%S')" >> "$LAST_RUN_FILE"
  printf "\n" >> "$LAST_RUN_FILE"
}

# Parity check block
if [[ "$ALLOW_DURING_PARITY_CHECK" == "no" ]]; then
  if grep -Eq 'mdResync="([1-9][0-9]*)"' /var/local/emhttp/var.ini 2>/dev/null; then
    echo "Parity check in progress. Skipping this run." >> "$LAST_RUN_FILE"
    exit 0
  fi
fi

# Disk usage check
POOL_NAME=$(basename "$MOUNT_POINT")
ZFS_CAP=$(zpool list -H -o name,cap 2>/dev/null | awk -v pool="$POOL_NAME" '$1 == pool {gsub("%","",$2); print $2}')

if [[ -n "$ZFS_CAP" ]]; then
  USED="$ZFS_CAP"
else
  USED=$(df -h --output=pcent "$MOUNT_POINT" 2>/dev/null | awk 'NR==2 {gsub("%",""); print}')
fi

if [[ -z "$USED" ]]; then
  echo "Could not retrieve usage for $MOUNT_POINT" >> "$LAST_RUN_FILE"
  exit 1
fi

echo "$POOL_NAME usage: ${USED}% (Threshold: $THRESHOLD%)" >> "$LAST_RUN_FILE"

if [[ "$USED" -le "$THRESHOLD" ]]; then
  echo "Usage below threshold — nothing to do" >> "$LAST_RUN_FILE"
  echo "Automover session finished - $(date '+%Y-%m-%d %H:%M:%S')" >> "$LAST_RUN_FILE"
  printf "\n" >> "$LAST_RUN_FILE"
  exit 0
fi

echo "Usage exceeds threshold" >> "$LAST_RUN_FILE"

dry_run_nothing=true

# Automover logic
SHARE_CFG_DIR="/boot/config/shares"
moved_anything=false

rm -f "$AUTOMOVER_LOG"

for cfg in "$SHARE_CFG_DIR"/*.cfg; do
  [[ -f "$cfg" ]] || continue
  share_name="${cfg##*/}"
  share_name="${share_name%.cfg}"

  use_cache=$(grep -E '^shareUseCache=' "$cfg" | cut -d'=' -f2- | tr -d '"' | tr -d '\r' | xargs | tr '[:upper:]' '[:lower:]')
  pool1=$(grep -E '^shareCachePool=' "$cfg" | cut -d'=' -f2- | tr -d '"' | tr -d '\r' | xargs)
  pool2=$(grep -E '^shareCachePool2=' "$cfg" | cut -d'=' -f2- | tr -d '"' | tr -d '\r' | xargs)

  [[ -z "$use_cache" || -z "$pool1" || -z "$pool2" ]] && continue

  case "$use_cache" in
    yes)
      src="/mnt/$pool1/$share_name"
      dst="/mnt/$pool2/$share_name"
      cleanup_path="$src"
      ;;
    prefer)
      src="/mnt/$pool2/$share_name"
      dst="/mnt/$pool1/$share_name"
      cleanup_path="$src"
      ;;
    *) continue ;;
  esac

  dst=$(readlink -f "$dst")
  dst_pool=$(basename "$(dirname "$dst")")
  dst_share=$(basename "$dst")

  if [[ "$DRY_RUN" == "yes" ]]; then
    if [[ -d "$src" ]]; then
      dry_output=$(rsync -anH --checksum --out-format="%n" "$src/" "$dst/" 2>/dev/null | grep -vE '/$|^\.$')
      file_lines=$(echo "$dry_output" | grep -v '^$')
      file_count=$(echo "$file_lines" | wc -l)

if [[ "$file_count" -gt 0 ]]; then
  echo "Dry run detected $file_count files to move for share: $share_name" >> "$AUTOMOVER_LOG"
  echo "Dry run detected $file_count files to move for share: $share_name" >> "$LAST_RUN_FILE"
  echo "$file_lines" | sed "s|^|$src/|;s|$| -> $dst/|" >> "$AUTOMOVER_LOG"
  log_session_end
  moved_anything=true
  dry_run_nothing=false
fi
    fi
  else
    if zpool list -H -o name | grep -qx "$dst_pool"; then
      if ! zfs list -H -o name | grep -qx "$dst_pool/$dst_share"; then
        zfs create "$dst_pool/$dst_share" 2>/dev/null
      fi
    fi

    if [[ -d "$src" ]]; then
      output=$(rsync -aH --checksum --remove-source-files --out-format="%n" "$src/" "$dst/" 2>/dev/null)
      file_lines=$(echo "$output" | awk '!/\/$/ && $0 != "." && NF')
      file_count=$(echo "$file_lines" | wc -l)

      if [[ "$file_count" -gt 0 ]]; then
        echo "$file_lines" | sed "s|^|$src/|;s|$| -> $dst/|" >> "$AUTOMOVER_LOG"
        echo "Starting move of $file_count files for share: $share_name" >> "$LAST_RUN_FILE"
        log_session_end
        moved_anything=true
      fi
    fi

    find "$cleanup_path" -type d -empty -delete
    cleanup_path=$(readlink -f "$cleanup_path")
    zfs_dataset=$(zfs list -H -o name,mountpoint | awk -v path="$cleanup_path" '$2 == path {print $1}')

    if [[ -n "$zfs_dataset" ]]; then
      if [[ -z "$(ls -A "$cleanup_path")" ]]; then
        zfs unmount "$zfs_dataset" 2>/dev/null
        zfs destroy "$zfs_dataset" 2>/dev/null
      else
        echo "ZFS dataset not empty: $zfs_dataset" >> "$LAST_RUN_FILE"
      fi
    else
      if [[ -d "$cleanup_path" && -z "$(ls -A "$cleanup_path")" ]]; then
        rmdir "$cleanup_path" 2>/dev/null
      fi
    fi
  fi
done

# Final summary if nothing was moved
if [[ "$moved_anything" == false ]]; then
  if [[ "$DRY_RUN" == "yes" && "$dry_run_nothing" == "true" ]]; then
    echo "Dry run: No files would have been moved" >> "$AUTOMOVER_LOG"
    echo "Dry run: No files would have been moved" >> "$LAST_RUN_FILE"
  else
    echo "No files moved for this run" >> "$AUTOMOVER_LOG"
    echo "No files moved for this run" >> "$LAST_RUN_FILE"
  fi
  echo "Automover session finished - $(date '+%Y-%m-%d %H:%M:%S')" >> "$LAST_RUN_FILE"
  printf "\n" >> "$LAST_RUN_FILE"
  rm -f "$AUTOMOVER_LOG"
fi

#!/bin/bash

LAST_RUN_FILE="/var/log/automover_last_run.log"
CFG_PATH="/boot/config/plugins/automover/settings.cfg"
AUTOMOVER_LOG="/var/log/automover_files_moved.log"
EXCLUSIONS_FILE="/boot/config/plugins/automover/exclusions.txt"
IN_USE_FILE="/boot/config/plugins/automover/in_use_files.txt"

# Generate in-use file exclusion list
> "$IN_USE_FILE"
for dir in /mnt/*; do
  [[ "$dir" == /mnt/disk* ]] && continue
  [[ "$dir" == "/mnt/user" || "$dir" == "/mnt/addons" || "$dir" == "/mnt/rootshare" ]] && continue
  if [ -d "$dir" ]; then
    lsof +D "$dir" 2>/dev/null | awk '$4 ~ /^[0-9]+[rwu]$/ {print $9}' >> "$IN_USE_FILE"
  fi
done
sort -u "$IN_USE_FILE" -o "$IN_USE_FILE"

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

# Parity check
if [[ "$ALLOW_DURING_PARITY_CHECK" == "no" ]]; then
  if grep -Eq 'mdResync="([1-9][0-9]*)"' /var/local/emhttp/var.ini 2>/dev/null; then
    echo "Parity check in progress. Skipping this run." >> "$LAST_RUN_FILE"
    log_session_end
    exit 0
  fi
fi

# Usage check
POOL_NAME=$(basename "$MOUNT_POINT")
ZFS_CAP=$(zpool list -H -o name,cap 2>/dev/null | awk -v pool="$POOL_NAME" '$1 == pool {gsub("%","",$2); print $2}')

if [[ -n "$ZFS_CAP" ]]; then
  USED="$ZFS_CAP"
else
  USED=$(df -h --output=pcent "$MOUNT_POINT" 2>/dev/null | awk 'NR==2 {gsub("%",""); print}')
fi

if [[ -z "$USED" ]]; then
  echo "$MOUNT_POINT usage not detected — nothing to do" >> "$LAST_RUN_FILE"
  log_session_end
  exit 1
fi

echo "$POOL_NAME usage: ${USED}% (Threshold: $THRESHOLD%)" >> "$LAST_RUN_FILE"

if [[ "$USED" -le "$THRESHOLD" ]]; then
  echo "Usage below threshold — nothing to do" >> "$LAST_RUN_FILE"
  log_session_end
  exit 0
fi

echo "Usage exceeds threshold - starting move" >> "$LAST_RUN_FILE"

dry_run_nothing=true
moved_anything=false

SHARE_CFG_DIR="/boot/config/shares"
rm -f "$AUTOMOVER_LOG"

for cfg in "$SHARE_CFG_DIR"/*.cfg; do
  [[ -f "$cfg" ]] || continue
  share_name="${cfg##*/}"
  share_name="${share_name%.cfg}"

  use_cache=$(grep -E '^shareUseCache=' "$cfg" | cut -d'=' -f2- | tr -d '"' | tr -d '\r' | xargs | tr '[:upper:]' '[:lower:]')
  pool1=$(grep -E '^shareCachePool=' "$cfg" | cut -d'=' -f2- | tr -d '"' | tr -d '\r' | xargs)
  pool2=$(grep -E '^shareCachePool2=' "$cfg" | cut -d'=' -f2- | tr -d '"' | tr -d '\r' | xargs)

  [[ -z "$use_cache" || -z "$pool1" ]] && continue

  if [[ -z "$pool2" ]]; then
    if [[ "$use_cache" == "yes" ]]; then
      src="/mnt/$pool1/$share_name"
      dst="/mnt/user0/$share_name"
      cleanup_path="$src"
      goto_case=true
    elif [[ "$use_cache" == "prefer" ]]; then
      src="/mnt/user0/$share_name"
      dst="/mnt/$pool1/$share_name"
      cleanup_path="$src"
      goto_case=true
    fi
  fi

  if [[ -z "$goto_case" ]]; then
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

    if [[ -n "$pool1" && -n "$pool2" && "$use_cache" =~ ^(yes|prefer)$ ]]; then
      if ! mountpoint -q "$src"; then
        echo "Source not mounted: $src — skipping share: $share_name" >> "$LAST_RUN_FILE"
        continue
      fi
      if ! mountpoint -q "$dst"; then
        echo "Destination not mounted: $dst — skipping share: $share_name" >> "$LAST_RUN_FILE"
        continue
      fi
    fi
  fi

  dst=$(readlink -f "$dst")
  dst_pool=$(basename "$(dirname "$dst")")
  dst_share=$(basename "$dst")

  # Load exclusions per share
  excludes=()
  src_clean="${src%/}"

  for file in "$EXCLUSIONS_FILE" "$IN_USE_FILE"; do
    [[ -f "$file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      line_clean="${line%/}"
      if [[ "$line_clean" == "$src_clean"* ]]; then
        rel="${line_clean#$src_clean/}"
        excludes+=("--exclude=$rel")
      fi
    done < "$file"
  done

  if [[ "$DRY_RUN" == "yes" ]]; then
    if [[ -d "$src" ]]; then
      dry_output=$(rsync -ainH --checksum "${excludes[@]}" "$src/" "$dst/" 2>/dev/null)
      file_lines=$(echo "$dry_output" | awk '$1 ~ /^>f/' | cut -c13-)
      file_count=$(echo "$file_lines" | grep -c .)

      if [[ "$file_count" -gt 0 ]]; then
        echo "Dry run detected $file_count files to move for share: $share_name" >> "$AUTOMOVER_LOG"
        echo "Dry run detected $file_count files to move for share: $share_name" >> "$LAST_RUN_FILE"
        echo "$file_lines" | awk -v src="$src" -v dst="$dst" '{print src "/" $0 " -> " dst "/" $0}' >> "$AUTOMOVER_LOG"
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
      output=$(rsync -aiH --checksum --remove-source-files "${excludes[@]}" "$src/" "$dst/" 2>/dev/null)
      file_lines=$(echo "$output" | awk '$1 ~ /^>f/' | cut -c13-)
      file_count=$(echo "$file_lines" | grep -c .)

      if [[ "$file_count" -gt 0 ]]; then
        echo "$file_lines" | awk -v src="$src" -v dst="$dst" '{print src "/" $0 " -> " dst "/" $0}' >> "$AUTOMOVER_LOG"
        echo "Starting move of $file_count files for share: $share_name" >> "$LAST_RUN_FILE"
        moved_anything=true
      fi

      # Cleanup directories that had files moved
      moved_dirs=()
      while IFS= read -r file; do
        full_path="$src/$file"
        dir=$(dirname "$full_path")
        while [[ "$dir" != "$src" && "$dir" != "/" ]]; do
          moved_dirs+=("$dir")
          dir=$(dirname "$dir")
        done
      done <<< "$file_lines"

      unique_dirs=$(printf "%s\n" "${moved_dirs[@]}" | sort -u | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)
      for dir in $unique_dirs; do
        [[ -d "$dir" && -z "$(ls -A "$dir")" ]] && rmdir "$dir" 2>/dev/null
      done

      # Additional cleanup: scan full source tree for empty folders not excluded
      if [[ -d "$src" ]]; then
        while IFS= read -r dir; do
          skip=false
          for ex in "${excludes[@]}"; do
            ex_path="${ex#--exclude=}"
            [[ "$dir" == "$src/$ex_path"* ]] && skip=true && break
          done
          [[ "$skip" == true ]] && continue
          [[ -d "$dir" && -z "$(ls -A "$dir")" ]] && rmdir "$dir" 2>/dev/null
        done < <(find "$src" -type d | sort -r)
      fi
    fi

    # ZFS dataset cleanup
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

# Final summary and session end
if [[ "$DRY_RUN" == "yes" ]]; then
  if [[ "$dry_run_nothing" == "true" ]]; then
    echo "Dry run: No files would have been moved" >> "$AUTOMOVER_LOG"
    echo "Dry run: No files would have been moved" >> "$LAST_RUN_FILE"
  fi
else
  if [[ "$moved_anything" == false ]]; then
    echo "No files moved for this run" >> "$AUTOMOVER_LOG"
    echo "No files moved for this run" >> "$LAST_RUN_FILE"
  fi
fi

log_session_end

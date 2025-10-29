#!/bin/bash
SCRIPT_NAME="automover"
LAST_RUN_FILE="/var/log/automover_last_run.log"
CFG_PATH="/boot/config/plugins/automover/settings.cfg"
AUTOMOVER_LOG="/var/log/automover_files_moved.log"
EXCLUSIONS_FILE="/boot/config/plugins/automover/exclusions.txt"
IN_USE_FILE="/tmp/automover/in_use_files.txt"
STATUS_FILE="/tmp/automover/automover_status.txt"

# ==========================================================
#  Setup directories and lock
# ==========================================================
mkdir -p /tmp/automover
LOCK_FILE="/tmp/automover/automover.lock"

# Preserve whatever status was set before starting
PREV_STATUS="Stopped"
if [[ -f "$STATUS_FILE" ]]; then
  PREV_STATUS=$(cat "$STATUS_FILE" | tr -d '\r\n')
fi

if [ -f "$LOCK_FILE" ]; then
  if ps -p "$(cat "$LOCK_FILE")" > /dev/null 2>&1; then
    echo "Another instance of $SCRIPT_NAME is already running. Exiting." >> "$LAST_RUN_FILE"
    exit 0
  else
    rm -f "$LOCK_FILE"
  fi
fi

echo $$ > "$LOCK_FILE"

# --- Ensure cleanup on all exit conditions ---
cleanup() {
  echo "$PREV_STATUS" > "$STATUS_FILE"    # ✅ Restore prior status
  rm -f "$LOCK_FILE"
  exit
}
trap cleanup EXIT SIGINT SIGTERM SIGHUP SIGQUIT

rm -f /tmp/automover/automover.done

# ==========================================================
#  Load Settings
# ==========================================================
if [[ -f "$CFG_PATH" ]]; then
  source "$CFG_PATH"
else
  echo "Config file not found: $CFG_PATH" >> "$LAST_RUN_FILE"
  echo "$PREV_STATUS" > "$STATUS_FILE"
  cleanup
fi

# ==========================================================
#  Check Python dependency for qBittorrent integration
# ==========================================================
if [[ "$QBITTORRENT_SCRIPT" == "yes" ]]; then
  if ! python3 -m pip show qbittorrent-api >/dev/null 2>&1; then
    if command -v pip3 >/dev/null 2>&1; then
      pip3 install qbittorrent-api -q >/dev/null 2>&1
    fi
  fi
fi

# ==========================================================
#  qBittorrent Pause/Resume Helper
# ==========================================================
run_qbit_script() {
  local action="$1"
  local python_script="/usr/local/emhttp/plugins/automover/helpers/qbittorrent_script.py"

  if [[ ! -f "$python_script" ]]; then
    echo "Qbittorrent script not found: $python_script" >> "$LAST_RUN_FILE"
    return
  fi

  echo "Running qbittorrent $action" >> "$LAST_RUN_FILE"

  python3 "$python_script" \
    --host "$QBITTORRENT_HOST" \
    --user "$QBITTORRENT_USERNAME" \
    --password "$QBITTORRENT_PASSWORD" \
    --cache-mount "/mnt/$POOL_NAME" \
    --days_from "$QBITTORRENT_DAYS_FROM" \
    --days_to "$QBITTORRENT_DAYS_TO" \
    --status-filter "$QBITTORRENT_STATUS" \
    "--$action" 2>&1 | grep -E '^(Running qBittorrent|Paused|Resumed|qBittorrent)' >> "$LAST_RUN_FILE"

  echo "Qbittorrent $action completed" >> "$LAST_RUN_FILE"
}

# ==========================================================
#  Optional MOVE NOW Mode (bypass all filters)
# ==========================================================
MOVE_NOW=false
if [[ "$1" == "--force-now" ]]; then
  MOVE_NOW=true
  shift
fi

# Optional: specify pool manually (used by Move Now button)
if [[ "$1" == "--pool" && -n "$2" ]]; then
  POOL_NAME="$2"
  shift 2
fi

# Normalize quoted values
for var in AGE_DAYS THRESHOLD INTERVAL POOL_NAME DRY_RUN ALLOW_DURING_PARITY \
           AGE_BASED_FILTER SIZE_BASED_FILTER SIZE_MB EXCLUSIONS_ENABLED \
           QBITTORRENT_SCRIPT QBITTORRENT_HOST QBITTORRENT_USERNAME QBITTORRENT_PASSWORD \
           QBITTORRENT_DAYS_FROM QBITTORRENT_DAYS_TO QBITTORRENT_STATUS HIDDEN_FILTER \
           FORCE_RECONSTRUCTIVE_WRITE CONTAINER_NAMES ENABLE_JDUPES HASH_PATH ENABLE_CLEANUP; do
  eval "$var=\$(echo \${$var} | tr -d '\"')"
done

# ==========================================================
#  Move now mode disables all filters and restrictions
# ==========================================================
if [[ "$MOVE_NOW" == true ]]; then
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "Dry run active — skipping move now execution" >> "$LAST_RUN_FILE"
    # Keep DRY_RUN as 'yes' and exit early so move now doesn’t override filters
    MOVE_NOW=false
  else
    echo "Move now mode active — disabling all filters and checks" >> "$LAST_RUN_FILE"
    AGE_FILTER_ENABLED=false
    SIZE_FILTER_ENABLED=false
    AGE_BASED_FILTER="no"
    SIZE_BASED_FILTER="no"
    HIDDEN_FILTER="no"
    ALLOW_DURING_PARITY="yes"
    EXCLUSIONS_FILE="/dev/null"
    THRESHOLD=0
  fi
fi


# ==========================================================
#  Log Header
# ==========================================================
start_time=$(date +%s)
{
  echo "------------------------------------------------"
  echo "Automover session started - $(date '+%Y-%m-%d %H:%M:%S')"
  [[ "$MOVE_NOW" == true ]] && echo "Move now triggered — all filters and exclusions disabled for this run"
} >> "$LAST_RUN_FILE"

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
  echo "" >> "$LAST_RUN_FILE"
}

# ==========================================================
#  Generate In-Use File Exclusion List (skip in dry run)
# ==========================================================
> "$IN_USE_FILE"

if [[ "$DRY_RUN" == "yes" ]]; then
  echo "Dry run active — skipping in-use file scan" >> "$LAST_RUN_FILE"
else
  EXCLUDES=("user" "user0" "addons" "disks" "remotes" "rootshare")
  for dir in /mnt/*; do
    base="$(basename "$dir")"
    [[ " ${EXCLUDES[*]} " =~ " $base " ]] && continue
    [[ -d "$dir" ]] || continue
    lsof +D "$dir" 2>/dev/null | awk -v path="$dir" '
      $4 ~ /^[0-9]+[rwu]$/ && $9 ~ "^/mnt/" {
        file=$9
        if (file ~ "^/mnt/disk[0-9]+/") {
          sub("^/mnt/disk[0-9]+", "/mnt/user0", file)
        }
        print file
      }
    ' >> "$IN_USE_FILE"
  done
  sort -u "$IN_USE_FILE" -o "$IN_USE_FILE"
fi

# ==========================================================
#  Parity Check Guard (unless MOVE_NOW)
# ==========================================================
if [[ "$ALLOW_DURING_PARITY" == "no" && "$MOVE_NOW" == false ]]; then
  if grep -Eq 'mdResync="([1-9][0-9]*)"' /var/local/emhttp/var.ini 2>/dev/null; then
    echo "Parity check in progress. Skipping this run" >> "$LAST_RUN_FILE"
    log_session_end
    cleanup
  fi
fi

# ==========================================================
#  Age & Size Filters
# ==========================================================
if [[ "$MOVE_NOW" == false ]]; then
  AGE_FILTER_ENABLED=false
  SIZE_FILTER_ENABLED=false
  if [[ "$AGE_BASED_FILTER" == "yes" && "$AGE_DAYS" =~ ^[0-9]+$ && "$AGE_DAYS" -gt 0 ]]; then
    AGE_FILTER_ENABLED=true
    MTIME_ARG="+$((AGE_DAYS - 1))"
  fi
  if [[ "$SIZE_BASED_FILTER" == "yes" && "$SIZE_MB" =~ ^[0-9]+$ && "$SIZE_MB" -gt 0 ]]; then
    SIZE_FILTER_ENABLED=true
  fi
else
  AGE_FILTER_ENABLED=false
  SIZE_FILTER_ENABLED=false
fi

MOUNT_POINT="/mnt/${POOL_NAME}"

# ==========================================================
#  Setup rsync options (handles dry-run mode)
# ==========================================================
RSYNC_OPTS=(-aiH --checksum)
if [[ "$DRY_RUN" == "yes" ]]; then
  RSYNC_OPTS+=(--dry-run)
  echo "Dry run active — no files will actually be moved" >> "$LAST_RUN_FILE"
else
  RSYNC_OPTS+=(--remove-source-files)
fi

# ==========================================================
#  Pool Usage Check (skip if MOVE_NOW)
# ==========================================================
if [[ "$MOVE_NOW" == false ]]; then
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "Dry run active — skipping pool usage check" >> "$LAST_RUN_FILE"
  else
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
      cleanup
    fi

    echo "$POOL_NAME usage: ${USED}% (Threshold: $THRESHOLD%) - Continuing" >> "$LAST_RUN_FILE"

    if [[ "$USED" -le "$THRESHOLD" ]]; then
      echo "Usage below threshold — nothing to do" >> "$LAST_RUN_FILE"
      log_session_end
      cleanup
    fi
  fi
fi

# ==========================================================
#  Pause qBittorrent torrents if enabled
# ==========================================================
if [[ "$QBITTORRENT_SCRIPT" == "yes" ]]; then
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "Dry run active — skipping pausing of qBittorrent torrents" >> "$LAST_RUN_FILE"
  else
    run_qbit_script pause
  fi
fi

# ==========================================================
#  Stop managed containers (optional, skip in dry run)
# ==========================================================
if [[ -n "$CONTAINER_NAMES" ]]; then
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "Dry run active — skipping stopping of containers" >> "$LAST_RUN_FILE"
  else
    IFS=',' read -ra CONTAINERS <<< "$CONTAINER_NAMES"
    for container in "${CONTAINERS[@]}"; do
      container=$(echo "$container" | xargs)  # trim spaces
      [[ -z "$container" ]] && continue
      echo "Stopping Docker container: $container" >> "$LAST_RUN_FILE"
      docker stop "$container" || \
        echo "Failed to stop container: $container" >> "$LAST_RUN_FILE"
    done
  fi
fi

# ==========================================================
#  Begin Movement (status update)
# ==========================================================
if [[ "$DRY_RUN" == "yes" ]]; then
  echo "Dry run active — starting move process" >> "$LAST_RUN_FILE"
  echo "Dry Run: Simulating Moves" > "$STATUS_FILE"
else
  echo "Starting move process" >> "$LAST_RUN_FILE"
  echo "Moving Files" > "$STATUS_FILE"
fi

# ==========================================================
#  Enable reconstructive (turbo) write if requested (skip in dry run)
# ==========================================================
if [[ "$FORCE_RECONSTRUCTIVE_WRITE" == "yes" ]]; then
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "Dry run active — skipping enabling reconstructive (turbo) md_write_method" >> "$LAST_RUN_FILE"
  else
    echo "Enabling reconstructive (turbo) md_write_method" >> "$LAST_RUN_FILE"
    /usr/local/sbin/mdcmd set md_write_method 1
  fi
fi


# ==========================================================
#  Movement Logic
# ==========================================================
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

  if [[ "$pool1" != "$POOL_NAME" && "$pool2" != "$POOL_NAME" ]]; then
    continue
  fi

  if [[ -z "$pool2" ]]; then
    if [[ "$use_cache" == "yes" ]]; then
      src="/mnt/$pool1/$share_name"
      dst="/mnt/user0/$share_name"
    elif [[ "$use_cache" == "prefer" ]]; then
      src="/mnt/user0/$share_name"
      dst="/mnt/$pool1/$share_name"
    else
      continue
    fi
  else
    case "$use_cache" in
      yes)
        src="/mnt/$pool1/$share_name"
        dst="/mnt/$pool2/$share_name"
        ;;
      prefer)
        src="/mnt/$pool2/$share_name"
        dst="/mnt/$pool1/$share_name"
        ;;
      *) continue ;;
    esac
  fi

  [[ ! -d "$src" ]] && continue

  # Skip if source is on array (prevent array -> pool moves)
  if [[ "$src" == /mnt/user0/* ]]; then
    echo "Skipping $share_name (array → pool moves are not allowed)" >> "$LAST_RUN_FILE"
    continue
  fi

excludes=()
if [[ "$MOVE_NOW" == false && "$EXCLUSIONS_ENABLED" == "yes" && -f "$EXCLUSIONS_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    # Wildcard or relative pattern — pass as-is
    if [[ "$line" == *'*'* || "$line" != /* ]]; then
      excludes+=("--exclude=$line")
      continue
    fi

    # Absolute path — convert to relative
    abs_path=$(realpath -m "$line")
    if [[ "$abs_path" == "$src"* ]]; then
      rel_path="${abs_path#$src/}"
      excludes+=("--exclude=$rel_path")
    fi
  done < "$EXCLUSIONS_FILE"
fi

# === Hidden file/folder filter (strict recursive for both files and directories) ===
if [[ "$MOVE_NOW" == false && "$HIDDEN_FILTER" == "yes" ]]; then

  cd "$src" || continue

  # --- Exclude hidden directories (the folder itself and everything inside) ---
  while IFS= read -r hidden_dir; do
    rel="${hidden_dir#./}"
    excludes+=("--exclude=$rel" "--exclude=$rel/*" "--exclude=$rel/**")
  done < <(find . -type d -name '.*' 2>/dev/null)

  # --- Exclude hidden files (not inside hidden dirs) ---
  while IFS= read -r hidden_file; do
    rel="${hidden_file#./}"
    excludes+=("--exclude=$rel")
  done < <(find . -type f -name '.*' 2>/dev/null)

  cd - >/dev/null 2>&1 || true
fi

  if [[ "$AGE_FILTER_ENABLED" == true || "$SIZE_FILTER_ENABLED" == true ]]; then
    if [[ "$AGE_FILTER_ENABLED" == true && "$SIZE_FILTER_ENABLED" == true ]]; then
      mapfile -t filtered_files < <(cd "$src" && find . -type f -mtime "$MTIME_ARG" -size +"${SIZE_MB}"M -printf '%P\n' 2>/dev/null)
    elif [[ "$AGE_FILTER_ENABLED" == true ]]; then
      mapfile -t filtered_files < <(cd "$src" && find . -type f -mtime "$MTIME_ARG" -printf '%P\n' 2>/dev/null)
    elif [[ "$SIZE_FILTER_ENABLED" == true ]]; then
      mapfile -t filtered_files < <(cd "$src" && find . -type f -size +"${SIZE_MB}"M -printf '%P\n' 2>/dev/null)
    fi
    mapfile -t filtered_dirs < <(cd "$src" && find . -type d -empty -printf '%P/\n' 2>/dev/null)
    all_filtered_items=("${filtered_files[@]}" "${filtered_dirs[@]}")
    (( ${#all_filtered_items[@]} == 0 )) && continue
    output=$(printf '%s\n' "${all_filtered_items[@]}" | rsync "${RSYNC_OPTS[@]}" "${excludes[@]}" --files-from=- "$src/" "$dst/" 2>/dev/null)
  else
    output=$(rsync "${RSYNC_OPTS[@]}" "${excludes[@]}" "$src/" "$dst/" 2>/dev/null)
  fi

  file_lines=$(echo "$output" | awk '$1 ~ /^>f/' | cut -c13-)
  file_count=$(echo "$file_lines" | grep -c .)

  if [[ "$file_count" -gt 0 ]]; then
    if [[ "$DRY_RUN" == "yes" ]]; then
      echo "Dry run: $file_count files *would* be moved for share: $share_name" >> "$LAST_RUN_FILE"
    else
      echo "Starting move of $file_count files for share: $share_name" >> "$LAST_RUN_FILE"
    fi
    echo "$file_lines" | awk -v src="$src" -v dst="$dst" '{print src "/" $0 " -> " dst "/" $0}' >> "$AUTOMOVER_LOG"
    if [[ "$DRY_RUN" != "yes" ]]; then
      echo "Finished move of $file_count files for share: $share_name" >> "$LAST_RUN_FILE"
    fi
    moved_anything=true
  fi
done

if [[ "$moved_anything" == false ]]; then
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "Dry run active — no files were actually moved" >> "$LAST_RUN_FILE"
  else
    echo "No files moved for this run" >> "$AUTOMOVER_LOG"
    echo "No files moved for this run" >> "$LAST_RUN_FILE"
  fi
fi

# ==========================================================
#  Resume qBittorrent torrents if enabled
# ==========================================================
if [[ "$QBITTORRENT_SCRIPT" == "yes" ]]; then
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "Dry run active — skipping resuming of qBittorrent torrents" >> "$LAST_RUN_FILE"
  else
    run_qbit_script resume
  fi
fi

# ==========================================================
#  Restart managed containers (optional, skip in dry run)
# ==========================================================
if [[ -n "$CONTAINER_NAMES" ]]; then
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "Dry run active — skipping starting of containers" >> "$LAST_RUN_FILE"
  else
    IFS=',' read -ra CONTAINERS <<< "$CONTAINER_NAMES"
    for container in "${CONTAINERS[@]}"; do
      container=$(echo "$container" | xargs)
      [[ -z "$container" ]] && continue
      echo "Starting Docker container: $container" >> "$LAST_RUN_FILE"
      docker start "$container" || \
        echo "Failed to start container: $container" >> "$LAST_RUN_FILE"
    done
  fi
fi

# ==========================================================
#  Finish and restore previous status
# ==========================================================
if [[ "$DRY_RUN" == "yes" ]]; then
  echo "Dry run active — finished move process" >> "$LAST_RUN_FILE"
else
  echo "Finished move process" >> "$LAST_RUN_FILE"
fi

# ==========================================================
#  Cleanup Empty Folders (including ZFS datasets)
# ==========================================================
if [[ "$ENABLE_CLEANUP" == "yes" ]]; then
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "Dry run active — skipping cleanup of empty folders/datasets" >> "$LAST_RUN_FILE"

  elif [[ "$moved_anything" == true ]]; then
    for cfg in "$SHARE_CFG_DIR"/*.cfg; do
      [[ -f "$cfg" ]] || continue
      share_name="${cfg##*/}"
      share_name="${share_name%.cfg}"

      pool1=$(grep -E '^shareCachePool=' "$cfg" | cut -d'=' -f2- | tr -d '"' | tr -d '\r' | xargs)
      pool2=$(grep -E '^shareCachePool2=' "$cfg" | cut -d'=' -f2- | tr -d '"' | tr -d '\r' | xargs)
      [[ -z "$pool1" && -z "$pool2" ]] && continue

      for pool in "$pool1" "$pool2"; do
        [[ -z "$pool" ]] && continue
        base_path="/mnt/$pool/$share_name"
        [[ ! -d "$base_path" ]] && continue

        # Remove truly empty directories
        find "$base_path" -type d -empty -delete 2>/dev/null

        # Detect and destroy empty ZFS datasets
        if command -v zfs >/dev/null 2>&1; then
          mapfile -t datasets < <(zfs list -H -o name,mountpoint | awk -v mp="$base_path" '$2 ~ "^"mp {print $1}')
          for ds in "${datasets[@]}"; do
            mountpoint=$(zfs get -H -o value mountpoint "$ds" 2>/dev/null)
            if [[ -d "$mountpoint" ]]; then
              if [[ -z "$(ls -A "$mountpoint" 2>/dev/null)" ]]; then
                zfs destroy -f "$ds" >/dev/null 2>&1
              fi
            fi
          done
        fi
      done
    done
    echo "Cleanup of empty folders/datasets finished" >> "$LAST_RUN_FILE"
  else
    echo "No files moved — skipping cleanup of empty folders/datasets" >> "$LAST_RUN_FILE"
  fi
fi

# ==========================================================
#  Re-hardlink media duplicates using jdupes
# ==========================================================
if [[ "$ENABLE_JDUPES" == "yes" && "$DRY_RUN" != "yes" && "$moved_anything" == true ]]; then
  if command -v jdupes >/dev/null 2>&1; then
    TEMP_LIST="/tmp/automover_jdupes_list.txt"
    HASH_DIR="$HASH_PATH"
    HASH_DB="${HASH_DIR}/jdupes_hash_database.db"

    # Ensure HASH_DIR exists
    if [[ ! -d "$HASH_DIR" ]]; then
      mkdir -p "$HASH_DIR"
      chmod 777 "$HASH_DIR"
    else
      echo "Using existing jdupes database: $HASH_DB" >> "$LAST_RUN_FILE"
    fi

    # Ensure HASH_DB exists
    if [[ ! -f "$HASH_DB" ]]; then
      touch "$HASH_DB"
      chmod 666 "$HASH_DB"
      echo "Creating jdupes hash database at $HASH_DIR" >> "$LAST_RUN_FILE"
    fi

    # Extract destination file paths from Automover log
    grep -E -- ' -> ' "$AUTOMOVER_LOG" | awk -F'->' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' > "$TEMP_LIST"

    if [[ ! -s "$TEMP_LIST" ]]; then
      echo "No moved files found, skipping jdupes step" >> "$LAST_RUN_FILE"
    else
      # Determine affected shares from destination paths (e.g., /mnt/user0/movies)
      mapfile -t SHARES < <(awk -F'/' '$2=="mnt" && $3=="user0" && $4!="" {print $4}' "$TEMP_LIST" | sort -u)

      # Excluded shares
      EXCLUDES=("appdata" "system" "domains" "isos")

      for share in "${SHARES[@]}"; do
        # Skip excluded shares
        skip=false
        for ex in "${EXCLUDES[@]}"; do
          [[ "$share" == "$ex" ]] && skip=true && break
        done
        [[ "$skip" == true ]] && {
          echo "Jdupes - Skipping excluded share: $share" >> "$LAST_RUN_FILE"
          continue
        }

        SHARE_PATH="/mnt/user/${share}"

        [[ -d "$SHARE_PATH" ]] || {
          echo "Jdupes - Skipping missing path: $SHARE_PATH" >> "$LAST_RUN_FILE"
          continue
        }

        echo "Jdupes processing share $share" >> "$LAST_RUN_FILE"

        # Run jdupes on this share’s destination folder
        /usr/bin/jdupes -rLX onlyext:mp4,mkv,avi -y "$HASH_DB" "$SHARE_PATH" 2>&1 \
          | grep -v -E \
              -e "^Creating a new hash database " \
              -e "^[[:space:]]*AT YOUR OWN RISK\. Report hashdb issues to jody@jodybruchon\.com" \
              -e "^[[:space:]]*yet and basic .*" \
              -e "^[[:space:]]*but there are LOTS OF QUIRKS.*" \
              -e "^WARNING: THE HASH DATABASE FEATURE IS UNDER HEAVY DEVELOPMENT!.*" \
          >> "$LAST_RUN_FILE"

        echo "Completed jdupes step for $share" >> "$LAST_RUN_FILE"
      done
    fi
  else
    echo "Jdupes not installed, skipping jdupes step" >> "$LAST_RUN_FILE"
  fi

elif [[ "$ENABLE_JDUPES" == "yes" ]]; then
  # Only log skip reasons if jdupes is actually enabled
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "Dry run active — skipping jdupes step" >> "$LAST_RUN_FILE"
  elif [[ "$moved_anything" == false ]]; then
    echo "No files moved — skipping jdupes step" >> "$LAST_RUN_FILE"
  fi
fi

# ==========================================================
#  Restore previous md_write_method if modified (skip in dry run)
# ==========================================================
if [[ "$FORCE_RECONSTRUCTIVE_WRITE" == "yes" ]]; then
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "Dry run active — skipping restoring md_write_method to previous value" >> "$LAST_RUN_FILE"
  else
    turbo_write_mode=$(grep -Po 'md_write_method="\K[^"]+' /var/local/emhttp/var.ini 2>/dev/null)
    if [[ -n "$turbo_write_mode" ]]; then
      /usr/local/sbin/mdcmd set md_write_method "$turbo_write_mode"
      echo "Restored md_write_method to previous value: $turbo_write_mode" >> "$LAST_RUN_FILE"
    fi
  fi
fi

log_session_end

# ==========================================================
#  Signal completion to WebUI
# ==========================================================
mkdir -p /tmp/automover
echo "done" > /tmp/automover/automover.done

echo "$PREV_STATUS" > "$STATUS_FILE"

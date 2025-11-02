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

PREV_STATUS="Stopped"
if [[ -f "$STATUS_FILE" ]]; then
  PREV_STATUS=$(cat "$STATUS_FILE" | tr -d '\r\n')
fi

if [ -f "$LOCK_FILE" ]; then
  if ps -p "$(cat "$LOCK_FILE")" > /dev/null 2>&1; then
    exit 0
  else
    rm -f "$LOCK_FILE"
  fi
fi

echo $$ > "$LOCK_FILE"

cleanup() {
  echo "$PREV_STATUS" > "$STATUS_FILE"
  rm -f "$LOCK_FILE"
  exit
}
trap cleanup EXIT SIGINT SIGTERM SIGHUP SIGQUIT

rm -f /tmp/automover/automover_done.txt

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
#  qBittorrent dependency check
# ==========================================================
if [[ "$QBITTORRENT_SCRIPT" == "yes" ]]; then
  if ! python3 -m pip show qbittorrent-api >/dev/null 2>&1; then
    command -v pip3 >/dev/null 2>&1 && pip3 install qbittorrent-api -q >/dev/null 2>&1
  fi
fi

# ==========================================================
#  qBittorrent helper
# ==========================================================
run_qbit_script() {
  local action="$1"
  local python_script="/usr/local/emhttp/plugins/automover/helpers/qbittorrent_script.py"
  [[ ! -f "$python_script" ]] && echo "Qbittorrent script not found: $python_script" >> "$LAST_RUN_FILE" && return
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
#  Move Now override
# ==========================================================
MOVE_NOW=false
if [[ "$1" == "--force-now" ]]; then
  MOVE_NOW=true
  shift
fi
if [[ "$1" == "--pool" && -n "$2" ]]; then
  POOL_NAME="$2"
  shift 2
fi

for var in AGE_DAYS THRESHOLD INTERVAL POOL_NAME DRY_RUN ALLOW_DURING_PARITY \
           AGE_BASED_FILTER SIZE_BASED_FILTER SIZE_MB EXCLUSIONS_ENABLED \
           QBITTORRENT_SCRIPT QBITTORRENT_HOST QBITTORRENT_USERNAME QBITTORRENT_PASSWORD \
           QBITTORRENT_DAYS_FROM QBITTORRENT_DAYS_TO QBITTORRENT_STATUS HIDDEN_FILTER \
           FORCE_RECONSTRUCTIVE_WRITE CONTAINER_NAMES ENABLE_JDUPES HASH_PATH ENABLE_CLEANUP MODE CRON_EXPRESSION STOP_THRESHOLD; do
  eval "$var=\$(echo \${$var} | tr -d '\"')"
done

# ==========================================================
#  Header
# ==========================================================
start_time=$(date +%s)
{
  echo "------------------------------------------------"
  echo "Automover session started - $(date '+%Y-%m-%d %H:%M:%S')"
  [[ "$MOVE_NOW" == true ]] && echo "Move now triggered — filters disabled"
} >> "$LAST_RUN_FILE"

log_session_end() {
  end_time=$(date +%s)
  duration=$((end_time - start_time))

  if (( duration < 60 )); then
    echo "Duration: ${duration}s" >> "$LAST_RUN_FILE"
  elif (( duration < 3600 )); then
    mins=$((duration / 60))
    secs=$((duration % 60))
    echo "Duration: ${mins}m ${secs}s" >> "$LAST_RUN_FILE"
  else
    hours=$((duration / 3600))
    mins=$(((duration % 3600) / 60))
    secs=$((duration % 60))
    echo "Duration: ${hours}h ${mins}m ${secs}s" >> "$LAST_RUN_FILE"
  fi

  echo "Automover session finished - $(date '+%Y-%m-%d %H:%M:%S')" >> "$LAST_RUN_FILE"
  echo "" >> "$LAST_RUN_FILE"
}

# ==========================================================
#  Parity guard
# ==========================================================
if [[ "$ALLOW_DURING_PARITY" == "no" && "$MOVE_NOW" == false ]]; then
  if grep -Eq 'mdResync="([1-9][0-9]*)"' /var/local/emhttp/var.ini; then
    echo "Parity check in progress — skipping" >> "$LAST_RUN_FILE"
    log_session_end; cleanup
  fi
fi

# ==========================================================
#  Filters
# ==========================================================
if [[ "$MOVE_NOW" == false ]]; then
  AGE_FILTER_ENABLED=false; SIZE_FILTER_ENABLED=false
  if [[ "$AGE_BASED_FILTER" == "yes" && "$AGE_DAYS" -gt 0 ]]; then
    AGE_FILTER_ENABLED=true; MTIME_ARG="+$((AGE_DAYS - 1))"
  fi
  if [[ "$SIZE_BASED_FILTER" == "yes" && "$SIZE_MB" -gt 0 ]]; then
    SIZE_FILTER_ENABLED=true
  fi
fi

MOUNT_POINT="/mnt/${POOL_NAME}"

# ==========================================================
#  Rsync setup
# ==========================================================
RSYNC_OPTS=(-aiHAX --numeric-ids --checksum --perms --owner --group)
[[ "$DRY_RUN" == "yes" ]] && RSYNC_OPTS+=(--dry-run) || RSYNC_OPTS+=(--remove-source-files)

# ==========================================================
#  Pool usage check
# ==========================================================
if [[ "$MOVE_NOW" == false && "$DRY_RUN" != "yes" ]]; then
  POOL_NAME=$(basename "$MOUNT_POINT")
  ZFS_CAP=$(zpool list -H -o name,cap 2>/dev/null | awk -v pool="$POOL_NAME" '$1 == pool {gsub("%","",$2); print $2}')
  [[ -n "$ZFS_CAP" ]] && USED="$ZFS_CAP" || USED=$(df -h --output=pcent "$MOUNT_POINT" | awk 'NR==2 {gsub("%",""); print}')
  [[ -z "$USED" ]] && echo "$MOUNT_POINT usage not detected — nothing to do" >> "$LAST_RUN_FILE" && log_session_end && cleanup
  echo "$POOL_NAME usage:${USED}% Threshold:${THRESHOLD}% Stop Threshold:${STOP_THRESHOLD}%" >> "$LAST_RUN_FILE"
  if [[ "$USED" -le "$THRESHOLD" ]]; then
    echo "Usage below threshold — nothing to do" >> "$LAST_RUN_FILE"; log_session_end; cleanup
  fi
fi

# ==========================================================
#  Stop threshold pre-check
# ==========================================================
if [[ "$MOVE_NOW" == false && "$DRY_RUN" != "yes" && "$STOP_THRESHOLD" -gt 0 && "$USED" -le "$STOP_THRESHOLD" ]]; then
  echo "Usage already below stop threshold ($USED% ≤ $STOP_THRESHOLD%) — skipping moves" >> "$LAST_RUN_FILE"
  log_session_end; cleanup
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
      container=$(echo "$container" | xargs)
      [[ -z "$container" ]] && continue
      echo "Stopping Docker container: $container" >> "$LAST_RUN_FILE"
      docker stop "$container" || \
        echo "Failed to stop container: $container" >> "$LAST_RUN_FILE"
    done
  fi
fi

# ==========================================================
#  Pause qBittorrent
# ==========================================================
[[ "$QBITTORRENT_SCRIPT" == "yes" && "$DRY_RUN" != "yes" ]] && run_qbit_script pause

# ==========================================================
#  Update status to "Moving Files"
# ==========================================================
if [[ "$DRY_RUN" == "yes" ]]; then
  echo "Dry Run: Simulating Moves" > "$STATUS_FILE"
else
  echo "Starting move process" >> "$LAST_RUN_FILE"
  echo "Moving Files" > "$STATUS_FILE"
fi

# ==========================================================
#  Main move logic (alphabeticalized)
# ==========================================================
moved_anything=false
STOP_TRIGGERED=false
SHARE_CFG_DIR="/boot/config/shares"
rm -f "$AUTOMOVER_LOG"

for cfg in "$SHARE_CFG_DIR"/*.cfg; do
  [[ -f "$cfg" ]] || continue
  share_name="${cfg##*/}"; share_name="${share_name%.cfg}"

  use_cache=$(grep -E '^shareUseCache=' "$cfg" | cut -d'=' -f2- | tr -d '"' | tr -d '\r' | xargs | tr '[:upper:]' '[:lower:]')
  pool1=$(grep -E '^shareCachePool=' "$cfg" | cut -d'=' -f2- | tr -d '"' | tr -d '\r' | xargs)
  pool2=$(grep -E '^shareCachePool2=' "$cfg" | cut -d'=' -f2- | tr -d '"' | tr -d '\r' | xargs)
  [[ -z "$use_cache" || -z "$pool1" ]] && continue
  if [[ "$pool1" != "$POOL_NAME" && "$pool2" != "$POOL_NAME" ]]; then continue; fi

  if [[ -z "$pool2" ]]; then
    if [[ "$use_cache" == "yes" ]]; then src="/mnt/$pool1/$share_name"; dst="/mnt/user0/$share_name"
    elif [[ "$use_cache" == "prefer" ]]; then src="/mnt/user0/$share_name"; dst="/mnt/$pool1/$share_name"
    else continue; fi
  else
    case "$use_cache" in
      yes) src="/mnt/$pool1/$share_name"; dst="/mnt/$pool2/$share_name";;
      prefer) src="/mnt/$pool2/$share_name"; dst="/mnt/$pool1/$share_name";;
      *) continue ;;
    esac
  fi
  [[ ! -d "$src" ]] && continue

  if [[ "$src" == /mnt/user0/* ]]; then
    echo "Skipping $share_name (array → pool moves not allowed)" >> "$LAST_RUN_FILE"
    continue
  fi

  # ==========================================================
  #  Determine candidate files (alphabetically)
  # ==========================================================
  if [[ "$AGE_FILTER_ENABLED" == true || "$SIZE_FILTER_ENABLED" == true ]]; then
    if [[ "$AGE_FILTER_ENABLED" == true && "$SIZE_FILTER_ENABLED" == true ]]; then
      mapfile -t all_filtered_items < <(cd "$src" && find . -type f -mtime "$MTIME_ARG" -size +"${SIZE_MB}"M -printf '%P\n' | LC_ALL=C sort)
    elif [[ "$AGE_FILTER_ENABLED" == true ]]; then
      mapfile -t all_filtered_items < <(cd "$src" && find . -type f -mtime "$MTIME_ARG" -printf '%P\n' | LC_ALL=C sort)
    else
      mapfile -t all_filtered_items < <(cd "$src" && find . -type f -size +"${SIZE_MB}"M -printf '%P\n' | LC_ALL=C sort)
    fi
  else
    mapfile -t all_filtered_items < <(cd "$src" && find . -type f -printf '%P\n' | LC_ALL=C sort)
  fi

  file_count=${#all_filtered_items[@]}
  (( file_count == 0 )) && { continue; }

  echo "Starting move of $file_count files for share: $share_name" >> "$LAST_RUN_FILE"

  # ==========================================================
  #  File-by-file rsync loop (alphabetical order preserved)
  # ==========================================================
  tmpfile=$(mktemp)
  printf '%s\n' "${all_filtered_items[@]}" > "$tmpfile"
  file_count_moved=0
  src_owner=$(stat -c "%u" "$src"); src_group=$(stat -c "%g" "$src"); src_perms=$(stat -c "%a" "$src")

  while IFS= read -r relpath; do
    [[ -z "$relpath" ]] && continue
    srcfile="$src/$relpath"; dstfile="$dst/$relpath"; dstdir="$(dirname "$dstfile")"

    # Skip if file is currently in use
    if fuser "$srcfile" >/dev/null 2>&1; then
      echo "Skipping in-use file: $srcfile" >> "$LAST_RUN_FILE"
      grep -qxF "$srcfile" "$IN_USE_FILE" || echo "$srcfile" >> "$IN_USE_FILE"
      continue
    fi

    if [[ "$DRY_RUN" != "yes" ]]; then
      mkdir -p "$dstdir"
      chown "$src_owner:$src_group" "$dstdir"
      chmod "$src_perms" "$dstdir"
    fi

    rsync "${RSYNC_OPTS[@]}" -- "$srcfile" "$dstdir/" >/dev/null 2>&1

    if [[ "$DRY_RUN" != "yes" && -f "$dstfile" ]]; then
      ((file_count_moved++))
      echo "$srcfile -> $dstfile" >> "$AUTOMOVER_LOG"
    fi

    # Stop threshold check per file
    if [[ "$MOVE_NOW" == false && "$DRY_RUN" != "yes" && "$STOP_THRESHOLD" -gt 0 ]]; then
      FINAL_USED=$(df -h --output=pcent "$MOUNT_POINT" | awk 'NR==2 {gsub("%",""); print}')
      if [[ -n "$FINAL_USED" && "$FINAL_USED" -le "$STOP_THRESHOLD" ]]; then
        echo "Pool usage reached stop threshold" >> "$LAST_RUN_FILE"
        STOP_TRIGGERED=true
        break
      fi
    fi
  done < "$tmpfile"
  rm -f "$tmpfile"

  echo "Finished move of $file_count_moved files for share: $share_name" >> "$LAST_RUN_FILE"
  moved_anything=true

  [[ "$STOP_TRIGGERED" == true ]] && break
done

# ==========================================================
#  In-use file summary
# ==========================================================
if [[ -s "$IN_USE_FILE" ]]; then
  sort -u "$IN_USE_FILE" -o "$IN_USE_FILE"
  count_inuse=$(wc -l < "$IN_USE_FILE")
  echo "Skipped $count_inuse in-use file(s)" >> "$LAST_RUN_FILE"
else
  echo "No in-use files detected during move" >> "$LAST_RUN_FILE"
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
#  Start managed containers (optional, skip in dry run)
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
  echo ""
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
        find "$base_path" -type d -empty -delete 2>/dev/null
        if command -v zfs >/dev/null 2>&1; then
          mapfile -t datasets < <(zfs list -H -o name,mountpoint | awk -v mp="$base_path" '$2 ~ "^"mp {print $1}')
          for ds in "${datasets[@]}"; do
            mountpoint=$(zfs get -H -o value mountpoint "$ds" 2>/dev/null)
            if [[ -d "$mountpoint" && -z "$(ls -A "$mountpoint" 2>/dev/null)" ]]; then
              zfs destroy -f "$ds" >/dev/null 2>&1
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

    if [[ ! -d "$HASH_DIR" ]]; then
      mkdir -p "$HASH_DIR"
      chmod 777 "$HASH_DIR"
    else
      echo "Using existing jdupes database: $HASH_DB" >> "$LAST_RUN_FILE"
    fi

    if [[ ! -f "$HASH_DB" ]]; then
      touch "$HASH_DB"
      chmod 666 "$HASH_DB"
      echo "Creating jdupes hash database at $HASH_DIR" >> "$LAST_RUN_FILE"
    fi

    grep -E -- ' -> ' "$AUTOMOVER_LOG" | awk -F'->' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' > "$TEMP_LIST"

    if [[ ! -s "$TEMP_LIST" ]]; then
      echo "No moved files found, skipping jdupes step" >> "$LAST_RUN_FILE"
    else
      mapfile -t SHARES < <(awk -F'/' '$2=="mnt" && $3=="user0" && $4!="" {print $4}' "$TEMP_LIST" | sort -u)
      EXCLUDES=("appdata" "system" "domains" "isos")

      for share in "${SHARES[@]}"; do
        skip=false
        for ex in "${EXCLUDES[@]}"; do
          [[ "$share" == "$ex" ]] && skip=true && break
        done
        [[ "$skip" == true ]] && { echo "Jdupes - Skipping excluded share: $share" >> "$LAST_RUN_FILE"; continue; }

        SHARE_PATH="/mnt/user/${share}"
        [[ -d "$SHARE_PATH" ]] || { echo "Jdupes - Skipping missing path: $SHARE_PATH" >> "$LAST_RUN_FILE"; continue; }

        echo "Jdupes processing share $share" >> "$LAST_RUN_FILE"
        /usr/bin/jdupes -rLX onlyext:mp4,mkv,avi -y "$HASH_DB" "$SHARE_PATH" 2>&1 \
          | grep -v -E \
              -e "^Creating a new hash database " \
              -e "^[[:space:]]*AT YOUR OWN RISK" \
              -e "^[[:space:]]*yet and basic" \
              -e "^[[:space:]]*but there are LOTS OF QUIRKS" \
              -e "^WARNING: THE HASH DATABASE FEATURE IS UNDER HEAVY DEVELOPMENT" \
          >> "$LAST_RUN_FILE"
        echo "Completed jdupes step for $share" >> "$LAST_RUN_FILE"
      done
    fi
  else
    echo "Jdupes not installed, skipping jdupes step" >> "$LAST_RUN_FILE"
  fi
elif [[ "$ENABLE_JDUPES" == "yes" ]]; then
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
echo "done" > /tmp/automover/automover_done.txt
echo "$PREV_STATUS" > "$STATUS_FILE"

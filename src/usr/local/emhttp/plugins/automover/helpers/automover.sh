#!/bin/bash
SCRIPT_NAME="automover"
LAST_RUN_FILE="/var/log/automover_last_run.log"
CFG_PATH="/boot/config/plugins/automover/settings.cfg"
AUTOMOVER_LOG="/var/log/automover_files_moved.log"
EXCLUSIONS_FILE="/boot/config/plugins/automover/exclusions.txt"
IN_USE_FILE="/tmp/automover/in_use_files.txt"

# ==========================================================
#  Prevent multiple concurrent runs
# ==========================================================
mkdir -p /tmp/automover
LOCK_FILE="/tmp/automover/automover.lock"

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
  rm -f "$LOCK_FILE"
  exit
}
trap cleanup EXIT SIGINT SIGTERM SIGHUP SIGQUIT

# ==========================================================
#  Load Settings
# ==========================================================
if [[ -f "$CFG_PATH" ]]; then
  source "$CFG_PATH"
else
  echo "Config file not found: $CFG_PATH" >> "$LAST_RUN_FILE"
  exit 1
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
    echo "qbittorrent script not found: $python_script" >> "$LAST_RUN_FILE"
    return
  fi

  echo "Running qbittorrent $action..." >> "$LAST_RUN_FILE"

  python3 "$python_script" \
    --host "$QBITTORRENT_HOST" \
    --user "$QBITTORRENT_USERNAME" \
    --password "$QBITTORRENT_PASSWORD" \
    --cache-mount "/mnt/$POOL_NAME" \
    --days_from "$QBITTORRENT_DAYS_FROM" \
    --days_to "$QBITTORRENT_DAYS_TO" \
    --status-filter "$QBITTORRENT_STATUS" \
    "--$action" 2>&1 | grep -E '^(Running qBittorrent|Paused|Resumed|qBittorrent)' >> "$LAST_RUN_FILE"

  echo "qbittorrent $action completed." >> "$LAST_RUN_FILE"
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
           QBITTORRENT_DAYS_FROM QBITTORRENT_DAYS_TO QBITTORRENT_STATUS; do
  eval "$var=\$(echo \${$var} | tr -d '\"')"
done

# ==========================================================
#  Move now mode disables all filters and restrictions
# ==========================================================
if [[ "$MOVE_NOW" == true ]]; then
  echo "Move now mode active — disabling all filters and checks" >> "$LAST_RUN_FILE"
  AGE_FILTER_ENABLED=false
  SIZE_FILTER_ENABLED=false
  AGE_BASED_FILTER="no"
  SIZE_BASED_FILTER="no"
  DRY_RUN="no"
  ALLOW_DURING_PARITY="yes"
  EXCLUSIONS_FILE="/dev/null"
  THRESHOLD=0
fi

# ==========================================================
#  Log Header
# ==========================================================
start_time=$(date +%s)
{
  echo "------------------------------------------------"
  echo "Automover session started - $(date '+%Y-%m-%d %H:%M:%S')"
  [[ "$MOVE_NOW" == true ]] && echo "Move now triggered — all filters and exclusions disabled"
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
#  Pause qBittorrent torrents if enabled (skip in dry run)
# ==========================================================
if [[ "$QBITTORRENT_SCRIPT" == "yes" && "$DRY_RUN" != "yes" ]]; then
  run_qbit_script pause
fi

# ==========================================================
#  Generate In-Use File Exclusion List
# ==========================================================
> "$IN_USE_FILE"

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

# ==========================================================
#  Parity Check Guard (unless MOVE_NOW)
# ==========================================================
if [[ "$ALLOW_DURING_PARITY" == "no" && "$MOVE_NOW" == false ]]; then
  if grep -Eq 'mdResync="([1-9][0-9]*)"' /var/local/emhttp/var.ini 2>/dev/null; then
    echo "Parity check in progress. Skipping this run." >> "$LAST_RUN_FILE"
    log_session_end
    exit 0
  fi
fi

# ==========================================================
#  Age & Size Filter Config
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
  echo "Dry run enabled — no files will actually be moved" >> "$LAST_RUN_FILE"
else
  RSYNC_OPTS+=(--remove-source-files)
fi

# ==========================================================
#  Pool Usage Check (skip if MOVE_NOW)
# ==========================================================
if [[ "$MOVE_NOW" == false ]]; then
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

  excludes=()
  if [[ "$MOVE_NOW" == false && -f "$EXCLUSIONS_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      excludes+=("--exclude=$line")
    done < "$EXCLUSIONS_FILE"
  fi

  if [[ -f "$IN_USE_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      excludes+=("--exclude=$line")
    done < "$IN_USE_FILE"
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
    echo "Dry run complete — no files were actually moved" >> "$LAST_RUN_FILE"
  else
    echo "No files moved for this run" >> "$AUTOMOVER_LOG"
    echo "No files moved for this run" >> "$LAST_RUN_FILE"
  fi
fi

# ==========================================================
#  Resume qBittorrent torrents if enabled (skip in dry run)
# ==========================================================
if [[ "$QBITTORRENT_SCRIPT" == "yes" && "$DRY_RUN" != "yes" ]]; then
  run_qbit_script resume
fi

log_session_end

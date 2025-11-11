#!/bin/bash
SCRIPT_NAME="automover"
LAST_RUN_FILE="/tmp/automover/automover_last_run.log"
CFG_PATH="/boot/config/plugins/automover/settings.cfg"
AUTOMOVER_LOG="/tmp/automover/automover_files_moved.log"
EXCLUSIONS_FILE="/boot/config/plugins/automover/automover_exclusions.txt"
IN_USE_FILE="/tmp/automover/automover_in_use_files.txt"
STATUS_FILE="/tmp/automover/automover_status.txt"
MOVED_SHARES_FILE="/tmp/automover/automover_moved_shares.txt"

# ==========================================================
#  Setup directories and lock
# ==========================================================
mkdir -p /tmp/automover
LOCK_FILE="/tmp/automover/automover_lock.txt"
> "$IN_USE_FILE"

# ==========================================================
#  Load Settings
# ==========================================================
set_status "Loading Config"
if [[ -f "$CFG_PATH" ]]; then
  source "$CFG_PATH"
else
  echo "Config file not found: $CFG_PATH" >> "$LAST_RUN_FILE"
  set_status "$PREV_STATUS"
  cleanup
fi

# ==========================================================
#  Unraid notifications helper
# ==========================================================
unraid_notify() {
  local title="$1"
  local message="$2"
  local level="${3:-normal}"
  local delay="${4:-0}"

  if (( delay > 0 )); then
    # Delay in minutes (for finish notifications)
    echo "/usr/local/emhttp/webGui/scripts/notify -e 'Automover' -s '$title' -d '$message' -i '$level'" | at now + "$delay" minutes
  else
    # Instant (for start notifications)
    /usr/local/emhttp/webGui/scripts/notify -e 'Automover' -s "$title" -d "$message" -i "$level"
  fi
}

# ==========================================================
#  Discord webhook helper
# ==========================================================
send_discord_message() {
  local title="$1"
  local message="$2"
  local color="${3:-65280}" # default = green
  local webhook="${WEBHOOK_URL:-}"

  # Only run if webhook is set and not empty
  [[ -z "$webhook" ]] && return

  # Ensure jq exists (for JSON encoding)
  if ! command -v jq >/dev/null 2>&1; then
    logger "jq not found; skipping Discord webhook notification"
    return
  fi

  local json
  json=$(jq -n \
    --arg title "$title" \
    --arg message "$message" \
    --argjson color "$color" \
    '{embeds: [{title: $title, description: $message, color: $color}]}')

  curl -s -X POST -H "Content-Type: application/json" -d "$json" "$webhook" >/dev/null 2>&1
}

# ==========================================================
#  Status helper
# ==========================================================
set_status() {
  local new_status="$1"
  echo "$new_status" > "$STATUS_FILE"
}

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

# ==========================================================
#  Always send finishing notification (with runtime + summary)
# ==========================================================
send_summary_notification() {
  [[ "$ENABLE_NOTIFICATIONS" != "yes" ]] && return
  if [[ "$PREV_STATUS" == "Stopped" && "$MOVE_NOW" == false ]]; then
    return
  fi

  # --- Skip if nothing moved ---
  if [[ "$moved_anything" != "true" ]]; then
    echo "No files moved - skipping sending notifications" >> "$LAST_RUN_FILE"
    return
  fi

  # --- Build per-share counts ---
  declare -A SHARE_COUNTS
  total_moved=0
  if [[ -f "$AUTOMOVER_LOG" && -s "$AUTOMOVER_LOG" ]]; then
    while IFS='>' read -r _ dst; do
      dst=$(echo "$dst" | xargs)
      [[ -z "$dst" ]] && continue
      share=$(echo "$dst" | awk -F'/' '$3=="user0"{print $4}')
      [[ -z "$share" ]] && continue
      ((SHARE_COUNTS["$share"]++))
      ((total_moved++))
    done < <(grep -E ' -> ' "$AUTOMOVER_LOG")
  fi

  # --- Calculate runtime ---
  end_time=$(date +%s)
  duration=$((end_time - start_time))
  if (( duration < 60 )); then
    runtime="${duration}s"
  elif (( duration < 3600 )); then
    mins=$((duration / 60)); secs=$((duration % 60))
    runtime="${mins}m ${secs}s"
  else
    hours=$((duration / 3600)); mins=$(((duration % 3600) / 60))
    runtime="${hours}h ${mins}m"
  fi

  # --- Base message ---
  notif_body="Automover finished moving ${total_moved} file(s) in ${runtime}."

  # --- Discord: add per-share summary (alphabetical) ---
  if [[ -n "$WEBHOOK_URL" ]]; then
    if (( ${#SHARE_COUNTS[@]} > 0 )); then
      notif_body+="

Per share summary:"
      while IFS= read -r share; do
        notif_body+="
• ${share}: ${SHARE_COUNTS[$share]} file(s)"
      done < <(printf '%s\n' "${!SHARE_COUNTS[@]}" | LC_ALL=C sort)
    fi

    # Send with real newlines preserved
    send_discord_message "Automover session finished" "$notif_body" 65280

  else
    # --- Unraid notify: add per-share summary with <br> ---
    notif_body_html="$notif_body"

    if (( ${#SHARE_COUNTS[@]} > 0 )); then
      notif_body_html+="<br><br>Per share summary:<br>"
      while IFS= read -r share; do
        notif_body_html+="• ${share}: ${SHARE_COUNTS[$share]} file(s)<br>"
      done < <(printf '%s\n' "${!SHARE_COUNTS[@]}" | LC_ALL=C sort)
    fi

    unraid_notify "Automover session finished" "$notif_body_html" "normal" 1
  fi
}

# ==========================================================
#  Cleanup
# ==========================================================
cleanup() {
  # Called when interrupted (SIGINT, SIGTERM, etc.)
  set_status "$PREV_STATUS"
  rm -f "$LOCK_FILE"
}
trap cleanup SIGINT SIGTERM SIGHUP SIGQUIT

rm -f /tmp/automover/automover_done.txt
> "$MOVED_SHARES_FILE"

# ==========================================================
#  qBittorrent helper
# ==========================================================
run_qbit_script() {
  local action="$1"
  local python_script="/usr/local/emhttp/plugins/automover/helpers/qbittorrent_script.py"
  [[ ! -f "$python_script" ]] && echo "Qbittorrent script not found: $python_script" >> "$LAST_RUN_FILE" && return
  echo "Starting qbittorrent $action of torrents" >> "$LAST_RUN_FILE"
  python3 "$python_script" \
    --host "$QBITTORRENT_HOST" \
    --user "$QBITTORRENT_USERNAME" \
    --password "$QBITTORRENT_PASSWORD" \
    --cache-mount "/mnt/$POOL_NAME" \
    --days_from "$QBITTORRENT_DAYS_FROM" \
    --days_to "$QBITTORRENT_DAYS_TO" \
    --status-filter "$QBITTORRENT_STATUS" \
    "--$action" 2>&1 | grep -E '^(Running qBittorrent|Paused|Resumed|qBittorrent)' >> "$LAST_RUN_FILE"
  echo "Finished qbittorrent $action of torrents" >> "$LAST_RUN_FILE"
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

# ==========================================================
#  Skip scheduled runs if Automover is stopped (unless Move Now)
# ==========================================================
if [[ "$MOVE_NOW" != true ]]; then
  if [[ -f "$STATUS_FILE" && "$(cat "$STATUS_FILE")" == "Stopped" ]]; then
    exit 0
  fi
fi

for var in AGE_DAYS THRESHOLD INTERVAL POOL_NAME DRY_RUN ALLOW_DURING_PARITY \
           AGE_BASED_FILTER SIZE_BASED_FILTER SIZE_MB EXCLUSIONS_ENABLED \
           QBITTORRENT_SCRIPT QBITTORRENT_HOST QBITTORRENT_USERNAME QBITTORRENT_PASSWORD \
           QBITTORRENT_DAYS_FROM QBITTORRENT_DAYS_TO QBITTORRENT_STATUS HIDDEN_FILTER \
           FORCE_RECONSTRUCTIVE_WRITE CONTAINER_NAMES ENABLE_JDUPES HASH_PATH ENABLE_CLEANUP \
           MODE CRON_EXPRESSION STOP_THRESHOLD ENABLE_NOTIFICATIONS; do
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
    mins=$((duration / 60)); secs=$((duration % 60))
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
    set_status "Check If Parity Is In Progress"
    echo "Parity check in progress — skipping" >> "$LAST_RUN_FILE"
    log_session_end; cleanup
  fi
fi

# ==========================================================
#  Filters
# ==========================================================
if [[ "$MOVE_NOW" == false ]]; then
  set_status "Applying Filters"
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
set_status "Prepping Rsync"
RSYNC_OPTS=(-aiHAX --numeric-ids --checksum --perms --owner --group)
[[ "$DRY_RUN" == "yes" ]] && RSYNC_OPTS+=(--dry-run) || RSYNC_OPTS+=(--remove-source-files)

# ==========================================================
#  Pool usage check
# ==========================================================
set_status "Checking Usage"
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
  set_status "Checking Stop Threshold"
  echo "Usage already below stop threshold:$STOP_THRESHOLD% — skipping moves" >> "$LAST_RUN_FILE"
  log_session_end; cleanup
fi

# ==========================================================
#  Update status to "Moving Files"
# ==========================================================
if [[ "$DRY_RUN" == "yes" ]]; then
  set_status "Dry Run: Simulating Moves"
  echo "Dry Run: Simulating Moves" >> "$LAST_RUN_FILE"
else
  set_status "Starting Move Process"
  echo "Starting move process" >> "$LAST_RUN_FILE"
fi

# ==========================================================
#  Log which filters are enabled
# ==========================================================
if [[ "$MOVE_NOW" == false ]]; then
  filters_active=false
  if [[ "$HIDDEN_FILTER" == "yes" || "$SIZE_BASED_FILTER" == "yes" || "$AGE_BASED_FILTER" == "yes" || "$EXCLUSIONS_ENABLED" == "yes" ]]; then
    filters_active=true
  fi
  if [[ "$filters_active" == true ]]; then
    {
      echo "***************** Filters Used *****************"
      [[ "$HIDDEN_FILTER" == "yes" ]] && echo "Hidden Filter Enabled"
      [[ "$SIZE_BASED_FILTER" == "yes" ]] && echo "Size Based Filter Enabled (${SIZE_MB} MB)"
      [[ "$AGE_BASED_FILTER" == "yes" ]] && echo "Age Based Filter Enabled (${AGE_DAYS} days)"
      [[ "$EXCLUSIONS_ENABLED" == "yes" ]] && echo "Exclusions Enabled"
      echo "***************** Filters Used *****************"
    } >> "$LAST_RUN_FILE"
  fi
fi

# ==========================================================
#  Load exclusions if enabled
# ==========================================================
EXCLUDED_PATHS=()
if [[ "$EXCLUSIONS_ENABLED" == "yes" && -f "$EXCLUSIONS_FILE" ]]; then
  while IFS= read -r line; do
    line=$(echo "$line" | sed 's/\r//g' | xargs)
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    EXCLUDED_PATHS+=("$line")
  done < "$EXCLUSIONS_FILE"
fi

# ==========================================================
#  Main move logic (alphabeticalized)
# ==========================================================
moved_anything=false
STOP_TRIGGERED=false
SHARE_CFG_DIR="/boot/config/shares"
pre_move_done="no"
sent_start_notification="no"

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

  # Determine candidate files (alphabetically)
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

  # ==========================================================
  #  Check for eligible files before moving (pre-move trigger)
  # ==========================================================
eligible_count=0
for relpath in "${all_filtered_items[@]}"; do
  [[ -z "$relpath" ]] && continue
  srcfile="$src/$relpath"

  # Skip exclusions
  if [[ "$EXCLUSIONS_ENABLED" == "yes" && ${#EXCLUDED_PATHS[@]} -gt 0 ]]; then
    skip_file=false
    for ex in "${EXCLUDED_PATHS[@]}"; do
      [[ -d "$ex" ]] && ex="${ex%/}/"
      if [[ "$srcfile" == "$ex"* || "$srcfile" == "$src/$ex"* ]]; then
        skip_file=true; break
      fi
    done
    $skip_file && continue
  fi

  # Skip if file in use
  if fuser "$srcfile" >/dev/null 2>&1; then
    grep -qxF "$srcfile" "$IN_USE_FILE" 2>/dev/null || echo "$srcfile" >> "$IN_USE_FILE"
    continue
  fi

  ((eligible_count++))
  # No need to break; we’ll just count them all
done

if [[ "$pre_move_done" != "yes" && "$eligible_count" -ge 1 ]]; then
  # --- Send start notification only once when actual move begins ---
if [[ "$ENABLE_NOTIFICATIONS" == "yes" && "$sent_start_notification" != "yes" && "$eligible_count" -ge 1 ]]; then
  title="Automover session started"
  message="Automover is beginning to move eligible files."

  if [[ -n "$WEBHOOK_URL" ]]; then
    send_discord_message "$title" "$message" 16776960  # yellow/orange color
  else
    unraid_notify "$title" "$message" "normal" 0
  fi

  sent_start_notification="yes"
fi

    # --- Enable turbo write ---
    if [[ "$FORCE_RECONSTRUCTIVE_WRITE" == "yes" && "$DRY_RUN" != "yes" ]]; then
      set_status "Enabling Turbo Write"
      turbo_write_prev=$(grep -Po 'md_write_method="\K[^"]+' /var/local/emhttp/var.ini 2>/dev/null)
      echo "$turbo_write_prev" > /tmp/automover_prev_write_method
      logger "Force turbo write on"
      /usr/local/sbin/mdcmd set md_write_method 1
      echo "Enabled reconstructive write mode (turbo write)" >> "$LAST_RUN_FILE"
      turbo_write_enabled=true
    fi
    # --- Stop managed containers ---
    if [[ -n "$CONTAINER_NAMES" && "$DRY_RUN" != "yes" ]]; then
      set_status "Stopping Containers"
      IFS=',' read -ra CONTAINERS <<< "$CONTAINER_NAMES"
      for container in "${CONTAINERS[@]}"; do
        container=$(echo "$container" | xargs)
        [[ -z "$container" ]] && continue
        echo "Stopping Docker container: $container" >> "$LAST_RUN_FILE"
        docker stop "$container" || echo "Failed to stop container: $container" >> "$LAST_RUN_FILE"
      done
      containers_stopped=true
    fi
# --- qBittorrent dependency check + pause ---
if [[ "$QBITTORRENT_SCRIPT" == "yes" && "$DRY_RUN" != "yes" ]]; then
  if ! python3 -m pip show qbittorrent-api >/dev/null 2>&1; then
    echo "Installing qbittorrent-api" >> "$LAST_RUN_FILE"
    command -v pip3 >/dev/null 2>&1 && pip3 install qbittorrent-api -q >/dev/null 2>&1
  fi
  set_status "Pausing Torrents"
  run_qbit_script pause
  qbit_paused=true
fi

# --- Clear mover log only once when the first move begins ---
if [[ "$pre_move_done" != "yes" && "$eligible_count" -ge 1 ]]; then
  if [[ -f "$AUTOMOVER_LOG" ]]; then
    rm -f "$AUTOMOVER_LOG"
  fi
fi
pre_move_done="yes"
  fi

  echo "Starting move of $file_count file(s) for share: $share_name" >> "$LAST_RUN_FILE"
  set_status "Moving Files For Share: $share_name"

  tmpfile=$(mktemp)
  printf '%s\n' "${all_filtered_items[@]}" > "$tmpfile"
  file_count_moved=0
  src_owner=$(stat -c "%u" "$src")
  src_group=$(stat -c "%g" "$src")
  src_perms=$(stat -c "%a" "$src")

  while IFS= read -r relpath; do
    [[ -z "$relpath" ]] && continue
    srcfile="$src/$relpath"; dstfile="$dst/$relpath"; dstdir="$(dirname "$dstfile")"
    # Skip exclusions
    if [[ "$EXCLUSIONS_ENABLED" == "yes" && ${#EXCLUDED_PATHS[@]} -gt 0 ]]; then
      skip_file=false
      for ex in "${EXCLUDED_PATHS[@]}"; do
        [[ -d "$ex" ]] && ex="${ex%/}/"
        if [[ "$srcfile" == "$ex"* || "$srcfile" == "$src/$ex"* ]]; then
          skip_file=true; break
        fi
      done
      $skip_file && continue
    fi
    # Skip if file is currently in use
    if fuser "$srcfile" >/dev/null 2>&1; then
      grep -qxF "$srcfile" "$IN_USE_FILE" 2>/dev/null || echo "$srcfile" >> "$IN_USE_FILE"
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
        echo "Move stopped - pool usage reached stop threshold:$STOP_THRESHOLD%" >> "$LAST_RUN_FILE"
        STOP_TRIGGERED=true
        break
      fi
    fi
  done < "$tmpfile"
  rm -f "$tmpfile"

  echo "Finished move of $file_count_moved file(s) for share: $share_name" >> "$LAST_RUN_FILE"
  if (( file_count_moved > 0 )); then
    moved_anything=true
    echo "$share_name" >> "$MOVED_SHARES_FILE"
  fi
  [[ "$STOP_TRIGGERED" == true ]] && break
done

# ==========================================================
#  If no shares had eligible files — log skipped pre-move actions
# ==========================================================
if [[ "$pre_move_done" != "yes" ]]; then
  if [[ "$FORCE_RECONSTRUCTIVE_WRITE" == "yes" ]]; then
    echo "No files moved - skipping enabling reconstructive write (turbo write)" >> "$LAST_RUN_FILE"
  fi
  if [[ -n "$CONTAINER_NAMES" ]]; then
    echo "No files moved - skipping stopping of containers" >> "$LAST_RUN_FILE"
  fi
  if [[ "$QBITTORRENT_SCRIPT" == "yes" ]]; then
    echo "No files moved - skipping pausing of qbittorrent torrents" >> "$LAST_RUN_FILE"
  fi
fi

# ==========================================================
#  In-use file summary
# ==========================================================
if [[ -s "$IN_USE_FILE" ]]; then
  set_status "In-Use Summary"
  sort -u "$IN_USE_FILE" -o "$IN_USE_FILE"
  count_inuse=$(wc -l < "$IN_USE_FILE")
  echo "Skipped $count_inuse in-use file(s)" >> "$LAST_RUN_FILE"
else
  echo "No in-use files detected during move" >> "$LAST_RUN_FILE"
fi

# ==========================================================
#  Handle case where all files were in-use
# ==========================================================
if [[ "$moved_anything" == false && -s "$IN_USE_FILE" ]]; then
  moved_anything=false
fi

# ==========================================================
#  Resume qBittorrent torrents
# ==========================================================
if [[ "$qbit_paused" == true && "$QBITTORRENT_SCRIPT" == "yes" ]]; then
  set_status "Resuming Torrents"
  run_qbit_script resume
fi

# ==========================================================
#  Start managed containers
# ==========================================================
if [[ "$containers_stopped" == true && -n "$CONTAINER_NAMES" ]]; then
  set_status "Starting Containers"
  IFS=',' read -ra CONTAINERS <<< "$CONTAINER_NAMES"
  for container in "${CONTAINERS[@]}"; do
    container=$(echo "$container" | xargs)
    [[ -z "$container" ]] && continue
    echo "Starting Docker container: $container" >> "$LAST_RUN_FILE"
    docker start "$container" || echo "Failed to start container: $container" >> "$LAST_RUN_FILE"
  done
fi

# ==========================================================
#  Finished move process
# ==========================================================
if [[ "$DRY_RUN" != "yes" ]]; then
  echo "Finished move process" >> "$LAST_RUN_FILE"
fi

# ==========================================================
#  Cleanup Empty Folders (including ZFS datasets) - ONLY moved shares
# ==========================================================
if [[ "$ENABLE_CLEANUP" == "yes" ]]; then
  set_status "Cleaning Up"
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "Dry run active — skipping cleanup of empty folders/datasets" >> "$LAST_RUN_FILE"
  elif [[ "$moved_anything" == true ]]; then
    if [[ ! -s "$MOVED_SHARES_FILE" ]]; then
      echo "No moved shares recorded — skipping cleanup" >> "$LAST_RUN_FILE"
    else
      # sort unique in case same share got added twice
      while IFS= read -r share_name; do
        [[ -z "$share_name" ]] && continue

        # force exclude these 4
        case "$share_name" in
          appdata|system|domains|isos)
            echo "Skipping cleanup for excluded share: $share_name" >> "$LAST_RUN_FILE"
            continue
            ;;
        esac

        cfg="$SHARE_CFG_DIR/$share_name.cfg"
        [[ -f "$cfg" ]] || continue

        pool1=$(grep -E '^shareCachePool=' "$cfg" | cut -d'=' -f2- | tr -d '"' | tr -d '\r' | xargs)
        pool2=$(grep -E '^shareCachePool2=' "$cfg" | cut -d'=' -f2- | tr -d '"' | tr -d '\r' | xargs)
        [[ -z "$pool1" && -z "$pool2" ]] && continue

        for pool in "$pool1" "$pool2"; do
          [[ -z "$pool" ]] && continue
          base_path="/mnt/$pool/$share_name"
          [[ ! -d "$base_path" ]] && continue

          # remove empty dirs
          find "$base_path" -type d -empty -delete 2>/dev/null

          # zfs datasets
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
      done < <(sort -u "$MOVED_SHARES_FILE")
      echo "Cleanup of empty folders/datasets finished" >> "$LAST_RUN_FILE"
    fi
  else
    echo "No files moved — skipping cleanup of empty folders/datasets" >> "$LAST_RUN_FILE"
  fi
fi

# ==========================================================
#  Re-hardlink media duplicates using jdupes
# ==========================================================
if [[ "$ENABLE_JDUPES" == "yes" && "$DRY_RUN" != "yes" && "$moved_anything" == true ]]; then
  set_status "Running Jdupes"
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

    # get list of moved files (dest side)
    grep -E -- ' -> ' "$AUTOMOVER_LOG" | awk -F'->' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' > "$TEMP_LIST"

    if [[ ! -s "$TEMP_LIST" ]]; then
      echo "No moved files found, skipping jdupes step" >> "$LAST_RUN_FILE"
    else
      # collect shares moved to /mnt/user0/{share}
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
if [[ "$FORCE_RECONSTRUCTIVE_WRITE" == "yes" && "$moved_anything" == true ]]; then
  set_status "Restoring Turbo Write Setting"
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "Dry run active — skipping restoring md_write_method to previous value" >> "$LAST_RUN_FILE"
  else
    turbo_write_mode=$(grep -Po 'md_write_method="\K[^"]+' /var/local/emhttp/var.ini 2>/dev/null)
    if [[ -n "$turbo_write_mode" ]]; then
      # Translate numeric mode to human-readable text
      case "$turbo_write_mode" in
        0) mode_name="read/modify/write" ;;
        1) mode_name="reconstruct write" ;;
        auto) mode_name="auto" ;;
        *) mode_name="unknown ($turbo_write_mode)" ;;
      esac

      logger "Restoring md_write_method to previous value: $mode_name"
      /usr/local/sbin/mdcmd set md_write_method "$turbo_write_mode"
      echo "Restored md_write_method to previous value: $mode_name" >> "$LAST_RUN_FILE"
    fi
  fi
fi

# ==========================================================
#  Final check and backup handling
# ==========================================================
mkdir -p "$(dirname "$AUTOMOVER_LOG")"

if [[ "$moved_anything" == "true" && -s "$AUTOMOVER_LOG" ]]; then
  # Actual files were moved → update the "previous" log for next run
  cp -f "$AUTOMOVER_LOG" "${AUTOMOVER_LOG%/*}/automover_files_moved_prev.log"

else
  # Nothing moved → keep previous log intact, just mark the current one
  : > "$AUTOMOVER_LOG"
  echo "No files moved for this run - displaying the prior run moved files below" >> "$AUTOMOVER_LOG"
fi

# ==========================================================
#  Finish and signal
# ==========================================================
send_summary_notification
log_session_end
mkdir -p /tmp/automover
echo "done" > /tmp/automover/automover_done.txt

# Reset status and release lock
set_status "$PREV_STATUS"
rm -f "$LOCK_FILE"

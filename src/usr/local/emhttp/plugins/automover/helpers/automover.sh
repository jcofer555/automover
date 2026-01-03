#!/bin/bash
SCRIPT_NAME="automover"
LAST_RUN_FILE="/tmp/automover/last_run.log"
CFG_PATH="/boot/config/plugins/automover/settings.cfg"
AUTOMOVER_LOG="/tmp/automover/files_moved.log"
EXCLUSIONS_FILE="/boot/config/plugins/automover/exclusions.txt"
IN_USE_FILE="/tmp/automover/in_use_files.txt"
STATUS_FILE="/tmp/automover/temp_logs/status.txt"
MOVED_SHARES_FILE="/tmp/automover/temp_logs/moved_shares.txt"
STOP_FILE="/tmp/automover/temp_logs/stopped_containers.txt"

# ==========================================================
#  Setup directories and lock
# ==========================================================
mkdir -p /tmp/automover/temp_logs
LOCK_FILE="/tmp/automover/lock.txt"
> "$IN_USE_FILE"
> "/tmp/automover/temp_logs/cleanup_sources.txt"
rm -f "/tmp/automover/temp_logs/qbittorrent_parser.txt"
> "/tmp/automover/qbittorrent_paused.txt"
> "/tmp/automover/qbittorrent_resumed.txt"
RSYNC_SPEED_FILE="/tmp/automover/temp_logs/rsync_speed.txt"
> "$RSYNC_SPEED_FILE"

# ==========================================================
#  Unraid notifications helper
# ==========================================================
unraid_notify() {
  local title="$1"
  local message="$2"
  local level="${3:-normal}"
  local delay="${4:-0}"

  if (( delay > 0 )); then
    echo "/usr/local/emhttp/webGui/scripts/notify -e 'Automover' -s '$title' -d '$message' -i '$level'" | at now + "$delay" minutes
  else
    /usr/local/emhttp/webGui/scripts/notify -e 'Automover' -s "$title" -d "$message" -i "$level"
  fi
}

# ==========================================================
#  Discord webhook helper
# ==========================================================
send_discord_message() {
  local title="$1"
  local message="$2"
  local color="${3:-65280}"
  local webhook="${WEBHOOK_URL:-}"

  [[ -z "$webhook" ]] && return

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

  if [[ "$moved_anything" != "true" ]]; then
    echo "No files moved - skipping sending notifications" >> "$LAST_RUN_FILE"
    return
  fi

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

  notif_body="Automover finished moving ${total_moved} file(s) in ${runtime}."

  if [[ -n "$WEBHOOK_URL" ]]; then
    if (( ${#SHARE_COUNTS[@]} > 0 )); then
      notif_body+="

Per share summary:"
      while IFS= read -r share; do
        notif_body+="
• ${share}: ${SHARE_COUNTS[$share]} file(s)"
      done < <(printf '%s\n' "${!SHARE_COUNTS[@]}" | LC_ALL=C sort)
    fi
    send_discord_message "Automover session finished" "$notif_body" 65280
  else
    notif_body_html="$notif_body"
    notif_cfg="/boot/config/plugins/dynamix/dynamix.cfg"
    agent_active=false

    if [[ -f "$notif_cfg" ]]; then
      normal_val=$(grep -Po 'normal="\K[0-9]+' "$notif_cfg" 2>/dev/null)
      if [[ "$normal_val" =~ ^(4|5|6|7)$ ]]; then
        agent_active=true
      elif [[ "$normal_val" == "0" ]]; then
        echo "Unraid's notice notifications are disabled at Settings > Notifications" >> "$LAST_RUN_FILE"
      fi
    fi

    if [[ "$agent_active" == true ]]; then
      if (( ${#SHARE_COUNTS[@]} > 0 )); then
        notif_body_html+=" - Per share summary: "
        first=true
        while IFS= read -r share; do
          if [[ "$first" == true ]]; then
            notif_body_html+="${share}: ${SHARE_COUNTS[$share]} file(s)"
            first=false
          else
            notif_body_html+=" - ${share}: ${SHARE_COUNTS[$share]} file(s)"
          fi
        done < <(printf '%s\n' "${!SHARE_COUNTS[@]}" | LC_ALL=C sort)
      fi
    else
      if (( ${#SHARE_COUNTS[@]} > 0 )); then
        notif_body_html+="<br><br>Per share summary:<br>"
        while IFS= read -r share; do
          notif_body_html+="• ${share}: ${SHARE_COUNTS[$share]} file(s)<br>"
        done < <(printf '%s\n' "${!SHARE_COUNTS[@]}" | LC_ALL=C sort)
      fi
    fi
    unraid_notify "Automover session finished" "$notif_body_html" "normal" 1
  fi
}

# ==========================================================
#  Manage containers (stop/start)
# ==========================================================
containers_stopped=false

manage_containers() {
  local action="$1"
  local STOP_FILE="/tmp/automover/temp_logs/stopped_containers.txt"
  mkdir -p /tmp/automover/temp_logs

  if [[ "$STOP_ALL_CONTAINERS" == "yes" && "$DRY_RUN" != "yes" ]]; then
    if [[ "$action" == "stop" ]]; then
      set_status "Stopping all docker containers"
      echo "Stopping all docker containers" >> "$LAST_RUN_FILE"
      : > "$STOP_FILE"
      for cid in $(docker ps -q); do
        cname=$(docker inspect --format='{{.Name}}' "$cid" | sed 's#^/##')
        if docker stop "$cid" >/dev/null 2>&1; then
          echo "Stopped container: $cname" >> "$LAST_RUN_FILE"
          echo "$cname" >> "$STOP_FILE"
        else
          echo "❌ Failed to stop container: $cname" >> "$LAST_RUN_FILE"
        fi
      done
      containers_stopped=true

    elif [[ "$action" == "start" && "$containers_stopped" == true ]]; then
      set_status "Starting docker containers that automover stopped"
      echo "Starting docker containers that automover stopped" >> "$LAST_RUN_FILE"
      if [[ -f "$STOP_FILE" ]]; then
        while read -r cname; do
          [[ -z "$cname" ]] && continue
          if docker start "$cname" >/dev/null 2>&1; then
            echo "Started container: $cname" >> "$LAST_RUN_FILE"
          else
            echo "❌ Failed to start container: $cname" >> "$LAST_RUN_FILE"
          fi
        done < "$STOP_FILE"
        rm -f "$STOP_FILE"
      fi
    fi

  elif [[ -n "$CONTAINER_NAMES" && "$DRY_RUN" != "yes" ]]; then
    IFS=',' read -ra CONTAINERS <<< "$CONTAINER_NAMES"
    if [[ "$action" == "stop" ]]; then
      set_status "Stopping selected containers"
      : > "$STOP_FILE"
      for container in "${CONTAINERS[@]}"; do
        container=$(echo "$container" | xargs)
        [[ -z "$container" ]] && continue
        if docker stop "$container" >/dev/null 2>&1; then
          echo "Stopped container: $container" >> "$LAST_RUN_FILE"
          echo "$container" >> "$STOP_FILE"
        else
          echo "❌ Failed to stop container: $container" >> "$LAST_RUN_FILE"
        fi
      done
      containers_stopped=true

    elif [[ "$action" == "start" && "$containers_stopped" == true ]]; then
      set_status "Starting selected containers"
      if [[ -f "$STOP_FILE" ]]; then
        while read -r container; do
          [[ -z "$container" ]] && continue
          if docker start "$container" >/dev/null 2>&1; then
            echo "Started container: $container" >> "$LAST_RUN_FILE"
          else
            echo "❌ Failed to start container: $container" >> "$LAST_RUN_FILE"
          fi
        done < "$STOP_FILE"
        rm -f "$STOP_FILE"
      fi
    fi
  fi
}

# ==========================================================
#  Cleanup
# ==========================================================
cleanup() {
  set_status "$PREV_STATUS"
  rm -f "$LOCK_FILE"
  exit "${1:-0}"
}
trap 'cleanup 0' SIGINT SIGTERM SIGHUP SIGQUIT

rm -f /tmp/automover/temp_logs/done.txt
> "$MOVED_SHARES_FILE"

# ==========================================================
#  qBittorrent helper
# ==========================================================
run_qbit_script() {
  local action="$1"
  local python_script="/usr/local/emhttp/plugins/automover/helpers/qbittorrent_script.py"
  local paused_file="/tmp/automover/qbittorrent_paused.txt"
  local resumed_file="/tmp/automover/qbittorrent_resumed.txt"
  local tmp_out="/tmp/automover/temp_logs/qbittorrent_parser.txt"

  # make sure temp_logs dir exists
  mkdir -p /tmp/automover/temp_logs

  [[ ! -f "$python_script" ]] && echo "Qbittorrent script not found: $python_script" >> "$LAST_RUN_FILE" && return

  # Capture full output into tmp_out AND apply filtered grep to LAST_RUN_FILE
  python3 "$python_script" \
    --host "$QBITTORRENT_HOST" \
    --user "$QBITTORRENT_USERNAME" \
    --password "$QBITTORRENT_PASSWORD" \
    --cache-mount "/mnt/$POOL_NAME" \
    --days_from "$QBITTORRENT_DAYS_FROM" \
    --days_to "$QBITTORRENT_DAYS_TO" \
    --status-filter "$QBITTORRENT_STATUS" \
    "--$action" 2>&1 | tee "$tmp_out" \
      | grep -E '^(Running qBittorrent|Paused|Resumed|Pausing|Resuming|qBittorrent)' \
      >> "$LAST_RUN_FILE"

  # Extract paused torrents
grep -E "Pausing:|Paused:" "$tmp_out" \
  | sed -E 's/.*(Pausing:|Paused:)\s*//; s/\s*\[[0-9]+\]\s*$//' \
  >> "$paused_file"

  # Extract resumed torrents
grep -E "Resuming:|Resumed:" "$tmp_out" \
  | sed -E 's/.*(Resuming:|Resumed:)\s*//; s/\s*\[[0-9]+\]\s*$//' \
  >> "$resumed_file"

  echo "Qbittorrent $action of torrents" >> "$LAST_RUN_FILE"
}

# ==========================================================
#  Load Settings
# ==========================================================
set_status "Loading Config"
if [[ -f "$CFG_PATH" ]]; then
  source "$CFG_PATH"
else
  echo "Config file not found: $CFG_PATH" >> "$LAST_RUN_FILE"
  set_status "$PREV_STATUS"
  cleanup 0
fi

# Disable notifications completely when dry run is active
if [[ "$DRY_RUN" == "yes" ]]; then
  ENABLE_NOTIFICATIONS="no"
fi

# ==========================================================
#  Run Pre/Post Scripts
# ==========================================================
run_script() {
    local script_path="$1"
    local script_name
    script_name=$(basename "$script_path")

    # Make sure the file exists
    if [[ ! -f "$script_path" ]]; then
        echo "Script not found: $script_path" >> "$LAST_RUN_FILE"
        return 1
    fi

    # Make script executable if it's a normal shell script
    chmod +x "$script_path" 2>/dev/null

    # Detect type by extension (optional) or use shebang
    case "$script_path" in
        *.sh|*.bash)
            bash "$script_path"
            ;;
        *.php)
            /usr/bin/php "$script_path"
            ;;
        *)
            # Fallback: try to execute directly (shebang must be set)
            "$script_path"
            ;;
    esac
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
           MODE CRON_EXPRESSION STOP_THRESHOLD ENABLE_NOTIFICATIONS STOP_ALL_CONTAINERS \
           ENABLE_TRIM ENABLE_SCRIPTS PRE_SCRIPT POST_SCRIPT \
           PROCESS_PRIORITY IO_PRIORITY PRIORITIES; do
  eval "$var=\$(echo \${$var} | tr -d '\"')"
done

# ==========================
# Normalize priority values
# ==========================

# PRIORITIES flag: only "yes" enables priority wrapper
if [[ "$PRIORITIES" != "yes" ]]; then
  PROCESS_PRIORITY=""
  IO_CLASS=""
  IO_LEVEL=""
else
  # CPU nice priority: -20 to 19
  if [[ -z "$PROCESS_PRIORITY" || ! "$PROCESS_PRIORITY" =~ ^-?[0-9]+$ ]]; then
    PROCESS_PRIORITY=0
  elif (( PROCESS_PRIORITY < -20 )); then
    PROCESS_PRIORITY=-20
  elif (( PROCESS_PRIORITY > 19 )); then
    PROCESS_PRIORITY=19
  fi

  # IO priority:
  # Allowed:
  #   idle      → ionice -c3
  #   be:N      → ionice -c2 -n N
  #
case "$IO_PRIORITY" in
  idle)
    IO_CLASS=3
    IO_LEVEL=""
    ;;
  be:[0-7])
    IO_CLASS=2
    IO_LEVEL="${IO_PRIORITY#be:}"
    ;;
  normal|"")
    IO_CLASS=""
    IO_LEVEL=""
    ;;
  *)
    # fallback to normal
    IO_CLASS=""
    IO_LEVEL=""
    ;;
esac
fi

# ==========================================================
#  Header
# ==========================================================
start_time=$(date +%s)

{
  echo "------------------------------------------------"
  echo "Automover session started - $(date '+%Y-%m-%d %H:%M:%S')"
  [[ "$MOVE_NOW" == true ]] && echo "Move now triggered — filters disabled"
  # --- Log exclusions state when Move Now is pressed ---
if [[ "$MOVE_NOW" == true && "$EXCLUSIONS_ENABLED" == "yes" ]]; then
  echo "Exclusions Enabled" >> "$LAST_RUN_FILE"
fi
} >> "$LAST_RUN_FILE"

log_session_end() {
if [[ "$moved_anything" == true ]]; then
    if [[ "$PRIORITIES" == "yes" ]]; then
        echo "Cpu priority: $PROCESS_PRIORITY" >> "$LAST_RUN_FILE"

        if [[ "$IO_PRIORITY" == "normal" ]]; then
            echo "I/O priority: normal" >> "$LAST_RUN_FILE"
        elif [[ "$IO_CLASS" == "3" ]]; then
            echo "I/O priority: idle" >> "$LAST_RUN_FILE"
        else
            echo "I/O priority: best-effort $IO_LEVEL" >> "$LAST_RUN_FILE"
        fi
    fi
fi

if [[ "$moved_anything" == true && -s "$RSYNC_SPEED_FILE" ]]; then
  avg_speed=$(awk '{sum+=$1; n++} END {if (n>0) printf "%.2f", sum/n; else print 0}' "$RSYNC_SPEED_FILE")
  echo "Average move speed: ${avg_speed} MB/s" >> "$LAST_RUN_FILE"
fi

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
    log_session_end; cleanup 0
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
RSYNC_OPTS=(-aiHAX --numeric-ids --checksum --perms --owner --group --info=progress2)
[[ "$DRY_RUN" == "yes" ]] && RSYNC_OPTS+=(--dry-run) || RSYNC_OPTS+=(--remove-source-files)

# ==========================================================
# Build rsync priority wrapper
# ==========================================================
RSYNC_WRAPPER=()

if [[ "$PRIORITIES" == "yes" ]]; then

  # CPU priority
  if [[ -n "$PROCESS_PRIORITY" ]]; then
    RSYNC_WRAPPER+=(nice -n "$PROCESS_PRIORITY")
  fi

  # IO priority
  if [[ -n "$IO_CLASS" ]]; then
    if [[ "$IO_CLASS" == "3" ]]; then
      RSYNC_WRAPPER+=(ionice -c3)
    elif [[ "$IO_CLASS" == "2" ]]; then
      RSYNC_WRAPPER+=(ionice -c2 -n "$IO_LEVEL")
    fi
  fi

fi

# ==========================================================
#  Pool usage check
# ==========================================================
set_status "Checking Usage"
if [[ "$MOVE_NOW" == false && "$DRY_RUN" != "yes" ]]; then
  POOL_NAME=$(basename "$MOUNT_POINT")
  ZFS_CAP=$(zpool list -H -o name,cap 2>/dev/null | awk -v pool="$POOL_NAME" '$1 == pool {gsub("%","",$2); print $2}')
  [[ -n "$ZFS_CAP" ]] && USED="$ZFS_CAP" || USED=$(df -h --output=pcent "$MOUNT_POINT" | awk 'NR==2 {gsub("%",""); print}')
  [[ -z "$USED" ]] && echo "$MOUNT_POINT usage not detected — nothing to do" >> "$LAST_RUN_FILE" && log_session_end && cleanup 0
  echo "$POOL_NAME usage:${USED}% Threshold:${THRESHOLD}% Stop Threshold:${STOP_THRESHOLD}%" >> "$LAST_RUN_FILE"
  if [[ "$USED" -le "$THRESHOLD" ]]; then
    echo "Usage below threshold — nothing to do" >> "$LAST_RUN_FILE"; log_session_end; cleanup 0
  fi
fi

# ==========================================================
#  Stop threshold pre-check
# ==========================================================
if [[ "$MOVE_NOW" == false && "$DRY_RUN" != "yes" && "$STOP_THRESHOLD" -gt 0 && "$USED" -le "$STOP_THRESHOLD" ]]; then
  set_status "Checking Stop Threshold"
  echo "Usage already below stop threshold:$STOP_THRESHOLD% — skipping moves" >> "$LAST_RUN_FILE"
  log_session_end; cleanup 0
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
#  Run Pre Move Script
# ==========================================================
if [[ "$ENABLE_SCRIPTS" == "yes" && -n "$PRE_SCRIPT" ]]; then
    echo "Running pre-move script: $PRE_SCRIPT" >> "$LAST_RUN_FILE"
    if run_script "$PRE_SCRIPT" >> "$LAST_RUN_FILE" 2>&1; then
        echo "Pre-move script completed successfully" >> "$LAST_RUN_FILE"
    else
        echo "Pre-move script failed" >> "$LAST_RUN_FILE"
    fi
fi

# ==========================================================
#  Log which filters are enabled
# ==========================================================
skipped_hidden=0
skipped_size=0
skipped_age=0
skipped_exclusions=0

if [[ "$MOVE_NOW" == false ]]; then
  filters_active=false
  if [[ "$HIDDEN_FILTER" == "yes" || "$SIZE_BASED_FILTER" == "yes" || \
        "$AGE_BASED_FILTER" == "yes" || "$EXCLUSIONS_ENABLED" == "yes" ]]; then
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
#  Copy empty directories
# ==========================================================
copy_empty_dirs() {
    local SRC="$1"
    local DEST="$2"
    [[ ! -d "$SRC" ]] && return
    SRC="${SRC%/}"
    sharename=$(basename "$SRC")
    find "$SRC" -type d | while read -r dir; do
        [[ "$dir" == "$SRC" ]] && continue
        if [[ "$(basename "$dir")" == "$sharename" && "$dir" == "$SRC" ]]; then
            continue
        fi
        dst_dir="$DEST/${dir#$SRC/}"
        skip_dir=false
        if [[ "$EXCLUSIONS_ENABLED" == "yes" && ${#EXCLUDED_PATHS[@]} -gt 0 ]]; then
            for ex in "${EXCLUDED_PATHS[@]}"; do
                [[ -d "$ex" && "$ex" != */ ]] && ex="$ex/"
                dir_check="$dir/"
                if [[ "$dir_check" == "$ex"* ]]; then
                    skip_dir=true
                    break
                fi
            done
        fi
        $skip_dir && continue
        if [[ -z "$(ls -A "$dir")" ]]; then
            mkdir -p "$dst_dir"
            chown "$src_owner:$src_group" "$dst_dir"
            chmod "$src_perms" "$dst_dir"
            echo "Created empty directory: $dst_dir" >> "$AUTOMOVER_LOG"
        fi
    done
}

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

# ==========================================================
#  Collect ALL files (no filters applied yet)
# ==========================================================
mapfile -t all_filtered_items < <(cd "$src" && find . -type f -printf '%P\n' | LC_ALL=C sort)

eligible_items=()
for relpath in "${all_filtered_items[@]}"; do
  [[ -z "$relpath" ]] && continue
  srcfile="$src/$relpath"

  #
  # ===========================
  # Hidden Filter
  # ===========================
  #
  if [[ "$HIDDEN_FILTER" == "yes" && "$(basename "$srcfile")" == .* ]]; then
    ((skipped_hidden++))
    continue
  fi

  #
  # ===========================
  # Size Filter
  # ===========================
  #
  if [[ "$SIZE_FILTER_ENABLED" == true ]]; then
    threshold_bytes=$(( SIZE_MB * 1024 * 1024 ))
    filesize=$(stat -c%s "$srcfile")
    if (( filesize < threshold_bytes )); then
      ((skipped_size++))
      continue
    fi
  fi

  #
  # ===========================
  # Age Filter
  # ===========================
  #
  if [[ "$AGE_FILTER_ENABLED" == true ]]; then
    file_mtime_days=$(( ( $(date +%s) - $(stat -c %Y "$srcfile") ) / 86400 ))
    if (( file_mtime_days < AGE_DAYS )); then
      ((skipped_age++))
      continue
    fi
  fi

  #
  # ===========================
  # Exclusions
  # ===========================
  #
  skip_file=false
  if [[ "$EXCLUSIONS_ENABLED" == "yes" && ${#EXCLUDED_PATHS[@]} -gt 0 ]]; then
    for ex in "${EXCLUDED_PATHS[@]}"; do
      [[ -d "$ex" ]] && ex="${ex%/}/"
      if [[ "$srcfile" == "$ex"* ]]; then
        skip_file=true
        break
      fi
    done
  fi

  if [[ "$skip_file" == true ]]; then
    ((skipped_exclusions++))
    continue
  fi

  #
  # ===========================
  # In-use File Check
  # ===========================
  #
  if fuser "$srcfile" >/dev/null 2>&1; then
    grep -qxF "$srcfile" "$IN_USE_FILE" 2>/dev/null || echo "$srcfile" >> "$IN_USE_FILE"
    continue
  fi

  # Passed all filters → eligible
  eligible_items+=("$relpath")
done

  file_count=${#eligible_items[@]}
  (( file_count == 0 )) && { continue; }
  echo "$src" >> /tmp/automover/temp_logs/cleanup_sources.txt

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

# Detect if qBittorrent script host/port overlaps with a stopped container
skip_qbit_script=false
if [[ -n "$CONTAINER_NAMES" && -n "$QBITTORRENT_HOST" ]]; then
  if [[ "$QBITTORRENT_HOST" == *:* ]]; then
    qbit_port="${QBITTORRENT_HOST##*:}"
  else
    qbit_port=""
  fi

  IFS=',' read -ra CONTAINERS <<< "$CONTAINER_NAMES"
  for container in "${CONTAINERS[@]}"; do
    cname=$(echo "$container" | xargs)
    [[ -z "$cname" ]] && continue

    lcname=$(echo "$cname" | tr '[:upper:]' '[:lower:]')
    if [[ "$lcname" == *qbittorrent* ]]; then
      skip_qbit_script=true
      echo "Qbittorrent container is in stop containers list — skipping qbittorrent pause/resume" >> "$LAST_RUN_FILE"
      break
    fi

    if [[ -n "$qbit_port" ]]; then
      ports=$(docker inspect --format='{{range $p, $conf := .HostConfig.PortBindings}}{{(index $conf 0).HostPort}} {{end}}' "$cname" 2>/dev/null)
      for port in $ports; do
        if [[ "$port" == "$qbit_port" ]]; then
          skip_qbit_script=true
          echo "Qbittorrent container is in stop containers list — skipping qbittorrent pause/resume" >> "$LAST_RUN_FILE"
          break 2
        fi
      done
    fi
  done

  # --- Extra check: dynamic parent + PID mapping ---
  if [[ "$skip_qbit_script" == false && -n "$qbit_port" ]]; then
    parents=()
    for cid in $(docker ps -q); do
      netmode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$cid")
      if [[ "$netmode" == container:* ]]; then
        parent=${netmode#container:}
        parents+=("$parent")
      fi
    done
    parents=($(printf "%s\n" "${parents[@]}" | sort -u))

    for parent in "${parents[@]}"; do
      parent_id=$(docker inspect -f '{{.Id}}' "$parent" 2>/dev/null)
      parent_pid=$(docker inspect -f '{{.State.Pid}}' "$parent" 2>/dev/null)
      [[ -z "$parent_pid" || "$parent_pid" == "0" ]] && continue

      listener_pids=$(nsenter -t "$parent_pid" -n ss -ltnp 2>/dev/null \
        | grep ":$qbit_port " | grep -o 'pid=[0-9]\+' | cut -d= -f2 | sort -u)

      if [[ -n "$listener_pids" ]]; then
        for cid in $(docker ps -q); do
          netmode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$cid")
          cname=$(docker inspect -f '{{.Name}}' "$cid" | sed 's#^/##')
          if [[ "$netmode" == "container:$parent" || "$netmode" == "container:$parent_id" ]]; then
            cpids=$(docker top "$cname" -eo pid 2>/dev/null | awk 'NR>1 {print $1}')
            for lp in $listener_pids; do
              if echo "$cpids" | grep -q "^$lp$"; then
                for stopped in "${CONTAINERS[@]}"; do
                  stopped=$(echo "$stopped" | xargs)
                  if [[ "$cname" == "$stopped" ]]; then
                    skip_qbit_script=true
                    echo "Qbittorrent container is in stop containers list — skipping qbittorrent pause/resume" >> "$LAST_RUN_FILE"
                    break 4
                  fi
                done
              fi
            done
          fi
        done
      fi
    done
  fi
fi

    # --- Enable turbo write ---
    if [[ "$FORCE_RECONSTRUCTIVE_WRITE" == "yes" && "$DRY_RUN" != "yes" ]]; then
      set_status "Enabling Turbo Write"
      turbo_write_prev=$(grep -Po 'md_write_method="\K[^"]+' /var/local/emhttp/var.ini 2>/dev/null)
      echo "$turbo_write_prev" > /tmp/prev_write_method
      logger "Force turbo write on"
      /usr/local/sbin/mdcmd set md_write_method 1
      echo "Enabled reconstructive write mode (turbo write)" >> "$LAST_RUN_FILE"
      turbo_write_enabled=true
    fi
    # --- Stop managed containers ---
manage_containers stop

# --- qBittorrent dependency check + pause ---
if [[ "$QBITTORRENT_SCRIPT" == "yes" && "$DRY_RUN" != "yes" && "$skip_qbit_script" == false ]]; then
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

# ensure directory exists
mkdir -p /tmp/automover/temp_logs

# use fixed path instead of mktemp
tmpfile="/tmp/automover/temp_logs/eligible_files.txt"

# write eligible items into the file
printf '%s\n' "${eligible_items[@]}" > "$tmpfile"

file_count_moved=0
src_owner=$(stat -c "%u" "$src")
src_group=$(stat -c "%g" "$src")
src_perms=$(stat -c "%a" "$src")

# Ensure destination root exists with correct ownership/permissions
if [[ ! -d "$dst" ]]; then
  mkdir -p "$dst"
fi
chown "$src_owner:$src_group" "$dst"
chmod "$src_perms" "$dst"

copy_empty_dirs "$src" "$dst"
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
 
# -------------------------------
# Stop threshold check BEFORE move
# -------------------------------
if [[ "$MOVE_NOW" == false && "$DRY_RUN" != "yes" && "$STOP_THRESHOLD" -gt 0 ]]; then
  FINAL_USED=$(df --output=pcent "$MOUNT_POINT" | awk 'NR==2 {gsub("%",""); print}')
  if [[ -n "$FINAL_USED" && "$FINAL_USED" -le "$STOP_THRESHOLD" ]]; then
    echo "Move stopped — pool usage reached stop threshold: ${FINAL_USED}% (<= ${STOP_THRESHOLD}%)" >> "$LAST_RUN_FILE"
    STOP_TRIGGERED=true
    break
  fi
fi

# --- NOW do the move ---
"${RSYNC_WRAPPER[@]}" rsync "${RSYNC_OPTS[@]}" "$srcfile" "$dstdir/" 2>&1 \
  | awk '
      /MB\/s/ {
        for (i=1;i<=NF;i++) {
          if ($i ~ /MB\/s/) {
            gsub(/MB\/s/, "", $i)
            print $i
            fflush()
          }
        }
      }
    ' >> "$RSYNC_SPEED_FILE"
sync
sleep 1

if [[ "$DRY_RUN" == "yes" ]]; then
  # Log what WOULD be moved
  echo "$srcfile -> $dstfile" >> "$AUTOMOVER_LOG"
else
  # Real move
  if [[ -f "$dstfile" ]]; then
    ((file_count_moved++))
    echo "$srcfile -> $dstfile" >> "$AUTOMOVER_LOG"
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
#  Print skip totals
# ==========================================================
{
  if [[ "$HIDDEN_FILTER" == "yes" ]]; then
    echo "Skipped due to hidden filter: $skipped_hidden file(s)"
  fi
  if [[ "$SIZE_BASED_FILTER" == "yes" ]]; then
    echo "Skipped due to size filter: $skipped_size file(s)"
  fi
  if [[ "$AGE_BASED_FILTER" == "yes" ]]; then
    echo "Skipped due to age filter: $skipped_age file(s)"
  fi
  if [[ "$EXCLUSIONS_ENABLED" == "yes" ]]; then
    echo "Skipped due to exclusions: $skipped_exclusions file(s)"
  fi
} >> "$LAST_RUN_FILE"

# ==========================================================
#  No shares had any eligible files
# ==========================================================
if [[ "$pre_move_done" != "yes" && "$moved_anything" == false ]]; then
  echo "No shares had files to move" >> "$LAST_RUN_FILE"
fi

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
if [[ "$qbit_paused" == true && "$QBITTORRENT_SCRIPT" == "yes" && "$skip_qbit_script" == false ]]; then
  set_status "Resuming Torrents"
  run_qbit_script resume
fi

# ==========================================================
#  Start managed containers
# ==========================================================
manage_containers start

# ==========================================================
#  Finished move process
# ==========================================================
if [[ "$DRY_RUN" != "yes" ]]; then
  echo "Finished move process" >> "$LAST_RUN_FILE"
fi

# ==========================================================
#  Cleanup Empty Folders (including ZFS datasets) - ONLY moved sources
# ==========================================================
if [[ "$ENABLE_CLEANUP" == "yes" ]]; then
  set_status "Cleaning Up"
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "Dry run active — skipping cleanup of empty folders/datasets" >> "$LAST_RUN_FILE"
  elif [[ "$moved_anything" == true ]]; then
    if [[ ! -s /tmp/automover/temp_logs/cleanup_sources.txt ]]; then
      echo "No files moved — skipping cleanup of empty folders/datasets" >> "$LAST_RUN_FILE"
    else
      while IFS= read -r src_path; do
        [[ -z "$src_path" || ! -d "$src_path" ]] && continue
        share_name=$(basename "$src_path")

        # force exclude these 4
        case "$share_name" in
          appdata|system|domains|isos)
            echo "Skipping cleanup for excluded share: $share_name" >> "$LAST_RUN_FILE"
            continue
            ;;
        esac

        # -------------------------------
        # Remove dirs bottom‑up, skip exclusions
        # -------------------------------
        find "$src_path" -depth -type d | while read -r dir; do
          if [[ "$dir" == "$src_path" ]]; then
            # Root folder: remove only if another instance exists elsewhere
            other_exists=false
            for mp in /mnt/*; do
              [[ ! -d "$mp" ]] && continue
              [[ "$mp/$share_name" == "$src_path" ]] && continue
              if [[ -d "$mp/$share_name" ]]; then
                other_exists=true; break
              fi
            done
            [[ "$other_exists" == false ]] && continue
          fi

          # Skip exclusions
          skip_dir=false
          if [[ "$EXCLUSIONS_ENABLED" == "yes" && ${#EXCLUDED_PATHS[@]} -gt 0 ]]; then
            for ex in "${EXCLUDED_PATHS[@]}"; do
              [[ -d "$ex" && "$ex" != */ ]] && ex="$ex/"
              dir_check="$dir/"
              if [[ "$dir_check" == "$ex"* ]]; then
                skip_dir=true; break
              fi
            done
          fi
          $skip_dir && continue

          rmdir "$dir" 2>/dev/null
        done

        # -------------------------------
        # ZFS datasets cleanup, skip exclusions
        # -------------------------------
        if command -v zfs >/dev/null 2>&1; then
          mapfile -t datasets < <(zfs list -H -o name,mountpoint | awk -v mp="$src_path" '$2 ~ "^"mp {print $1}')
          for ds in "${datasets[@]}"; do
            mountpoint=$(zfs get -H -o value mountpoint "$ds" 2>/dev/null)
            skip_ds=false
            if [[ "$EXCLUSIONS_ENABLED" == "yes" && ${#EXCLUDED_PATHS[@]} -gt 0 ]]; then
              for ex in "${EXCLUDED_PATHS[@]}"; do
                [[ -d "$ex" && "$ex" != */ ]] && ex="$ex/"
                mount_check="$mountpoint/"
                if [[ "$mount_check" == "$ex"* ]]; then
                  skip_ds=true; break
                fi
              done
            fi
            $skip_ds && continue
            if [[ -d "$mountpoint" && -z "$(ls -A "$mountpoint" 2>/dev/null)" ]]; then
              zfs destroy -f "$ds" >/dev/null 2>&1
            fi
          done
        fi

      done < <(sort -u /tmp/automover/temp_logs/cleanup_sources.txt)
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
  mkdir -p /tmp/automover/temp_logs
  if command -v jdupes >/dev/null 2>&1; then
    TEMP_LIST="/tmp/automover/temp_logs/jdupes_list.txt"
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

# Add dry run notification for skipping notifications
if [[ "$DRY_RUN" == "yes" ]]; then
  echo "Dry run active — skipping sending notifications" >> "$LAST_RUN_FILE"
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

# ==========================================================
# Final automover_log handling with proper DRY RUN behavior
# ==========================================================

if [[ "$DRY_RUN" == "yes" ]]; then
  :
else
  if [[ "$moved_anything" == "true" && -s "$AUTOMOVER_LOG" ]]; then
    cp -f "$AUTOMOVER_LOG" "${AUTOMOVER_LOG%/*}/files_moved_prev.log"
  else
    : > "$AUTOMOVER_LOG"
    echo "No files moved for this run" >> "$AUTOMOVER_LOG"
  fi
fi

# ==========================================================
#  Post-move share existence check and config cleanup
# ==========================================================
if [[ "$moved_anything" == true && "$ENABLE_CLEANUP" == "yes" ]]; then
  set_status "Checking Share Existence"

  while IFS= read -r share_name; do
    [[ -z "$share_name" ]] && continue
    cfg="/boot/config/shares/${share_name}.cfg"

    [[ -f "$cfg" ]] || continue

    found=false
    for mount in /mnt/*; do
      [[ -d "$mount/$share_name" ]] && { found=true; break; }
    done

    if [[ "$found" == false ]]; then
      rm -f "$cfg"
    fi
  done < "$MOVED_SHARES_FILE"
fi

# ==========================================================
#  SSD Trim
# ==========================================================
if [[ "$ENABLE_TRIM" == "yes" && "$DRY_RUN" != "yes" && "$moved_anything" == true ]]; then
    set_status "Running ssd trim"

    # Execute TRIM using php wrapper
    /usr/local/emhttp/plugins/dynamix/scripts/ssd_trim cron >/dev/null 2>&1
    exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        echo "Ssd trim finished" >> "$LAST_RUN_FILE"
    else
        echo "Ssd trim failed" >> "$LAST_RUN_FILE"
    fi

elif [[ "$ENABLE_TRIM" == "yes" && "$DRY_RUN" == "yes" ]]; then
    echo "Dry run active — skipping ssd trim" >> "$LAST_RUN_FILE"
fi

# ==========================================================
#  Finish and signal
# ==========================================================
send_summary_notification

# ==========================================================
#  Run Post Move Script
# ==========================================================
if [[ "$ENABLE_SCRIPTS" == "yes" && -n "$POST_SCRIPT" ]]; then
    echo "Running post-move script: $POST_SCRIPT" >> "$LAST_RUN_FILE"
    if run_script "$POST_SCRIPT" >> "$LAST_RUN_FILE" 2>&1; then
        echo "Post-move script completed successfully" >> "$LAST_RUN_FILE"
    else
        echo "Post-move script failed" >> "$LAST_RUN_FILE"
    fi
fi

log_session_end
mkdir -p /tmp/automover/temp_logs
echo "done" > /tmp/automover/temp_logs/done.txt

# Reset status and release lock
set_status "$PREV_STATUS"
rm -f "$LOCK_FILE"

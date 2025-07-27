#!/bin/bash

LAST_RUN_FILE="/var/log/automover_last_run.log"
CFG_PATH="/boot/config/plugins/automover/settings.cfg"
TMP_LOG="/tmp/automover_trimmed.log"

# Rotate logs if over 10MB
rotate_logs() {
  local log="$1"
  local max_size=$((10 * 1024 * 1024))  # 10MB

  if [[ -f "$log" && $(stat -c%s "$log") -ge $max_size ]]; then
    [[ -f "${log}.3" ]] && rm -f "${log}.3"
    [[ -f "${log}.2" ]] && mv "${log}.2" "${log}.3"
    [[ -f "${log}.1" ]] && mv "${log}.1" "${log}.2"
    mv "$log" "${log}.1"
    > "$log"
  fi
}

rotate_logs "$LAST_RUN_FILE"

# Load settings
if [[ -f "$CFG_PATH" ]]; then
  source "$CFG_PATH"
else
  echo "Config file not found: $CFG_PATH" >> "$LAST_RUN_FILE"
  exit 1
fi

MOUNT_POINT="/mnt/${POOL_NAME}"

# Log header
echo "------------------------------------------------" >> "$LAST_RUN_FILE"
echo "Automover session started - $(date '+%Y-%m-%d %H:%M:%S')" >> "$LAST_RUN_FILE"

# Parity check block
if [[ "$ALLOW_DURING_PARITY_CHECK" == "no" ]]; then
  if grep -Eq 'mdResync="([1-9][0-9]*)"' /var/local/emhttp/var.ini 2>/dev/null; then
    echo "Parity check in progress. Skipping this run." >> "$LAST_RUN_FILE"
    exit 0
  fi
fi

# Check if mover is already running
if pgrep -x mover &>/dev/null; then
  echo "Mover already running — skipping this check" >> "$LAST_RUN_FILE"
  exit 0
fi

# Disk usage check
USED=$(df -h --output=pcent "$MOUNT_POINT" | awk 'NR==2 {gsub("%",""); print}')
if [[ -z "$USED" ]]; then
  echo "Could not retrieve usage for $MOUNT_POINT" >> "$LAST_RUN_FILE"
  exit 1
fi

echo "$POOL_NAME usage: ${USED}% (Threshold: $THRESHOLD%)" >> "$LAST_RUN_FILE"

# Threshold logic
if [[ "$USED" -gt "$THRESHOLD" ]]; then
  echo "Usage exceeds threshold!" >> "$LAST_RUN_FILE"

  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "Dry Run enabled — not starting mover" >> "$LAST_RUN_FILE"
  else
    echo "Starting mover" >> "$LAST_RUN_FILE"
    /usr/local/emhttp/plugins/automover/helpers/mover_wrapper.sh
    echo "Mover finished" >> "$LAST_RUN_FILE"
  fi
else
  echo "Usage below threshold — nothing to do" >> "$LAST_RUN_FILE"
fi

echo "Automover session finished - $(date '+%Y-%m-%d %H:%M:%S')" >> "$LAST_RUN_FILE"
printf "\n" >> "$LAST_RUN_FILE"

# Trim to last 20 full sessions
awk '
  /Automover session started -/ {
    start = NR
    # Look backward for separator
    for (i = NR - 1; i > 0; i--) {
      if (lines[i] ~ /^-+$/) { start = i; break }
    }
  }
  /Automover session finished -/ {
    end = NR
    sessions[++count] = start "," end
  }
  {lines[NR] = $0}
  END {
    for (i = count - 19 > 0 ? count - 19 : 1; i <= count; i++) {
      split(sessions[i], range, ",")
      for (j = range[1]; j <= range[2]; j++) {
        print lines[j]
      }
      print ""  # Preserve blank line after each session
    }
  }
' "$LAST_RUN_FILE" > "$TMP_LOG"

mv "$TMP_LOG" "$LAST_RUN_FILE"
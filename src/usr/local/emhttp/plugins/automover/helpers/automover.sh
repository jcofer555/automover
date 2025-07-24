#!/bin/bash

LAST_RUN_FILE="/var/log/automover_last_run.log"
CFG_PATH="/boot/config/plugins/automover/settings.cfg"

# Load settings
if [[ -f "$CFG_PATH" ]]; then
  source "$CFG_PATH"
else
  echo "❌ Config file not found: $CFG_PATH" >> "$LAST_RUN_FILE"
  exit 1
fi

MOUNT_POINT="/mnt/${POOL_NAME}"

# Header + last run marker
{
  echo "Automover session started - $(date '+%Y-%m-%d %H:%M:%S')"
} >> "$LAST_RUN_FILE"

# Check if parity check is running — only block if allow_during_parity is "no"
if [[ "$ALLOW_DURING_PARITY_CHECK" == "no" ]]; then
  if grep -Eq 'mdResync="([1-9][0-9]*)"' /var/local/emhttp/var.ini 2>/dev/null; then
    echo "⚠️ Parity check in progress. Skipping this run. If you want to allow moving while parity check is running set allow during parity check to yes" >> "$LAST_RUN_FILE"
    exit 0
  fi
fi

# Check if mover is already running
if pgrep -x mover &>/dev/null; then
  echo "⏳ Mover already running — skipping this check" >> "$LAST_RUN_FILE"
  exit 0
fi

# Disk usage check
USED=$(df -h --output=pcent "$MOUNT_POINT" | awk 'NR==2 {gsub("%",""); print}')
if [ -z "$USED" ]; then
  echo "❌ Could not retrieve usage for $MOUNT_POINT" >> "$LAST_RUN_FILE"
  exit 1
fi

echo "📊 $POOL_NAME usage: ${USED}% (Threshold: $THRESHOLD%)" >> "$LAST_RUN_FILE"

# Threshold logic
if [ "$USED" -gt "$THRESHOLD" ]; then
  echo "⚠️ Usage exceeds threshold!" >> "$LAST_RUN_FILE"

  if [ "$DRY_RUN" == "yes" ]; then
    echo "🔧 Dry Run enabled — not starting mover" >> "$LAST_RUN_FILE"
  else
    echo "🛠️ Starting mover" >> "$LAST_RUN_FILE"
    /usr/local/emhttp/plugins/automover/helpers/mover_wrapper.sh
  fi
  if [ "$DRY_RUN" == "yes" ]; then
    echo
  else
   echo "🛠️ Mover Finshed" >> "$LAST_RUN_FILE"
  fi
else
  echo "✅ Usage below threshold — nothing to do" >> "$LAST_RUN_FILE"
fi
echo "Automover session finished - $(date '+%Y-%m-%d %H:%M:%S')" >> "$LAST_RUN_FILE"
printf "\n" >> "$LAST_RUN_FILE"

# 🔄 Trim log to last 10 days
TMP_LOG="/tmp/automover_trimmed.log"
now=$(date +%s)

grep -E '^Automover session started - [0-9]{4}-[0-9]{2}-[0-9]{2}' "$LAST_RUN_FILE" | while read -r line; do
  timestamp=$(echo "$line" | cut -d '-' -f2- | xargs -I{} date -d "{}" +%s)
  age=$(( (now - timestamp) / 86400 ))
  if (( age <= 9 )); then
    match_time=$(echo "$line" | cut -d'-' -f2-)
    sed -n "/$match_time/,/^Automover session finished -/p" "$LAST_RUN_FILE" >> "$TMP_LOG"
  fi
done

mv "$TMP_LOG" "$LAST_RUN_FILE"

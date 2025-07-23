#!/bin/bash

CONFIG="/boot/config/plugins/automover/settings.cfg"
PIDFILE="/var/run/automover.pid"
LAST_RUN_FILE="/var/log/automover_last_run.log"

# Trap cleanup on exit
cleanup() {
  echo "🛑 Caught termination signal — cleaning up"
  rm -f "$PIDFILE"
  exit 0
}

trap cleanup SIGINT SIGTERM

# Exit if already running
if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE")
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "❌ Already running with PID $OLD_PID"
    exit 1
  else
    echo "⚠️ Stale PID found — continuing"
    rm -f "$PIDFILE"
  fi
fi

echo $$ > "$PIDFILE"

# Load settings
if [ -f "$CONFIG" ]; then
  source "$CONFIG"
else
  echo "❌ Config file not found: $CONFIG"
  rm -f "$PIDFILE"
  exit 1
fi

MOUNT_POINT="/mnt/${POOL_NAME}"

echo "🔁 Automover loop started for $POOL_NAME (Threshold=${THRESHOLD}%, Interval=${INTERVAL}s, DryRun=$DRY_RUN"

while true; do
{
  # Update last run timestamp
  date '+%Y-%m-%d %H:%M:%S' > "$LAST_RUN_FILE"

# Define parity completion handler
check_parity_done() {
    while grep -Eq 'mdResync="([1-9][0-9]*)"' /var/local/emhttp/var.ini 2>/dev/null; do
        sleep 10
    done

    echo "✅ Parity done. Restarting Automover..." >> /var/log/automover_run_details.log

    rm -f /var/run/automover.pid

    # Relaunch the script (adjust the path if needed)
    /usr/bin/automover.sh &
}

# Main logic
if grep -Eq 'mdResync="([1-9][0-9]*)"' /var/local/emhttp/var.ini 2>/dev/null; then
    echo "⚠️ Parity check in progress. Delaying Automover..." >> /var/log/automover_run_details.log
    check_parity_done &
    exit 0
fi

  # Wait if mover is already running
  if pgrep -x mover &>/dev/null; then
    echo "⏳ Mover already running — skipping this check"
  else
    USED=$(df -h --output=pcent "$MOUNT_POINT" | awk 'NR==2 {gsub("%",""); print}')

    if [ -z "$USED" ]; then
      echo "❌ Could not retrieve usage for $MOUNT_POINT"
    else
      echo "📊 $POOL_NAME usage: ${USED}% (Threshold: $THRESHOLD%) at $(date '+%Y-%m-%d %H:%M:%S')"

      if [ "$USED" -gt "$THRESHOLD" ]; then
        echo "⚠️ Usage exceeds threshold!"

        if [ "$DRY_RUN" == "yes" ]; then
          echo "🔧 Dry Run enabled — not starting mover"
        else
          echo "🛠️ Starting mover..."
          mover start
        fi
      else
        echo "✅ Usage below threshold — nothing to do"
      fi
    fi
  fi

} >> "/var/log/automover_run_details.log" 2>&1
  sleep "$INTERVAL"
done

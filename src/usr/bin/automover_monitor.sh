#!/bin/bash

CONFIG="/boot/config/plugins/automover/settings.cfg"
TRIGGER_LOG="/boot/config/plugins/automover/last_triggered.log"
PIDFILE="/var/run/automover_monitor.pid"

# Check for existing process
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "🛑 Automover already running with PID $(cat "$PIDFILE")"
  exit 1
fi

# Save our PID
echo $$ > "$PIDFILE"

# Cleanup PID on exit
trap "rm -f $PIDFILE" EXIT

# Load settings
source "$CONFIG" 2>/dev/null
POOL_NAME="${POOL_NAME:-cache}"
THRESHOLD="${THRESHOLD:-90}"
DRY_RUN="${DRY_RUN:-no}"
LOOP_INTERVAL="${LOOP_INTERVAL:-300}"

MOUNT="/mnt/${POOL_NAME}"

while true; do
  echo "📦 Checking usage of pool '$POOL_NAME'..."

  if [ ! -d "$MOUNT" ]; then
    echo "❌ Mount point '$MOUNT' not found"
    sleep "$LOOP_INTERVAL"
    continue
  fi

  if pgrep -x mover &>/dev/null; then
    echo "⏳ Mover already running — sleeping 15s"
    sleep 15
    if pgrep -x mover &>/dev/null; then
      echo "❌ Still running — skipping trigger"
      sleep "$LOOP_INTERVAL"
      continue
    fi
  fi

  USED=$(df -h --si "$MOUNT" | awk 'NR==2 {print $5}' | sed 's/%//')
  if [ -z "$USED" ]; then
    echo "⚠️ Unable to detect usage for $POOL_NAME"
    sleep "$LOOP_INTERVAL"
    continue
  fi

  echo "📊 Current usage: ${USED}% (threshold: ${THRESHOLD}%)"

  if [ "$USED" -gt "$THRESHOLD" ]; then
    if [ "$DRY_RUN" = "yes" ]; then
      echo "🧪 Dry run: Mover would be triggered"
    else
      echo "🚀 Starting mover"
      mover start
      date +"%Y-%m-%d %H:%M:%S" > "$TRIGGER_LOG"
      echo "✅ Triggered at $(cat "$TRIGGER_LOG")"
    fi
  else
    echo "🟢 Pool usage is below threshold"
  fi

  echo "⏱️ Sleeping ${LOOP_INTERVAL}s..."
  sleep "$LOOP_INTERVAL"
done

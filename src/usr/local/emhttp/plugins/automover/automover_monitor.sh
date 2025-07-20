#!/bin/bash

CONFIG="/boot/config/plugins/automover/settings.cfg"
TRIGGER_LOG="/boot/config/plugins/automover/last_triggered.log"

source "$CONFIG" 2>/dev/null

POOL_NAME="${POOL_NAME:-cache}"
THRESHOLD="${THRESHOLD:-90}"
DRY_RUN="${DRY_RUN:-no}"
LOOP_INTERVAL="${LOOP_INTERVAL:-300}"

MOUNT_POINT="/mnt/${POOL_NAME}"

while true; do
  echo "📦 Checking pool: $POOL_NAME (${THRESHOLD}%)"
  
  if pgrep -x mover &>/dev/null; then
    echo "⏳ Mover already running. Sleeping 15s..."
    sleep 15
    pgrep -x mover &>/dev/null && {
      echo "❌ Still running after 15s — skipping"
      sleep "$LOOP_INTERVAL"
      continue
    }
  fi

  USED=$(df -h --si "$MOUNT_POINT" | awk 'NR==2 {print $5}' | sed 's/%//')

  if [ -z "$USED" ]; then
    echo "❌ Usage unavailable — skipping"
    sleep "$LOOP_INTERVAL"
    continue
  fi

  echo "📊 Usage: ${USED}%"

  if [ "$USED" -le "$THRESHOLD" ]; then
    echo "🟢 Under threshold — skipping mover"
  else
    echo "🚨 Over threshold! Triggering mover..."

    if [ "$DRY_RUN" = "yes" ]; then
      echo "🧪 Dry run enabled — not starting mover"
    else
      mover start
      date +"%Y-%m-%d %H:%M:%S" > "$TRIGGER_LOG"
      echo "✅ Mover started"
    fi
  fi

  echo "⏱️ Sleeping ${LOOP_INTERVAL}s..."
  sleep "$LOOP_INTERVAL"
done

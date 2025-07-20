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
  if pgrep -x mover &>/dev/null; then
    sleep 15
    pgrep -x mover &>/dev/null && sleep "$LOOP_INTERVAL" && continue
  fi

  USED=$(df -h --si "$MOUNT_POINT" | awk 'NR==2 {print $5}' | sed 's/%//')

  if [ -z "$USED" ]; then sleep "$LOOP_INTERVAL"; continue; fi
  if [ "$USED" -gt "$THRESHOLD" ]; then
    if [ "$DRY_RUN" != "yes" ]; then
      mover start
      date +"%Y-%m-%d %H:%M:%S" > "$TRIGGER_LOG"
    fi
  fi

  sleep "$LOOP_INTERVAL"
done

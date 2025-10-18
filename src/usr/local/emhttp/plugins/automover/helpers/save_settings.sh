#!/bin/bash

CONFIG="/boot/config/plugins/automover/settings.cfg"
mkdir -p "$(dirname "$CONFIG")"

# Safely assign defaults if missing
POOL_NAME="${1:-cache}"
THRESHOLD="${2:-0}"
INTERVAL="${3:-60}"
DRY_RUN="${4:-no}"
ALLOW_DURING_PARITY_CHECK="${5:-no}"
AUTOSTART="${6:-no}"
DISABLE_UNRAID_MOVER_SCHEDULE="${7:-no}"
AGE_BASED_FILTER="${8:-no}"
AGE_DAYS="${9:-1}"
SIZE_BASED_FILTER="${10:-no}"
SIZE_MB="${11:-1}"

# Write all settings cleanly and atomically
{
  echo "POOL_NAME=\"$POOL_NAME\""
  echo "THRESHOLD=\"$THRESHOLD\""
  echo "INTERVAL=\"$INTERVAL\""
  echo "DRY_RUN=\"$DRY_RUN\""
  echo "ALLOW_DURING_PARITY_CHECK=\"$ALLOW_DURING_PARITY_CHECK\""
  echo "AUTOSTART=\"$AUTOSTART\""
  echo "DISABLE_UNRAID_MOVER_SCHEDULE=\"$DISABLE_UNRAID_MOVER_SCHEDULE\""
  echo "AGE_BASED_FILTER=\"$AGE_BASED_FILTER\""
  echo "AGE_DAYS=\"$AGE_DAYS\""
  echo "SIZE_BASED_FILTER=\"$SIZE_BASED_FILTER\""
  echo "SIZE_MB=\"$SIZE_MB\""
} > "$CONFIG"

echo '{"status":"ok"}'
exit 0

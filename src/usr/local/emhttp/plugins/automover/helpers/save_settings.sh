#!/bin/bash

CONFIG="/boot/config/plugins/automover/settings.cfg"
mkdir -p "$(dirname "$CONFIG")"

# Safely assign defaults if missing
POOL_NAME="${1:-cache}"
THRESHOLD="${2:-0}"
INTERVAL="${3:-60}"
DRY_RUN="${4:-no}"
ALLOW_DURING_PARITY="${5:-no}"
AUTOSTART="${6:-no}"
AGE_BASED_FILTER="${7:-no}"
AGE_DAYS="${8:-1}"
SIZE_BASED_FILTER="${9:-no}"
SIZE_MB="${10:-1}"
EXCLUSIONS_ENABLED="${11:-no}"

# Write all settings cleanly and atomically
{
  echo "POOL_NAME=\"$POOL_NAME\""
  echo "THRESHOLD=\"$THRESHOLD\""
  echo "INTERVAL=\"$INTERVAL\""
  echo "DRY_RUN=\"$DRY_RUN\""
  echo "ALLOW_DURING_PARITY=\"$ALLOW_DURING_PARITY\""
  echo "AUTOSTART=\"$AUTOSTART\""
  echo "AGE_BASED_FILTER=\"$AGE_BASED_FILTER\""
  echo "AGE_DAYS=\"$AGE_DAYS\""
  echo "SIZE_BASED_FILTER=\"$SIZE_BASED_FILTER\""
  echo "SIZE_MB=\"$SIZE_MB\""
  echo "EXCLUSIONS_ENABLED=\"$EXCLUSIONS_ENABLED\""
} > "$CONFIG"

echo '{"status":"ok"}'
exit 0

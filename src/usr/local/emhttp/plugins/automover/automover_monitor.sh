#!/bin/bash

LOG_PATH="/var/log/automover.log"
PYTHON_SCRIPT="/usr/local/bin/automover_monitor.py"

if ! command -v python3 &> /dev/null; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - ❌ Python3 is not installed. Please install it via Unraid apps page" >> "$LOG_PATH"
  exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - ✅ Running Python monitor..." >> "$LOG_PATH"
/usr/bin/python3 "$PYTHON_SCRIPT" >> "$LOG_PATH" 2>&1

#!/bin/bash

CONFIG="/boot/config/plugins/automover/settings.cfg"
mkdir -p "$(dirname "$CONFIG")"

echo "POOL_NAME=\"$1\"" > "$CONFIG"
echo "THRESHOLD=\"$2\"" >> "$CONFIG"
echo "INTERVAL=\"$3\"" >> "$CONFIG"
echo "DRY_RUN=\"$4\"" >> "$CONFIG"
echo "ALLOW_DURING_PARITY_CHECK=\"$5\"" >> "$CONFIG"
echo "AUTOSTART=\"$6\"" >> "$CONFIG"

echo '{"status":"ok"}'

#!/bin/bash

CONFIG="/boot/config/plugins/automover/settings.cfg"
mkdir -p "$(dirname "$CONFIG")"

echo "pool=\"$1\"" > "$CONFIG"
echo "threshold=\"$2\"" >> "$CONFIG"
echo "interval=\"$3\"" >> "$CONFIG"
echo "dry_run=\"$4\"" >> "$CONFIG"
echo "allow_during_parity=\"$5\"" >> "$CONFIG"
echo "autostart=\"$6\"" >> "$CONFIG"

echo '{"status":"ok"}'

#!/bin/bash
logger "🔄 Automover Wrapper: Starting mover"
rm -f /var/log/mover_debug.log
/usr/local/sbin/mover start | tee -a /var/log/automover_files_moved.log
logger "✅ Automover Wrapper: Mover finished"

#!/bin/bash
logger "🔄 Automover Wrapper: Starting mover"
rm -f /var/log/mover_debug.log
/usr/local/sbin/mover start | tee -a /var/log/mover_debug.log
logger "✅ Automover Wrapper: Mover finished"

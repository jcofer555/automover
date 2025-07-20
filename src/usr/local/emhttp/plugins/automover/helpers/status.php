<?php
$pidFile = "/var/run/automover.pid";

if (file_exists($pidFile)) {
    $pid = trim(file_get_contents($pidFile));
    if (is_numeric($pid) && file_exists("/proc/$pid")) {
        echo "🟢 Running";
    } else {
        echo "⚠️ Stale PID";
    }
} else {
    echo "⚪ Not Running";
}

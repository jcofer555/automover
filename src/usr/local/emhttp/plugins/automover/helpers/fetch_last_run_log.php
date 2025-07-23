<?php
$logPath = '/var/log/automover_last_run.log';
header('Content-Type: text/plain');

if (!file_exists($logPath)) {
    echo "Last run log not found.";
    exit;
}

$lines = file($logPath, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);

// ✂️ Grab only the last 100 lines
$tail = array_slice($lines, -24);

echo implode("\n", $tail);

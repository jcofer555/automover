<?php
$logPath = '/tmp/automover/last_run.log';
header('Content-Type: text/plain');

if (!file_exists($logPath)) {
    echo "Last run log not found.";
    exit;
}

// 📚 Read full log into array, clean empty lines
$lines = file($logPath, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);

// ✂️ Get last 500 entries
$tail = array_slice($lines, -500);

// 🔄 Show newest at the top
$reversed = array_reverse($tail);

// 🖨️ Display
echo implode("\n", $reversed);

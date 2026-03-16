<?php
$debug   = ($_GET['debug'] ?? '0') === '1';
$logPath = $debug
    ? '/tmp/automover/automover-debug.log'
    : '/tmp/automover/last_run.log';

header('Content-Type: text/plain');

if (!file_exists($logPath)) {
    echo $debug ? 'Debug log not found.' : 'Last run log not found.';
    exit;
}

$lines = file($logPath, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
$tail  = array_slice($lines, -500);

echo implode("\n", $tail);
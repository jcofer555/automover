<?php
header('Content-Type: application/json');

// No CSRF validation needed — these helpers are protected by Unraid's own
// nginx authentication layer. All other automover helpers follow the same pattern.

$log   = $_POST['log']   ?? '';
$debug = ($_POST['debug'] ?? '0') === '1';

$files = [
    'mover' => '/tmp/automover/files_moved.log',
    'last'  => $debug
        ? '/tmp/automover/automover-debug.log'
        : '/tmp/automover/last_run.log',
];

if (!isset($files[$log])) {
    echo json_encode(['ok' => false, 'message' => 'Invalid log target']);
    exit;
}

$file = $files[$log];

if (!file_exists($file)) {
    echo json_encode(['ok' => false, 'message' => 'Log file not found.']);
    exit;
}

file_put_contents($file, '');

echo json_encode([
    'ok'      => true,
    'message' => '✅ ' . ucfirst($log) . ' log cleared successfully.',
]);
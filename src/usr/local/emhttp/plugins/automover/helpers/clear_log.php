<?php
header('Content-Type: application/json');

$csrfHeader  = $_SERVER['HTTP_X_CSRF_TOKEN'] ?? '';
$postToken   = $_POST['csrf_token'] ?? '';
$cookieToken = $_COOKIE['csrf_token'] ?? '';

if (empty($csrfHeader) && empty($postToken)) {
    http_response_code(403);
    echo json_encode(['ok' => false, 'message' => 'Missing CSRF token']);
    exit;
}

if ($csrfHeader !== $cookieToken && $postToken !== $cookieToken) {
    http_response_code(403);
    echo json_encode(['ok' => false, 'message' => 'Invalid CSRF token']);
    exit;
}

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
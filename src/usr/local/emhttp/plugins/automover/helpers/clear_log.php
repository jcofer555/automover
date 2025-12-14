<?php
header('Content-Type: application/json');

// Accept both header and POST token (like other automover helpers)
$csrfHeader = $_SERVER['HTTP_X_CSRF_TOKEN'] ?? '';
$postToken  = $_POST['csrf_token'] ?? '';
$cookieToken = $_COOKIE['csrf_token'] ?? '';

if (empty($csrfHeader) && empty($postToken)) {
    http_response_code(403);
    echo json_encode(['ok' => false, 'message' => 'Missing CSRF token']);
    exit;
}

// Validate against cookie (Unraid 7.x standard)
if ($csrfHeader !== $cookieToken && $postToken !== $cookieToken) {
    http_response_code(403);
    echo json_encode(['ok' => false, 'message' => 'Invalid CSRF token']);
    exit;
}

$log = $_POST['log'] ?? '';
$files = [
    'mover' => '/tmp/automover/files_moved.log',
    'last'  => '/tmp/automover/last_run.log'
];

if (!isset($files[$log])) {
    echo json_encode(['ok' => false, 'message' => 'Invalid log target']);
    exit;
}

$file = $files[$log];
if (file_exists($file)) {
    file_put_contents($file, '');
    if (file_exists($file)) {
    file_put_contents($file, '');
    echo json_encode([
        'ok' => true,
        'message' => '✅ ' . ucfirst($log) . ' log cleared successfully.'
    ]);
} else {
    echo json_encode([
        'ok' => false,
        'message' => '❌ Log file not found.'
    ]);
}

} else {
    echo json_encode(['ok' => false, 'message' => 'Log file not found.']);
}

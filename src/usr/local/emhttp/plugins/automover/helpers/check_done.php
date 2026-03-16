<?php
declare(strict_types=1);

// ── Constants ─────────────────────────────────────────────────────────────────
const DONE_FILE = '/tmp/automover/temp_logs/done.txt';

// ── Entry point ───────────────────────────────────────────────────────────────
header('Content-Type: application/json');

$done_bool = file_exists(DONE_FILE);

echo json_encode([
    'status'    => 'success',
    'timestamp' => date('Y-m-d H:i:s'),
    'data'      => [
        'done' => $done_bool,
    ],
]);
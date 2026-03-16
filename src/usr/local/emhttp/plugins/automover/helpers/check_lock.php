<?php
declare(strict_types=1);

// ── Constants ─────────────────────────────────────────────────────────────────
const LOCK_FILE = '/tmp/automover/lock.txt';

// ── Entry point ───────────────────────────────────────────────────────────────
header('Content-Type: application/json');

$locked_bool = file_exists(LOCK_FILE);

echo json_encode([
    'status'    => 'success',
    'timestamp' => date('Y-m-d H:i:s'),
    'data'      => [
        'locked' => $locked_bool,
    ],
]);
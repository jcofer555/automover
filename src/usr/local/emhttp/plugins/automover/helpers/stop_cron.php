<?php
declare(strict_types=1);

// ── Constants ─────────────────────────────────────────────────────────────────
const CRON_FILE = '/boot/config/plugins/automover/automover.cron';

// ── Entry point ───────────────────────────────────────────────────────────────
header('Content-Type: application/json');

// ── Core logic ────────────────────────────────────────────────────────────────
if (!file_exists(CRON_FILE)) {
    echo json_encode([
        'status'    => 'success',
        'timestamp' => date('Y-m-d H:i:s'),
        'data'      => [
            'ok'      => true,
            'message' => 'automover was already stopped',
        ],
    ]);
    exit;
}

if (!@unlink(CRON_FILE)) {
    echo json_encode([
        'status'    => 'error',
        'timestamp' => date('Y-m-d H:i:s'),
        'data'      => [
            'ok'      => false,
            'message' => 'Failed to remove cron file',
        ],
    ]);
    exit;
}

exec('update_cron');

// ── Response ──────────────────────────────────────────────────────────────────
echo json_encode([
    'status'    => 'success',
    'timestamp' => date('Y-m-d H:i:s'),
    'data'      => [
        'ok'      => true,
        'message' => 'automover cron stopped',
    ],
]);
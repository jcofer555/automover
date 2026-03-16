<?php
declare(strict_types=1);

// ── Constants ─────────────────────────────────────────────────────────────────
const DISMISSED_FLAG = '/boot/config/plugins/automover/mover_warning_dismissed.txt';

// ── Entry point ───────────────────────────────────────────────────────────────
header('Content-Type: application/json');

$method_str = $_SERVER['REQUEST_METHOD'] ?? '';

// ── GET: check dismissed state ────────────────────────────────────────────────
if ($method_str === 'GET') {
    echo json_encode([
        'status'    => 'success',
        'timestamp' => date('Y-m-d H:i:s'),
        'data'      => [
            'dismissed' => file_exists(DISMISSED_FLAG),
        ],
    ]);
    exit;
}

// ── POST: dismiss warning ─────────────────────────────────────────────────────
if ($method_str === 'POST') {
    file_put_contents(DISMISSED_FLAG, 'dismissed');
    echo json_encode([
        'status'    => 'success',
        'timestamp' => date('Y-m-d H:i:s'),
        'data'      => [
            'ok' => true,
        ],
    ]);
    exit;
}

// ── Invalid method ────────────────────────────────────────────────────────────
http_response_code(405);
echo json_encode(['ok' => false, 'error' => 'Method not allowed']);
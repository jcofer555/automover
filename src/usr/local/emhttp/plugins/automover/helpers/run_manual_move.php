<?php
declare(strict_types=1);

// ── Constants ─────────────────────────────────────────────────────────────────
const AUTOMOVER_SCRIPT = '/usr/local/emhttp/plugins/automover/helpers/automover.sh';

// ── Entry point ───────────────────────────────────────────────────────────────
header('Content-Type: application/json');

// ── CSRF validation ───────────────────────────────────────────────────────────
$cookie_str = $_COOKIE['csrf_token'] ?? '';
$posted_str = $_POST['csrf_token']   ?? '';

if ($_SERVER['REQUEST_METHOD'] !== 'POST' || !hash_equals($cookie_str, $posted_str)) {
    echo json_encode(['ok' => false, 'error' => 'Invalid CSRF token']);
    exit;
}

// ── Input ─────────────────────────────────────────────────────────────────────
$pool_str = $_POST['pool'] ?? 'cache';

// ── Validation ────────────────────────────────────────────────────────────────
if (!file_exists(AUTOMOVER_SCRIPT)) {
    echo json_encode(['ok' => false, 'error' => 'automover.sh not found']);
    exit;
}

// ── Core logic ────────────────────────────────────────────────────────────────
$cmd_str = sprintf(
    '/bin/bash %s --force-now --pool %s >/dev/null 2>&1 &',
    escapeshellarg(AUTOMOVER_SCRIPT),
    escapeshellarg($pool_str)
);
exec($cmd_str);

// ── Response ──────────────────────────────────────────────────────────────────
echo json_encode([
    'status'    => 'success',
    'timestamp' => date('Y-m-d H:i:s'),
    'data'      => [
        'ok'      => true,
        'message' => 'Manual move started',
    ],
]);
<?php
declare(strict_types=1);

// ── Constants ─────────────────────────────────────────────────────────────────
const automover_SCRIPT = '/usr/local/emhttp/plugins/automover/helpers/automover_beta.sh';

// ── Entry point ───────────────────────────────────────────────────────────────
header('Content-Type: application/json');

// ── CSRF validation ───────────────────────────────────────────────────────────
$cookie_str = $_COOKIE['csrf_token'] ?? '';
$posted_str = $_POST['csrf_token']   ?? '';

if ($_SERVER['REQUEST_METHOD'] !== 'POST' || !hash_equals($cookie_str, $posted_str)) {
    echo json_encode(['ok' => false, 'error' => 'Invalid CSRF token']);
    exit;
}

// ── Validation ────────────────────────────────────────────────────────────────
if (!file_exists(automover_SCRIPT)) {
    echo json_encode(['ok' => false, 'error' => 'automover.sh not found']);
    exit;
}

// ── Core logic ────────────────────────────────────────────────────────────────
// Run with --force-now only. POOL_NAME is read from settings.cfg which
// doSaveSettings() already wrote before this request was made.
// Do NOT pass --pool here — that flag would override the saved config value.
$cmd_str = sprintf(
    '/bin/bash %s --force-now >/dev/null 2>&1 &',
    escapeshellarg(automover_SCRIPT)
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
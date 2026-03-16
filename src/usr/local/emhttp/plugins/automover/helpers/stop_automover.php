<?php
declare(strict_types=1);

// ── Constants ─────────────────────────────────────────────────────────────────
const LOCK_FILE   = '/tmp/automover/lock.txt';
const STATUS_FILE = '/tmp/automover/temp_logs/status.txt';

// ── Entry point ───────────────────────────────────────────────────────────────
header('Content-Type: application/json');

// ── CSRF validation ───────────────────────────────────────────────────────────
$cookie_str = $_COOKIE['csrf_token'] ?? '';
$posted_str = $_POST['csrf_token']   ?? '';

if ($_SERVER['REQUEST_METHOD'] !== 'POST' || !hash_equals($cookie_str, $posted_str)) {
    echo json_encode(['ok' => false, 'error' => 'Invalid CSRF token']);
    exit;
}

// ── Set stopping status ───────────────────────────────────────────────────────
file_put_contents(STATUS_FILE, 'Stopping automover…');

// ── Kill running processes ────────────────────────────────────────────────────
exec('pkill -f ' . escapeshellarg('automover.sh')    . ' 2>/dev/null');
exec('pkill -f ' . escapeshellarg('rsync -aH')            . ' 2>/dev/null');
exec('pkill -f ' . escapeshellarg('rsync --dry-run')      . ' 2>/dev/null');
exec('pkill -f ' . escapeshellarg('fuser -m')             . ' 2>/dev/null');
exec('pkill -f ' . escapeshellarg('find .*automover')  . ' 2>/dev/null');

// ── Kill process from lock file ───────────────────────────────────────────────
if (file_exists(LOCK_FILE)) {
    $pid_int = (int) trim((string) file_get_contents(LOCK_FILE));
    if ($pid_int > 0 && posix_kill($pid_int, 0)) {
        posix_kill($pid_int, SIGTERM);
        usleep(200000);
    }
    @unlink(LOCK_FILE);
}

// ── Reset status ──────────────────────────────────────────────────────────────
file_put_contents(STATUS_FILE, 'Stopped');

// ── Response ──────────────────────────────────────────────────────────────────
echo json_encode([
    'status'    => 'success',
    'timestamp' => date('Y-m-d H:i:s'),
    'data'      => [
        'ok' => true,
    ],
]);
<?php
declare(strict_types=1);

// ── Constants ─────────────────────────────────────────────────────────────────
define('SCHEDULES_CFG',   '/boot/config/plugins/automover/schedules.cfg');
define('LOCK_DIR',        '/tmp/automover');
define('LOCK_FILE',       LOCK_DIR . '/lock.txt');
define('AUTOMOVER_SCRIPT', '/usr/local/emhttp/plugins/automover/helpers/automover.sh');

// ── respond() ─────────────────────────────────────────────────────────────────
function respond(int $code, array $payload): void {
    http_response_code($code);
    header('Content-Type: application/json');
    echo json_encode($payload, JSON_UNESCAPED_SLASHES);
    exit;
}

// ── load_schedules() ──────────────────────────────────────────────────────────
function load_schedules(string $cfg): array {
    $real = realpath($cfg);
    if ($real === false || !file_exists($real)) {
        respond(404, ['status' => 'error', 'message' => 'Schedules file not found']);
    }
    $schedules = parse_ini_file($real, true, INI_SCANNER_RAW);
    if (!is_array($schedules)) {
        respond(500, ['status' => 'error', 'message' => 'Failed to parse schedules file']);
    }
    return $schedules;
}

// ── acquire_lock() ────────────────────────────────────────────────────────────
function acquire_lock(): mixed {
    if (!is_dir(LOCK_DIR)) {
        if (!mkdir(LOCK_DIR, 0777, true)) {
            respond(500, ['status' => 'error', 'message' => 'Unable to create lock directory']);
        }
    }

    $fp = fopen(LOCK_FILE, 'c');
    if (!$fp) {
        respond(500, ['status' => 'error', 'message' => 'Unable to open lock file']);
    }

    // Non-blocking — bail immediately if another instance holds the lock
    if (!flock($fp, LOCK_EX | LOCK_NB)) {
        respond(409, ['status' => 'error', 'message' => 'Automover already running']);
    }

    return $fp;
}

// ── write_lock_meta() ─────────────────────────────────────────────────────────
function write_lock_meta(mixed $fp, string $pid, string $id): void {
    $meta = implode("\n", [
        "PID={$pid}",
        "MODE=schedule",
        "SCHEDULE_ID={$id}",
        "START=" . time(),
    ]) . "\n";

    ftruncate($fp, 0);
    fwrite($fp, $meta);
    fflush($fp);
}

// ── main() ────────────────────────────────────────────────────────────────────
function main(): void {
    // Accept ID from env (cron) or POST (manual run button) — env takes priority
    $id = trim(getenv('SCHEDULE_ID') ?: ($_POST['id'] ?? ''));

    if ($id === '') {
        respond(400, ['status' => 'error', 'message' => 'Missing schedule ID']);
    }

    $schedules = load_schedules(SCHEDULES_CFG);

    if (!isset($schedules[$id])) {
        respond(404, ['status' => 'error', 'message' => 'Schedule not found']);
    }

    // Decode settings and export as env vars for the shell script
    $settings = json_decode(stripslashes($schedules[$id]['SETTINGS'] ?? ''), true);
    if (!is_array($settings)) {
        $settings = [];
    }

    foreach ($settings as $key => $val) {
        putenv("{$key}={$val}");
    }
    putenv("SCHEDULE_ID={$id}");

    if (!is_file(AUTOMOVER_SCRIPT) || !is_executable(AUTOMOVER_SCRIPT)) {
        respond(500, ['status' => 'error', 'message' => 'automover.sh missing or not executable']);
    }

    $fp = acquire_lock();

    $cmd = 'nohup /bin/bash ' . AUTOMOVER_SCRIPT . ' >/dev/null 2>&1 & echo $!';
    $pid = trim((string)shell_exec($cmd));

    if ($pid === '' || !is_numeric($pid)) {
        respond(500, ['status' => 'error', 'message' => 'Failed to start automover']);
    }

    write_lock_meta($fp, $pid, $id);

    respond(200, [
        'status'  => 'ok',
        'started' => true,
        'id'      => $id,
        'pid'     => $pid,
    ]);
}

main();
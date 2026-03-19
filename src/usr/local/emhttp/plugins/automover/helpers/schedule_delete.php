<?php
declare(strict_types=1);

require_once __DIR__ . '/rebuild_cron.php';

// ── Constants ─────────────────────────────────────────────────────────────────
define('SCHEDULES_CFG', '/boot/config/plugins/automover/schedules.cfg');

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
        respond(404, ['error' => 'Schedules file not found']);
    }
    $schedules = parse_ini_file($real, true, INI_SCANNER_RAW);
    if (!is_array($schedules)) {
        respond(500, ['error' => 'Failed to parse schedules file']);
    }
    return $schedules;
}

// ── write_schedules() ─────────────────────────────────────────────────────────
function write_schedules(string $cfg, array $schedules): void {
    $real = realpath($cfg);
    if ($real === false) {
        respond(500, ['error' => 'Cannot resolve schedules file path']);
    }

    $tmp = $real . '.tmp';
    $out = '';
    foreach ($schedules as $id => $fields) {
        $out .= "[{$id}]\n";
        ksort($fields);
        foreach ($fields as $key => $val) {
            $out .= "{$key}=\"{$val}\"\n";
        }
        $out .= "\n";
    }

    if (file_put_contents($tmp, $out) === false) {
        respond(500, ['error' => 'Failed to write temporary schedules file']);
    }
    if (!rename($tmp, $real)) {
        @unlink($tmp);
        respond(500, ['error' => 'Failed to commit schedules file update']);
    }
}

// ── main() ────────────────────────────────────────────────────────────────────
function main(): void {
    $id = trim($_POST['id'] ?? '');

    if ($id === '') {
        respond(400, ['error' => 'Missing schedule ID']);
    }

    $schedules = load_schedules(SCHEDULES_CFG);

    if (!isset($schedules[$id])) {
        respond(404, ['error' => 'Schedule not found']);
    }

    unset($schedules[$id]);

    write_schedules(SCHEDULES_CFG, $schedules);
    rebuild_cron();

    respond(200, ['success' => true]);
}

main();
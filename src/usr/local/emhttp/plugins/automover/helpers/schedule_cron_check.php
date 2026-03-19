<?php
declare(strict_types=1);

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
        return [];
    }
    $schedules = parse_ini_file($real, true, INI_SCANNER_RAW);
    return is_array($schedules) ? $schedules : [];
}

// ── main() ────────────────────────────────────────────────────────────────────
function main(): void {
    $schedules = load_schedules(SCHEDULES_CFG);

    $crons = [];
    foreach ($schedules as $id => $s) {
        $cron    = trim((string)($s['CRON'] ?? ''));
        $enabled = strtolower((string)($s['ENABLED'] ?? 'yes')) === 'yes';

        if ($cron === '') continue;

        $crons[] = [
            'id'      => $id,
            'cron'    => $cron,
            'enabled' => $enabled,
        ];
    }

    respond(200, $crons);
}

main();
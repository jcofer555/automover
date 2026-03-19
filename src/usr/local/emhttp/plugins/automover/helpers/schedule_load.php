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
        respond(404, ['error' => 'Schedules file not found']);
    }
    $schedules = parse_ini_file($real, true, INI_SCANNER_RAW);
    if (!is_array($schedules)) {
        respond(500, ['error' => 'Failed to parse schedules file']);
    }
    return $schedules;
}

// ── main() ────────────────────────────────────────────────────────────────────
function main(): void {
    $id = trim($_GET['id'] ?? '');

    if ($id === '') {
        respond(400, ['error' => 'Missing schedule ID']);
    }

    $schedules = load_schedules(SCHEDULES_CFG);

    if (!isset($schedules[$id])) {
        respond(404, ['error' => 'Schedule not found']);
    }

    $entry = $schedules[$id];

    // Decode SETTINGS JSON — strip INI escaping, fall back to empty array
    $settings = json_decode(stripslashes($entry['SETTINGS'] ?? '{}'), true);
    if (!is_array($settings)) {
        $settings = [];
    }

    // Return decoded settings so JS can populate the form fields directly
    $entry['SETTINGS'] = $settings;

    respond(200, $entry);
}

main();
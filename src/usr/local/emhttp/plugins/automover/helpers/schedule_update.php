<?php
declare(strict_types=1);

require_once __DIR__ . '/rebuild_cron.php';

// ── Constants ─────────────────────────────────────────────────────────────────
define('SCHEDULES_CFG', '/boot/config/plugins/automover/schedules.cfg');
define('CRON_PATTERN',  '/^([\*\/0-9,-]+\s+){4}[\*\/0-9,-]+$/');

// ── Allowed settings keys ─────────────────────────────────────────────────────
const ALLOWED_KEYS = [
    'AGE_BASED_FILTER',
    'AGE_DAYS',
    'ALLOW_DURING_PARITY',
    'AUTOSTART_ON_BOOT',
    'STOP_CONTAINERS',
    'CRON_EXPRESSION',
    'CRON_MODE',
    'DAILY_MINUTE',
    'DAILY_TIME',
    'DRY_RUN',
    'CLEANUP',
    'JDUPES',
    'NOTIFICATIONS',
    'PRE_AND_POST_SCRIPTS',
    'SSD_TRIM',
    'EXCLUSIONS',
    'FORCE_TURBO_WRITE',
    'HASH_LOCATION',
    'HIDDEN_FILTER',
    'HOURLY_FREQUENCY',
    'IO_PRIORITY',
    'MONTHLY_DAY',
    'MONTHLY_MINUTE',
    'MONTHLY_TIME',
    'NOTIFICATION_SERVICE',
    'POOL_NAME',
    'POST_SCRIPT',
    'PRE_SCRIPT',
    'CPU_AND_IO_PRIORITIES',
    'CPU_PRIORITY',
    'PUSHOVER_USER_KEY',
    'QBITTORRENT_DAYS_FROM',
    'QBITTORRENT_DAYS_TO',
    'QBITTORRENT_HOST',
    'QBITTORRENT_PASSWORD',
    'QBITTORRENT_MOVE_SCRIPT',
    'QBITTORRENT_STATUS',
    'QBITTORRENT_USERNAME',
    'SIZE_BASED_FILTER',
    'SIZE',
    'SIZE_UNIT',
    'STOP_ALL_CONTAINERS',
    'STOP_THRESHOLD',
    'THRESHOLD',
    'WEBHOOK_DISCORD',
    'WEBHOOK_GOTIFY',
    'WEBHOOK_NTFY',
    'WEBHOOK_PUSHOVER',
    'WEBHOOK_SLACK',
    'WEEKLY_DAY',
    'WEEKLY_MINUTE',
    'WEEKLY_TIME',
];

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

// ── check_duplicate() ─────────────────────────────────────────────────────────
// Reject if another schedule (not the one being updated) has the same cron expression.
function check_duplicate(array $schedules, string $new_cron, string $exclude_id): void {
    foreach ($schedules as $id => $s) {
        if ($id === $exclude_id) continue;
        if (trim((string)($s['CRON'] ?? '')) === $new_cron) {
            respond(409, [
                'error'       => 'A schedule with this cron expression already exists',
                'conflict_id' => $id,
            ]);
        }
    }
}

// ── main() ────────────────────────────────────────────────────────────────────
function main(): void {
    $id       = trim($_POST['id']       ?? '');
    $cron     = trim($_POST['cron']     ?? '');
    $settings = $_POST['settings']      ?? [];

    if (!is_array($settings)) {
        $settings = [];
    }

    // Allowlist — strip anything that shouldn't be persisted
    $settings = array_intersect_key($settings, array_flip(ALLOWED_KEYS));
    unset($settings['csrf_token']);

    if ($id === '') {
        respond(400, ['error' => 'Missing schedule ID']);
    }

    if (!preg_match(CRON_PATTERN, $cron)) {
        respond(400, ['error' => 'Invalid cron expression']);
    }

    if (trim($settings['POOL_NAME'] ?? '') === '') {
        respond(400, ['error' => 'Pool name is required']);
    }

    $schedules = load_schedules(SCHEDULES_CFG);

    if (!isset($schedules[$id])) {
        respond(404, ['error' => 'Schedule not found']);
    }

    // Duplicate cron check — exclude self to avoid false conflict on unchanged cron
    check_duplicate($schedules, $cron, $id);

    // Encode settings as escaped JSON for safe INI storage
    $settings_json = addcslashes(
        json_encode($settings, JSON_UNESCAPED_SLASHES),
        '"'
    );

    // Preserve ENABLED state, update CRON and SETTINGS
    $schedules[$id]['CRON']     = $cron;
    $schedules[$id]['SETTINGS'] = $settings_json;

    write_schedules(SCHEDULES_CFG, $schedules);
    rebuild_cron();

    respond(200, ['success' => true]);
}

main();
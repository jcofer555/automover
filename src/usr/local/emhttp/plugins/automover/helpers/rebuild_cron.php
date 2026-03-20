<?php
declare(strict_types=1);

// ── Constants ─────────────────────────────────────────────────────────────────
// Use defined() guards so this file is safe to require_once from files that
// also define these constants (schedule_create.php, schedule_update.php).
if (!defined('SCHEDULES_CFG'))    define('SCHEDULES_CFG',    '/boot/config/plugins/automover/schedules.cfg');
if (!defined('CRON_FILE'))        define('CRON_FILE',        '/boot/config/plugins/automover/automover.cron');
if (!defined('RUN_SCHEDULE_PHP')) define('RUN_SCHEDULE_PHP', '/usr/local/emhttp/plugins/automover/helpers/run_schedule.php');

// ── rebuild_cron() ────────────────────────────────────────────────────────────
// Reads schedules.cfg and writes a fresh .cron file, then calls update_cron.
// Called by schedule_create, schedule_update, schedule_delete, schedule_toggle.
function rebuild_cron(): void {
    // No schedules file yet — write empty cron and bail
    if (!file_exists(SCHEDULES_CFG)) {
        file_put_contents(CRON_FILE, '');
        exec('update_cron');
        return;
    }

    $schedules = parse_ini_file(SCHEDULES_CFG, true, INI_SCANNER_RAW);
    if (!is_array($schedules)) {
        file_put_contents(CRON_FILE, '');
        exec('update_cron');
        return;
    }

    $out = "# Automover Beta schedules\n";

    foreach ($schedules as $id => $s) {
        // Skip disabled schedules
        $enabled = strtolower((string)($s['ENABLED'] ?? 'yes')) === 'yes';
        if (!$enabled) continue;

        $cron = trim((string)($s['CRON'] ?? ''));
        if ($cron === '') continue;

        // Pass schedule ID via env so cron doesn't need shell quoting tricks
        $out .= "{$cron} sh -c 'SCHEDULE_ID={$id} /usr/bin/php -f " . RUN_SCHEDULE_PHP . "'\n";
    }

    file_put_contents(CRON_FILE, $out);
    exec('update_cron');
}
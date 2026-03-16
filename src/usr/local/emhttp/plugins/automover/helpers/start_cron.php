<?php
declare(strict_types=1);

// ── Constants ─────────────────────────────────────────────────────────────────
const CFG_PATH  = '/boot/config/plugins/automover/settings.cfg';
const CRON_FILE = '/boot/config/plugins/automover/automover.cron';
const CRON_CMD  = '/usr/local/emhttp/plugins/automover/helpers/automover.sh';

// ── Entry point ───────────────────────────────────────────────────────────────
header('Content-Type: application/json');

// ── Input ─────────────────────────────────────────────────────────────────────
$cron_expr_str  = trim($_POST['CRON_EXPRESSION'] ?? '');
$cron_mode_str  = $_POST['CRON_MODE']         ?? 'daily';
$hourly_str     = $_POST['HOURLY_FREQUENCY']  ?? '';
$daily_str      = $_POST['DAILY_TIME']        ?? '';
$weekly_day_str = $_POST['WEEKLY_DAY']        ?? '';
$weekly_time_str= $_POST['WEEKLY_TIME']       ?? '';
$monthly_day_str= $_POST['MONTHLY_DAY']       ?? '';
$monthly_time_str=$_POST['MONTHLY_TIME']      ?? '';

// ── Validation ────────────────────────────────────────────────────────────────
if ($cron_expr_str === '') {
    http_response_code(400);
    echo json_encode(['status' => 'error', 'message' => 'Missing cron expression']);
    exit;
}

// ── Write cron file ───────────────────────────────────────────────────────────
$cron_entry_str = $cron_expr_str . ' ' . CRON_CMD . " &> /dev/null 2>&1\n";

if (file_put_contents(CRON_FILE, $cron_entry_str) === false) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => 'Failed to write cron file']);
    exit;
}

exec('update_cron');

// ── Persist settings ──────────────────────────────────────────────────────────
$settings_arr = parse_ini_file(CFG_PATH) ?: [];

foreach ($_POST as $key_str => $val_str) {
    $settings_arr[$key_str] = $val_str;
}

$settings_arr['CRON_MODE']       = $cron_mode_str;
$settings_arr['HOURLY_FREQUENCY']= $hourly_str;
$settings_arr['DAILY_TIME']      = $daily_str;
$settings_arr['WEEKLY_DAY']      = $weekly_day_str;
$settings_arr['WEEKLY_TIME']     = $weekly_time_str;
$settings_arr['MONTHLY_DAY']     = $monthly_day_str;
$settings_arr['MONTHLY_TIME']    = $monthly_time_str;
$settings_arr['CRON_EXPRESSION'] = $cron_expr_str;

$cfg_out_str = '';
foreach ($settings_arr as $k_str => $v_str) {
    $cfg_out_str .= $k_str . '="' . $v_str . '"' . "\n";
}
file_put_contents(CFG_PATH, $cfg_out_str);

// ── Response ──────────────────────────────────────────────────────────────────
echo json_encode([
    'status'    => 'success',
    'timestamp' => date('Y-m-d H:i:s'),
    'data'      => [
        'ok' => true,
    ],
]);
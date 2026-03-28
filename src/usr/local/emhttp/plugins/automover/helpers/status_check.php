<?php
declare(strict_types=1);

// ── Constants ─────────────────────────────────────────────────────────────────
const CRON_FILE        = '/boot/config/plugins/automover/automover.cron';
const LAST_RUN_LOG     = '/tmp/automover/last_run.log';
const ARRAY_STATE_FILE = '/var/local/emhttp/var.ini';
const STATUS_FILE      = '/tmp/automover/temp_logs/status.txt';

// ── Utilities ─────────────────────────────────────────────────────────────────
function format_time_ago(int $diff_int): string {
    if ($diff_int < 10)      return 'just now';
    if ($diff_int < 60)      return $diff_int . ' seconds ago';
    $min_int = (int) floor($diff_int / 60);
    if ($diff_int < 3600)    return $min_int . ' minute' . ($min_int !== 1 ? 's' : '') . ' ago';
    $hrs_int = (int) floor($diff_int / 3600);
    if ($diff_int < 86400)   return $hrs_int . ' hour' . ($hrs_int !== 1 ? 's' : '') . ' ago';
    $days_int = (int) floor($diff_int / 86400);
    if ($diff_int < 604800)  return $days_int . ' day' . ($days_int !== 1 ? 's' : '') . ' ago';
    $weeks_int = (int) floor($diff_int / 604800);
    if ($diff_int < 2592000) return 'over ' . $weeks_int . ' week' . ($weeks_int !== 1 ? 's' : '') . ' ago';
    $months_int = (int) floor($diff_int / 2592000);
    if ($diff_int < 7776000) return 'over ' . $months_int . ' month' . ($months_int !== 1 ? 's' : '') . ' ago';
    return 'on ' . date('M d, Y h:i A', time() - $diff_int);
}

// ── Entry point ───────────────────────────────────────────────────────────────
header('Content-Type: application/json');

$status_str      = 'Stopped';
$last_run_str    = '';
$last_run_ts_str = '';

// Ensure status directory exists
$status_dir_str = dirname(STATUS_FILE);
if (!is_dir($status_dir_str)) {
    @mkdir($status_dir_str, 0755, true);
}

// ── Extract most recent timestamp from log ───────────────────────────────────
if (file_exists(LAST_RUN_LOG)) {
    $log_lines_arr = array_reverse(file(LAST_RUN_LOG, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES));
    foreach ($log_lines_arr as $line_str) {
        if (preg_match('/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/', $line_str, $match_arr)) {
            $last_run_ts_str = $match_arr[0];
            break;
        }
    }
}

// ── Determine if automover is scheduled ─────────────────────────────────
$scheduled_bool = file_exists(CRON_FILE) &&
    strpos((string) file_get_contents(CRON_FILE), 'automover.sh') !== false;

// ── Check array state ────────────────────────────────────────────────────────
$array_stopped_bool  = false;
$parity_running_bool = false;

if (file_exists(ARRAY_STATE_FILE)) {
    $var_ini_str = (string) file_get_contents(ARRAY_STATE_FILE);

    if (preg_match('/mdState="([^"]+)"/', $var_ini_str, $match_arr)) {
        $array_stopped_bool = ($match_arr[1] === 'STOPPED');
    }

    if (preg_match('/mdResync="([1-9][0-9]*)"/', $var_ini_str)) {
        $parity_running_bool = true;
    }
}

// ── Base status ──────────────────────────────────────────────────────────────
$running_label_str = $scheduled_bool ? 'Running' : 'Stopped';

if ($array_stopped_bool) {
    $status_str = 'Array Is Not Started While automover Is ' . $running_label_str;
} elseif ($parity_running_bool) {
    $status_str = 'Parity Check Happening While automover Is ' . $running_label_str;
} else {
    $status_str = $scheduled_bool ? 'Running' : 'Stopped';
}

// ── Override with live moving state if active ────────────────────────────────
if (file_exists(STATUS_FILE)) {
    $moving_state_str = trim((string) file_get_contents(STATUS_FILE));
    if (stripos($moving_state_str, 'moving files for share:') === 0) {
        $status_str = $moving_state_str;
    }
}

// ── Format last run time ─────────────────────────────────────────────────────
if ($last_run_ts_str !== '') {
    $last_ts_int = (int) strtotime($last_run_ts_str);
    if ($last_ts_int > 0) {
        $last_run_str = format_time_ago(time() - $last_ts_int);
    }
}

// ── Persist detected status ──────────────────────────────────────────────────
file_put_contents(STATUS_FILE, $status_str);

// ── Response ─────────────────────────────────────────────────────────────────
echo json_encode([
    'status'    => 'success',
    'timestamp' => date('Y-m-d H:i:s'),
    'data'      => [
        'status'      => $status_str,
        'last_run'    => $last_run_str,
        'last_run_ts' => $last_run_ts_str,
    ],
]);
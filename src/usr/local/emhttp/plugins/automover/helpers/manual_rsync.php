<?php
declare(strict_types=1);

// ── Constants ─────────────────────────────────────────────────────────────────
const LOCK_FILE         = '/tmp/automover/lock.txt';
const LAST_RUN_LOG      = '/tmp/automover/last_run.log';
const STATUS_FILE       = '/tmp/automover/temp_logs/status.txt';
const MOVED_LOG         = '/tmp/automover/files_moved.log';
const MOVED_LOG_PREV    = '/tmp/automover/files_moved_prev.log';
const INUSE_FILE        = '/tmp/automover/in_use_files.txt';
const EXCLUDE_FILE      = '/tmp/automover/manual_rsync_in_use_files.txt';
const CFG_FILE          = '/boot/config/plugins/automover/settings.cfg';
const NOTIFY_SCRIPT     = '/usr/local/emhttp/webGui/scripts/notify';
const DYNAMIX_CFG       = '/boot/config/plugins/dynamix/dynamix.cfg';

// ── Utilities ─────────────────────────────────────────────────────────────────
function load_settings(string $path_str): array {
    $settings_arr = [];
    if (!file_exists($path_str)) return $settings_arr;
    foreach (file($path_str, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line_str) {
        if (strpos($line_str, '=') === false) continue;
        [$key_str, $val_str] = array_map('trim', explode('=', $line_str, 2));
        $settings_arr[$key_str] = trim($val_str, '"');
    }
    return $settings_arr;
}

function set_status(string $status_str): void {
    @file_put_contents(STATUS_FILE, $status_str);
}

function log_append(string $message_str): void {
    file_put_contents(LAST_RUN_LOG, $message_str . "\n", FILE_APPEND);
}

function format_runtime(int $seconds_int): string {
    if ($seconds_int < 60)   return $seconds_int . 's';
    if ($seconds_int < 3600) return floor($seconds_int / 60) . 'm ' . ($seconds_int % 60) . 's';
    return floor($seconds_int / 3600) . 'h ' . floor(($seconds_int % 3600) / 60) . 'm';
}

function send_discord(string $webhook_str, string $title_str, string $body_str, int $color_int): void {
    $json_str = json_encode(['embeds' => [['title' => $title_str, 'description' => $body_str, 'color' => $color_int]]]);
    exec('curl -s -X POST -H ' . escapeshellarg('Content-Type: application/json') .
         ' -d ' . escapeshellarg($json_str) . ' ' . escapeshellarg($webhook_str) . ' >/dev/null 2>&1');
}

function send_unraid_notify(string $subject_str, string $body_str, int $delay_int = 0): void {
    $cmd_str = NOTIFY_SCRIPT . ' -e automover -s ' . escapeshellarg($subject_str) .
               ' -d ' . escapeshellarg($body_str) . ' -i normal';
    if ($delay_int > 0) {
        exec('echo ' . escapeshellarg($cmd_str) . ' | at now + ' . $delay_int . ' minute');
    } else {
        exec($cmd_str);
    }
}

function is_agent_active(): bool {
    if (!file_exists(DYNAMIX_CFG)) return false;
    $val_str = trim((string) shell_exec("grep -Po 'normal=\"\\K[0-9]+' " . escapeshellarg(DYNAMIX_CFG) . ' 2>/dev/null'));
    return (bool) preg_match('/^(4|5|6|7)$/', $val_str);
}

function ensure_dir(string $path_str): void {
    if (!is_dir($path_str)) {
        @mkdir($path_str, 0777, true);
    }
}

// ── Entry point ───────────────────────────────────────────────────────────────
header('Content-Type: application/json');

// ── CSRF validation ───────────────────────────────────────────────────────────
$cookie_str = $_COOKIE['csrf_token'] ?? '';
$posted_str = $_POST['csrf_token']   ?? '';

if ($_SERVER['REQUEST_METHOD'] !== 'POST' || !hash_equals($cookie_str, $posted_str)) {
    echo json_encode(['ok' => false, 'error' => 'Invalid CSRF token']);
    exit;
}

// ── Lock check ────────────────────────────────────────────────────────────────
if (file_exists(LOCK_FILE)) {
    $pid_int = (int) trim((string) file_get_contents(LOCK_FILE));
    if ($pid_int > 0 && posix_kill($pid_int, 0)) {
        echo json_encode(['ok' => false, 'error' => 'automover already running']);
        exit;
    }
    @unlink(LOCK_FILE);
}

file_put_contents(LOCK_FILE, (string) getmypid());
set_status('Manual Rsync Starting');
usleep(150000);
set_status('Manual Rsync Running');

// ── Load settings ─────────────────────────────────────────────────────────────
$settings_arr        = load_settings(CFG_FILE);
$webhook_str         = '';
$raw_webhook_str     = $settings_arr['WEBHOOK_URL'] ?? '';
if ($raw_webhook_str !== '' && strtolower(trim($raw_webhook_str)) !== 'null') {
    $webhook_str = trim($raw_webhook_str);
}
$notify_bool         = strtolower($settings_arr['ENABLE_NOTIFICATIONS'] ?? 'no') === 'yes';
$dry_run_bool        = strtolower($settings_arr['DRY_RUN']               ?? 'no') === 'yes';
$enable_cleanup_bool = strtolower($settings_arr['ENABLE_CLEANUP']        ?? 'no') === 'yes';

// ── Input validation ──────────────────────────────────────────────────────────
$src_raw_str = rtrim($_POST['source'] ?? '', '/');
$dst_raw_str = rtrim($_POST['dest']   ?? '', '/');
$copy_str    = $_POST['copy']     ?? '0';
$del_str     = $_POST['delete']   ?? '0';
$full_str    = $_POST['fullsync'] ?? '0';

if ($src_raw_str === '' || $dst_raw_str === '') {
    @unlink(LOCK_FILE);
    set_status('Stopped');
    echo json_encode(['ok' => false, 'error' => 'Missing source or destination']);
    exit;
}

$src_str = $src_raw_str . '/';
$dst_str = $dst_raw_str . '/';

// ── Ensure destination exists with correct ownership ──────────────────────────
if (!is_dir($dst_str)) {
    mkdir($dst_str, 0777, true);
    $parent_str  = dirname(rtrim($dst_str, '/'));
    $parent_stat = @stat($parent_str);
    if ($parent_stat) {
        if (function_exists('posix_getpwuid')) {
            $pw_arr = @posix_getpwuid($parent_stat['uid']);
            if (!empty($pw_arr['name'])) @chown($dst_str, $pw_arr['name']);
        }
        if (function_exists('posix_getgrgid')) {
            $gr_arr = @posix_getgrgid($parent_stat['gid']);
            if (!empty($gr_arr['name'])) @chgrp($dst_str, $gr_arr['name']);
        }
    }
}

// ── Mode name ─────────────────────────────────────────────────────────────────
if ($full_str === '1')     $mode_name_str = 'full sync';
elseif ($del_str  === '1') $mode_name_str = 'delete source after';
else                       $mode_name_str = 'copy';
if ($dry_run_bool)         $mode_name_str .= ' (dry run)';

// ── Session header ────────────────────────────────────────────────────────────
file_put_contents(LAST_RUN_LOG,
    "------------------------------------------------\n" .
    'Session started - ' . date('Y-m-d H:i:s') . "\n" .
    "Manually rsyncing {$src_str} -> {$dst_str} using mode: {$mode_name_str}\n"
);
if ($dry_run_bool) log_append('Dry run active - no files will be moved');

$start_time_int = time();

// ── Start notification ────────────────────────────────────────────────────────
if ($notify_bool) {
    $start_body_str = "Manual rsync has started.\n{$src_str} → {$dst_str}";
    if ($webhook_str !== '') {
        send_discord($webhook_str, 'Manual rsync started', $start_body_str, 16776960);
    } else {
        send_unraid_notify('Manual rsync started', 'Manual rsync operation has started');
    }
}

// ── Prepare log files ─────────────────────────────────────────────────────────
if (file_exists(MOVED_LOG)) unlink(MOVED_LOG);
file_put_contents(INUSE_FILE,   '');
file_put_contents(EXCLUDE_FILE, '');

$inuse_count_int = 0;
$output_arr      = [];
$moved_any_bool  = false;
$share_counts_arr = [];

// ── Run rsync ─────────────────────────────────────────────────────────────────
if ($full_str === '1') {
    // Full sync: gather in-use files first, exclude them
    $all_files_arr   = [];
    $files_in_use_arr = [];
    exec('find ' . escapeshellarg($src_str) . ' -type f 2>/dev/null', $all_files_arr);

    foreach ($all_files_arr as $file_str) {
        $fuser_str = (string) shell_exec('fuser -m ' . escapeshellarg($file_str) . ' 2>/dev/null');
        if (trim($fuser_str) !== '') {
            $rel_str = substr($file_str, strlen($src_str));
            $files_in_use_arr[] = $rel_str;
            file_put_contents(INUSE_FILE, $file_str . "\n", FILE_APPEND);
            $inuse_count_int++;
        }
    }

    $exclude_opt_str = '';
    if (!empty($files_in_use_arr)) {
        file_put_contents(EXCLUDE_FILE, implode("\n", $files_in_use_arr) . "\n");
        $exclude_opt_str = ' --exclude-from=' . escapeshellarg(EXCLUDE_FILE);
    }

    $dry_flag_str = $dry_run_bool ? '--dry-run ' : '';
    $cmd_str = 'rsync ' . $dry_flag_str . '-aH --delete --out-format=%n' .
               $exclude_opt_str . ' ' .
               escapeshellarg($src_str) . ' ' . escapeshellarg($dst_str);
    exec($cmd_str . ' 2>&1', $output_arr);

    if ($inuse_count_int > 0) {
        log_append("Skipped {$inuse_count_int} in-use file(s)");
    }

} else {
    // Copy or delete mode: per-file
    $all_files_arr = [];
    exec('find ' . escapeshellarg($src_str) . ' -type f 2>/dev/null', $all_files_arr);

    foreach ($all_files_arr as $file_str) {
        if (trim($file_str) === '') continue;

        $fuser_str = (string) shell_exec('fuser -m ' . escapeshellarg($file_str) . ' 2>/dev/null');
        if (trim($fuser_str) !== '') {
            file_put_contents(INUSE_FILE, $file_str . "\n", FILE_APPEND);
            $inuse_count_int++;
            continue;
        }

        $delete_flag_str = ($del_str === '1') ? '--remove-source-files ' : '';
        $dry_flag_str    = $dry_run_bool ? '--dry-run ' : '';
        $cmd_str = 'rsync ' . $dry_flag_str . '-aH ' . $delete_flag_str .
                   '--out-format=%n ' .
                   escapeshellarg($file_str) . ' ' . escapeshellarg($dst_str);
        exec($cmd_str . ' 2>&1', $output_arr);
    }

    if ($inuse_count_int > 0) {
        log_append("Skipped {$inuse_count_int} in-use file(s)");
    }
}

// ── Parse moved files ─────────────────────────────────────────────────────────
foreach ($output_arr as $line_str) {
    $line_str = trim($line_str);
    if ($line_str === '') continue;
    if (preg_match('/^(sending incremental|sent|total|bytes|speedup|created|deleting)/i', $line_str)) continue;

    $moved_any_bool = true;
    $src_file_str   = $src_str . $line_str;
    $dst_file_str   = $dst_str . $line_str;
    file_put_contents(MOVED_LOG, "{$src_file_str} -> {$dst_file_str}\n", FILE_APPEND);

    $parts_arr = explode('/', trim($dst_file_str, '/'));
    if (count($parts_arr) >= 3 && $parts_arr[1] === 'user0') {
        $share_str = $parts_arr[2];
        $share_counts_arr[$share_str] = ($share_counts_arr[$share_str] ?? 0) + 1;
    }
}

if (!$moved_any_bool) {
    file_put_contents(MOVED_LOG, "No files moved for this manual move\n");
} else {
    copy(MOVED_LOG, MOVED_LOG_PREV);
}

// ── Cleanup empty directories ─────────────────────────────────────────────────
if ($del_str === '1' && !$dry_run_bool && $enable_cleanup_bool) {
    exec('find ' . escapeshellarg($src_str) . ' -type d -empty -delete 2>/dev/null');
    log_append('Cleaned up empty directories from source');
}

// ── Finish notification ───────────────────────────────────────────────────────
$runtime_str = format_runtime(time() - $start_time_int);

if ($notify_bool) {
    if ($webhook_str !== '') {
        $body_str = "Manual rsync finished.\nMoved: " . ($moved_any_bool ? 'Yes' : 'No') . "\nRuntime: {$runtime_str}";
        if ($moved_any_bool && !empty($share_counts_arr)) {
            $body_str .= "\n\nPer share summary:";
            foreach ($share_counts_arr as $share_str => $count_int) {
                $body_str .= "\n• {$share_str}: {$count_int} file(s)";
            }
        }
        send_discord($webhook_str, 'Manual rsync finished', $body_str, 65280);
    } else {
        $agent_active_bool = is_agent_active();
        $body_str = "Manual rsync finished. Runtime: {$runtime_str}.";
        if ($moved_any_bool && !empty($share_counts_arr)) {
            if ($agent_active_bool) {
                $body_str .= ' - Per share summary: ';
                $first_bool = true;
                foreach ($share_counts_arr as $share_str => $count_int) {
                    if ($first_bool) { $body_str .= "{$share_str}: {$count_int} file(s)"; $first_bool = false; }
                    else             { $body_str .= " - {$share_str}: {$count_int} file(s)"; }
                }
            } else {
                $body_str .= '<br><br>Per share summary:<br>';
                foreach ($share_counts_arr as $share_str => $count_int) {
                    $body_str .= "• {$share_str}: {$count_int} file(s)<br>";
                }
            }
        }
        send_unraid_notify('Manual rsync finished', $body_str, 1);
    }
}

// ── Session footer ────────────────────────────────────────────────────────────
log_append('Session finished - ' . date('Y-m-d H:i:s'));
log_append('');

// ── Cleanup lock ──────────────────────────────────────────────────────────────
@unlink(LOCK_FILE);
set_status('Stopped');

echo json_encode([
    'status'    => 'success',
    'timestamp' => date('Y-m-d H:i:s'),
    'data'      => [
        'ok' => true,
    ],
]);
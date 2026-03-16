<?php
declare(strict_types=1);

// ── Constants ─────────────────────────────────────────────────────────────────
const LOG_DIR       = '/tmp/automover';
const MOVED_LOG     = LOG_DIR . '/files_moved.log';
const PREV_LOG      = LOG_DIR . '/files_moved_prev.log';
const LAST_RUN_LOG  = LOG_DIR . '/last_run.log';

// ── Entry point ───────────────────────────────────────────────────────────────
header('Content-Type: application/json');

if (!is_dir(LOG_DIR)) {
    @mkdir(LOG_DIR, 0755, true);
}

// ── Input ─────────────────────────────────────────────────────────────────────
$keyword_str = isset($_GET['filter']) ? strtolower(trim($_GET['filter'])) : '';

// ── Read moved log ────────────────────────────────────────────────────────────
$lines_arr = file_exists(MOVED_LOG)
    ? file(MOVED_LOG, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES)
    : [];

$matched_arr      = [];
$moved_count_int  = 0;
$no_move_bool     = false;

foreach ($lines_arr as $line_str) {
    $lower_str = strtolower($line_str);

    if ($keyword_str !== '' && strpos($lower_str, $keyword_str) === false) {
        continue;
    }

    if (strpos($lower_str, 'no files moved for this move') !== false ||
        strpos($lower_str, 'dry run: no files would have been moved') !== false) {
        $matched_arr[] = $line_str;
        $no_move_bool  = true;
        continue;
    }

    if (strpos($line_str, '->') !== false) {
        $moved_count_int++;
        $matched_arr[] = $line_str;
    }
}

$matched_arr = array_reverse($matched_arr);

// ── Append previous run if no files moved ────────────────────────────────────
if ($no_move_bool && file_exists(PREV_LOG)) {
    $matched_arr[] = '';
    $matched_arr[] = '----- Previous Run Moved Files -----';
    $prev_lines_arr = file(PREV_LOG, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    foreach (array_reverse($prev_lines_arr) as $prev_line_str) {
        if (strpos($prev_line_str, '->') !== false) {
            $matched_arr[] = $prev_line_str;
        }
    }
}

// ── Read last run log ─────────────────────────────────────────────────────────
$last_run_lines_arr = file_exists(LAST_RUN_LOG)
    ? file(LAST_RUN_LOG, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES)
    : [];

$last_message_str = 'No files moved for this run';

foreach (array_reverse($last_run_lines_arr) as $line_str) {
    if (stripos($line_str, 'Dry run: No files would have been moved') !== false) {
        $last_message_str = 'Dry run: No files would have been moved';
        break;
    }
    if (stripos($line_str, 'No files moved for this run') !== false) {
        $last_message_str = 'No files moved for this run';
        break;
    }
}

// ── Extract duration from last session block ──────────────────────────────────
$duration_str    = null;
$session_arr     = [];
$collecting_bool = false;

for ($i = count($last_run_lines_arr) - 1; $i >= 0; $i--) {
    $line_str = $last_run_lines_arr[$i];
    if (stripos($line_str, 'Session finished') !== false) {
        $collecting_bool = true;
    }
    if ($collecting_bool) {
        array_unshift($session_arr, $line_str);
        if (stripos($line_str, 'Session started') !== false) {
            break;
        }
    }
}

foreach ($session_arr as $line_str) {
    if (stripos($line_str, 'Duration:') === 0) {
        $duration_str = trim(substr($line_str, 9));
        break;
    }
}

if ($duration_str === null &&
    ($last_message_str === 'Dry run: No files would have been moved' ||
     $last_message_str === 'No files moved for this run')) {
    $duration_str = 'Nothing to track yet';
}

// ── Response ──────────────────────────────────────────────────────────────────
$log_text_str = count($matched_arr) > 0
    ? implode("\n", $matched_arr)
    : $last_message_str;

echo json_encode([
    'status'    => 'success',
    'timestamp' => date('Y-m-d H:i:s'),
    'data'      => [
        'log'      => $log_text_str,
        'moved'    => $moved_count_int,
        'duration' => $duration_str,
        'total'    => count($matched_arr),
    ],
]);
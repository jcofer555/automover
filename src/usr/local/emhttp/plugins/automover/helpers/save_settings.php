<?php
header('Content-Type: application/json');

// Path to your shell script
$cmd = '/usr/local/emhttp/plugins/automover/helpers/save_settings.sh';

// Grab arguments from query string
$args = [
    $_GET['POOL_NAME'] ?? '',
    $_GET['THRESHOLD'] ?? '',
    $_GET['DRY_RUN'] ?? '',
    $_GET['ALLOW_DURING_PARITY'] ?? '',
    $_GET['AUTOSTART'] ?? '',
    $_GET['AGE_BASED_FILTER'] ?? '',
    $_GET['AGE_DAYS'] ?? '',
    $_GET['SIZE_BASED_FILTER'] ?? '',
    $_GET['SIZE_MB'] ?? '',
    $_GET['EXCLUSIONS_ENABLED'] ?? '',
    $_GET['QBITTORRENT_SCRIPT'] ?? '',
    $_GET['QBITTORRENT_HOST'] ?? '',
    $_GET['QBITTORRENT_USERNAME'] ?? '',
    $_GET['QBITTORRENT_PASSWORD'] ?? '',
    $_GET['QBITTORRENT_DAYS_FROM'] ?? '',
    $_GET['QBITTORRENT_DAYS_TO'] ?? '',
    $_GET['QBITTORRENT_STATUS'] ?? '',
    $_GET['HIDDEN_FILTER'] ?? '',
    $_GET['FORCE_RECONSTRUCTIVE_WRITE'] ?? '',
    $_GET['CONTAINER_NAMES'] ?? '',
    $_GET['ENABLE_JDUPES'] ?? '',
    $_GET['HASH_PATH'] ?? '',
    $_GET['ENABLE_CLEANUP'] ?? '',
    $_GET['CRON_MODE'] ?? '',
    $_GET['MINUTES_FREQUENCY'] ?? '',
    $_GET['HOURLY_FREQUENCY'] ?? '',
    $_GET['DAILY_TIME'] ?? '',
    $_GET['WEEKLY_DAY'] ?? '',
    $_GET['WEEKLY_TIME'] ?? '',
    $_GET['MONTHLY_DAY'] ?? '',
    $_GET['MONTHLY_TIME'] ?? '',
    $_GET['CUSTOM_CRON'] ?? '',
    $_GET['CRON_EXPRESSION'] ?? '',
    $_GET['STOP_THRESHOLD'] ?? '',
    $_GET['ENABLE_NOTIFICATIONS'] ?? '',
    $_GET['WEBHOOK_URL'] ?? '',
    $_GET['MANUAL_MOVE'] ?? '',
    $_GET['STOP_ALL_CONTAINERS'] ?? '',
    $_GET['ENABLE_TRIM'] ?? '',
    $_GET['ENABLE_SCRIPTS'] ?? '',
    $_GET['PRE_SCRIPT'] ?? '',
    $_GET['POST_SCRIPT'] ?? '',
    $_GET['PRIORITIES'] ?? '',
    $_GET['PROCESS_PRIORITY'] ?? '',
    $_GET['IO_PRIORITY'] ?? '',
];

// Escape each argument for safety
$escapedArgs = array_map('escapeshellarg', $args);

// Build command string
$fullCmd = $cmd . ' ' . implode(' ', $escapedArgs);

// Set up I/O pipes for stdout and stderr
$process = proc_open($fullCmd, [
    1 => ['pipe', 'w'], // stdout
    2 => ['pipe', 'w']  // stderr
], $pipes);

// Handle output
if (is_resource($process)) {
    $output = stream_get_contents($pipes[1]);
    $error  = stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    proc_close($process);

    // If output is valid JSON, echo it — otherwise return error
    if (trim($output)) {
        echo $output;
    } else {
        echo json_encode(['status' => 'error', 'message' => trim($error) ?: 'No response from shell script']);
    }
} else {
    echo json_encode(['status' => 'error', 'message' => 'Failed to start process']);
}
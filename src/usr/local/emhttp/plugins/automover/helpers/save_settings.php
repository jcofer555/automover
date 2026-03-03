<?php

define('SAVE_SETTINGS_SCRIPT', '/usr/local/emhttp/plugins/automover/helpers/save_settings.sh');

// ------------------------------------------------------------------------------
// respond() — deterministic JSON response with explicit HTTP code, then exit
// ------------------------------------------------------------------------------
function respond(int $code, array $payload): void {
    http_response_code($code);
    header('Content-Type: application/json');
    echo json_encode($payload, JSON_UNESCAPED_SLASHES);
    exit;
}

// ------------------------------------------------------------------------------
// run_script() — guarded proc_open execution, explicit stdout/stderr handling
// ------------------------------------------------------------------------------
function run_script(string $cmd): void {
    $process = proc_open($cmd, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);

    if (!is_resource($process)) {
        respond(500, ['status' => 'error', 'message' => 'Failed to start process']);
    }

    $output = stream_get_contents($pipes[1]);
    $error  = stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    proc_close($process);

    $output = trim($output);
    $error  = trim($error);

    if ($output !== '') {
        header('Content-Type: application/json');
        echo $output;
        exit;
    }

    respond(500, ['status' => 'error', 'message' => $error !== '' ? $error : 'No response from shell script']);
}

// ------------------------------------------------------------------------------
// main() — explicit entrypoint, all state explicit, args alphabetized
// ------------------------------------------------------------------------------
function main(): void {
    if (!is_file(SAVE_SETTINGS_SCRIPT) || !is_executable(SAVE_SETTINGS_SCRIPT)) {
        respond(500, ['status' => 'error', 'message' => 'Save settings script missing or not executable']);
    }

    $args = [
        $_GET['AGE_BASED_FILTER']           ?? '',
        $_GET['AGE_DAYS']                   ?? '',
        $_GET['ALLOW_DURING_PARITY']        ?? '',
        $_GET['AUTOSTART']                  ?? '',
        $_GET['CONTAINER_NAMES']            ?? '',
        $_GET['CRON_EXPRESSION']            ?? '',
        $_GET['CRON_MODE']                  ?? '',
        $_GET['CUSTOM_CRON']                ?? '',
        $_GET['DAILY_TIME']                 ?? '',
        $_GET['DRY_RUN']                    ?? '',
        $_GET['ENABLE_CLEANUP']             ?? '',
        $_GET['ENABLE_JDUPES']              ?? '',
        $_GET['ENABLE_NOTIFICATIONS']       ?? '',
        $_GET['ENABLE_SCRIPTS']             ?? '',
        $_GET['ENABLE_TRIM']                ?? '',
        $_GET['EXCLUSIONS_ENABLED']         ?? '',
        $_GET['FORCE_RECONSTRUCTIVE_WRITE'] ?? '',
        $_GET['HASH_PATH']                  ?? '',
        $_GET['HIDDEN_FILTER']              ?? '',
        $_GET['HOURLY_FREQUENCY']           ?? '',
        $_GET['IO_PRIORITY']                ?? '',
        $_GET['MANUAL_MOVE']                ?? '',
        $_GET['MINUTES_FREQUENCY']          ?? '',
        $_GET['MONTHLY_DAY']                ?? '',
        $_GET['MONTHLY_TIME']               ?? '',
        $_GET['NOTIFICATION_SERVICE']       ?? '',
        $_GET['POOL_NAME']                  ?? '',
        $_GET['POST_SCRIPT']                ?? '',
        $_GET['PRE_SCRIPT']                 ?? '',
        $_GET['PRIORITIES']                 ?? '',
        $_GET['PROCESS_PRIORITY']           ?? '',
        $_GET['PUSHOVER_USER_KEY']          ?? '',
        $_GET['QBITTORRENT_DAYS_FROM']      ?? '',
        $_GET['QBITTORRENT_DAYS_TO']        ?? '',
        $_GET['QBITTORRENT_HOST']           ?? '',
        $_GET['QBITTORRENT_PASSWORD']       ?? '',
        $_GET['QBITTORRENT_SCRIPT']         ?? '',
        $_GET['QBITTORRENT_STATUS']         ?? '',
        $_GET['QBITTORRENT_USERNAME']       ?? '',
        $_GET['SIZE_BASED_FILTER']          ?? '',
        $_GET['SIZE_MB']                    ?? '',
        $_GET['STOP_ALL_CONTAINERS']        ?? '',
        $_GET['STOP_THRESHOLD']             ?? '',
        $_GET['THRESHOLD']                  ?? '',
        $_GET['WEBHOOK_DISCORD']            ?? '',
        $_GET['WEBHOOK_GOTIFY']             ?? '',
        $_GET['WEBHOOK_NTFY']               ?? '',
        $_GET['WEBHOOK_PUSHOVER']           ?? '',
        $_GET['WEBHOOK_SLACK']              ?? '',
        $_GET['WEEKLY_DAY']                 ?? '',
        $_GET['WEEKLY_TIME']                ?? '',
    ];

    $cmd = SAVE_SETTINGS_SCRIPT . ' ' . implode(' ', array_map('escapeshellarg', $args));

    run_script($cmd);
}

main();
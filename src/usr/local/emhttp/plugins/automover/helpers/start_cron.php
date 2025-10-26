<?php
$cfgPath  = '/boot/config/plugins/automover/settings.cfg';
$cronFile = '/boot/config/plugins/automover/automover.cron';

$response = ['status' => 'ok', 'messages' => []];

// === Handle cron update logic ===
$INTERVAL = isset($_GET['INTERVAL']) ? intval($_GET['INTERVAL']) : 60;

// Convert minutes → rounded cron schedule
if ($INTERVAL < 60) {
    // Every X minutes
    $minutes = max(1, $INTERVAL);
    $cronEntry = "*/{$minutes} * * * * /usr/local/emhttp/plugins/automover/helpers/automover.sh &> /dev/null 2>&1\n";
}
elseif ($INTERVAL < 1440) {
    // Round to nearest hour
    $hours = round($INTERVAL / 60);
    $hours = max(1, $hours);
    $cronEntry = "0 */{$hours} * * * /usr/local/emhttp/plugins/automover/helpers/automover.sh &> /dev/null 2>&1\n";
}
elseif ($INTERVAL < 10080) {
    // Round to nearest day
    $days = round($INTERVAL / 1440);
    $days = max(1, $days);
    $cronEntry = "0 0 */{$days} * * /usr/local/emhttp/plugins/automover/helpers/automover.sh &> /dev/null 2>&1\n";
}
elseif ($INTERVAL < 43200) {
    // Round to nearest week (7 days = 10080 minutes)
    $weeks = round($INTERVAL / 10080);
    $days = $weeks * 7;
    $days = max(7, $days);
    $cronEntry = "0 0 */{$days} * * /usr/local/emhttp/plugins/automover/helpers/automover.sh &> /dev/null 2>&1\n";
}
else {
    // Round to nearest month (30 days = 43200 minutes)
    $months = round($INTERVAL / 43200);
    $months = max(1, $months);
    $cronEntry = "0 0 1 */{$months} * /usr/local/emhttp/plugins/automover/helpers/automover.sh &> /dev/null 2>&1\n";
}

// === Write cron and apply ===
if (file_put_contents($cronFile, $cronEntry) === false) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => 'Failed to write cron file']);
    exit;
}

exec('update_cron');

// === Final response ===
header('Content-Type: application/json');
echo json_encode($response);

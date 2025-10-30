<?php
$cfgPath  = '/boot/config/plugins/automover/settings.cfg';
$cronFile = '/boot/config/plugins/automover/automover.cron';
$response = ['status' => 'ok'];

$MODE            = $_POST['MODE'] ?? 'minutes';
$INTERVAL        = intval($_POST['INTERVAL'] ?? 60);
$CRON_EXPRESSION = trim($_POST['CRON_EXPRESSION'] ?? '');

// Build cron entry depending on mode
if ($MODE === 'cron' && !empty($CRON_EXPRESSION)) {
    $cronEntry = "$CRON_EXPRESSION /usr/local/emhttp/plugins/automover/helpers/automover.sh &> /dev/null 2>&1\n";
} else {
    // Use your existing interval-to-cron conversion logic here
    if ($INTERVAL < 60) {
        $minutes = max(1, $INTERVAL);
        $cronEntry = "*/{$minutes} * * * * /usr/local/emhttp/plugins/automover/helpers/automover.sh &> /dev/null 2>&1\n";
    } elseif ($INTERVAL < 1440) {
        $hours = round($INTERVAL / 60);
        $hours = max(1, $hours);
        $cronEntry = "0 */{$hours} * * * /usr/local/emhttp/plugins/automover/helpers/automover.sh &> /dev/null 2>&1\n";
    } elseif ($INTERVAL < 10080) {
        $days = round($INTERVAL / 1440);
        $days = max(1, $days);
        $cronEntry = "0 0 */{$days} * * /usr/local/emhttp/plugins/automover/helpers/automover.sh &> /dev/null 2>&1\n";
    } elseif ($INTERVAL < 43200) {
        $weeks = round($INTERVAL / 10080);
        $days = $weeks * 7;
        $days = max(7, $days);
        $cronEntry = "0 0 */{$days} * * /usr/local/emhttp/plugins/automover/helpers/automover.sh &> /dev/null 2>&1\n";
    } else {
        $months = round($INTERVAL / 43200);
        $months = max(1, $months);
        $cronEntry = "0 0 1 */{$months} * /usr/local/emhttp/plugins/automover/helpers/automover.sh &> /dev/null 2>&1\n";
    }
}

// Write new cron and update system
if (file_put_contents($cronFile, $cronEntry) === false) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => 'Failed to write cron file']);
    exit;
}

exec('update_cron');

// Persist mode and values in settings.cfg
$settings = parse_ini_file($cfgPath) ?: [];
$settings['MODE'] = $MODE;
$settings['INTERVAL'] = $INTERVAL;
$settings['CRON_EXPRESSION'] = $CRON_EXPRESSION;
$cfgOut = '';
foreach ($settings as $k => $v) {
    $cfgOut .= "$k=\"$v\"\n";
}
file_put_contents($cfgPath, $cfgOut);

header('Content-Type: application/json');
echo json_encode($response);

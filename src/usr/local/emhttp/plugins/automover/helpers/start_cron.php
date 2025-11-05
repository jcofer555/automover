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
    // INTERVAL MODE: convert minutes to proper cron
    if ($INTERVAL < 60) {
        // every X minutes
        $minutes = max(1, $INTERVAL);
        $cronEntry = "*/{$minutes} * * * * /usr/local/emhttp/plugins/automover/helpers/automover.sh &> /dev/null 2>&1\n";
    } elseif ($INTERVAL < 1440) {
        // every X hours
        $hours = max(1, floor($INTERVAL / 60));
        $minute = $INTERVAL % 60;
        $cronEntry = sprintf("%d */%d * * * /usr/local/emhttp/plugins/automover/helpers/automover.sh &> /dev/null 2>&1\n", $minute, $hours);
    } elseif ($INTERVAL < 10080) {
        // every X days
        $days = max(1, floor($INTERVAL / 1440));
        $hour = floor(($INTERVAL % 1440) / 60);
        $minute = $INTERVAL % 60;
        $cronEntry = sprintf("%d %d */%d * * /usr/local/emhttp/plugins/automover/helpers/automover.sh &> /dev/null 2>&1\n", $minute, $hour, $days);
    } elseif ($INTERVAL < 43200) {
        // every X weeks (7-day multiples)
        $weeks = max(1, floor($INTERVAL / 10080));
        $day = 0; // Sunday
        $hour = floor(($INTERVAL % 1440) / 60);
        $minute = $INTERVAL % 60;
        $cronEntry = sprintf("%d %d * * %d /usr/local/emhttp/plugins/automover/helpers/automover.sh &> /dev/null 2>&1\n", $minute, $hour, $day);
    } else {
        // every X months (approx 30-day multiples)
        $months = max(1, floor($INTERVAL / 43200));
        $day = 1;
        $hour = 0;
        $minute = 0;
        $cronEntry = sprintf("%d %d %d */%d * /usr/local/emhttp/plugins/automover/helpers/automover.sh &> /dev/null 2>&1\n",
            $minute, $hour, $day, $months);
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

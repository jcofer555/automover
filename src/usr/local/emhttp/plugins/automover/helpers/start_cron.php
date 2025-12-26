<?php
$cfgPath  = '/boot/config/plugins/automover/settings.cfg';
$cronFile = '/boot/config/plugins/automover/automover.cron';
$response = ['status' => 'ok'];

// Grab all posted values
$CRON_MODE       = $_POST['CRON_MODE'] ?? 'minutes';
$MINUTES_FREQ    = intval($_POST['MINUTES_FREQUENCY'] ?? 30);
$HOURLY_FREQ     = $_POST['HOURLY_FREQUENCY'] ?? '';
$DAILY_TIME      = $_POST['DAILY_TIME'] ?? '';
$WEEKLY_DAY      = $_POST['WEEKLY_DAY'] ?? '';
$WEEKLY_TIME     = $_POST['WEEKLY_TIME'] ?? '';
$MONTHLY_DAY     = $_POST['MONTHLY_DAY'] ?? '';
$MONTHLY_TIME    = $_POST['MONTHLY_TIME'] ?? '';
$CUSTOM_CRON     = $_POST['CUSTOM_CRON'] ?? '';
$CRON_EXPRESSION = trim($_POST['CRON_EXPRESSION'] ?? '');

// Build cron entry directly from CRON_EXPRESSION
if (!empty($CRON_EXPRESSION)) {
    $cronEntry = "$CRON_EXPRESSION /usr/local/emhttp/plugins/automover/helpers/automover.sh &> /dev/null 2>&1\n";
} else {
    http_response_code(400);
    echo json_encode(['status' => 'error', 'message' => 'Missing cron expression']);
    exit;
}

// Write new cron and update system
if (file_put_contents($cronFile, $cronEntry) === false) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => 'Failed to write cron file']);
    exit;
}
exec('update_cron');

// Persist values in settings.cfg
$settings = parse_ini_file($cfgPath) ?: [];

// Merge all posted keys into settings
foreach ($_POST as $key => $val) {
    $settings[$key] = $val;
}

// Ensure scheduling fields are set explicitly
$settings['CRON_MODE']         = $CRON_MODE;
$settings['MINUTES_FREQUENCY'] = $MINUTES_FREQ;
$settings['HOURLY_FREQUENCY']  = $HOURLY_FREQ;
$settings['DAILY_TIME']        = $DAILY_TIME;
$settings['WEEKLY_DAY']        = $WEEKLY_DAY;
$settings['WEEKLY_TIME']       = $WEEKLY_TIME;
$settings['MONTHLY_DAY']       = $MONTHLY_DAY;
$settings['MONTHLY_TIME']      = $MONTHLY_TIME;
$settings['CUSTOM_CRON']       = $CUSTOM_CRON;
$settings['CRON_EXPRESSION']   = $CRON_EXPRESSION;

// Rebuild config text
$cfgOut = '';
foreach ($settings as $k => $v) {
    $cfgOut .= "$k=\"$v\"\n";
}
file_put_contents($cfgPath, $cfgOut);

header('Content-Type: application/json');
echo json_encode($response);

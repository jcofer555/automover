<?php
$cfgPath  = '/boot/config/plugins/automover/settings.cfg';
$cronFile = '/boot/config/plugins/automover/automover.cron';

$response = [ 'status' => 'ok', 'messages' => [] ];

// === Handle cron update logic ===
$INTERVAL = isset($_GET['INTERVAL']) ? intval($_GET['INTERVAL']) : 60;
$cronEntry = "*/{$INTERVAL} * * * * /usr/local/emhttp/plugins/automover/helpers/automover.sh &> /dev/null 2>&1\n";

if (file_put_contents($cronFile, $cronEntry) === false) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => 'Failed to write cron file']);
    exit;
}

exec('update_cron');

// === Final response ===
header('Content-Type: application/json');
echo json_encode($response);

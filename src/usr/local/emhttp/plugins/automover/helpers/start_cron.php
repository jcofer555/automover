<?php
$cronFile = '/boot/config/plugins/automover/automover.cron';
$INTERVAL = isset($_GET['INTERVAL']) ? intval($_GET['INTERVAL']) : 60;

// ✅ Build cron string
$cronEntry = "*/{$INTERVAL} * * * * /usr/local/emhttp/plugins/automover/helpers/automover.sh &> /dev/null 2>&1\n";

// ✅ Write to cron file
if (file_put_contents($cronFile, $cronEntry) === false) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => 'Failed to write cron file']);
    exit;
}

// ✅ Trigger cron reload
exec('update_cron');

// ✅ Response
header('Content-Type: application/json');
echo json_encode(['status' => 'ok', 'message' => 'Cron updated']);
?>

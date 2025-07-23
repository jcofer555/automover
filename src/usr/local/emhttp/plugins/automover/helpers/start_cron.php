<?php
$cronFile = '/boot/config/plugins/automover/automover.cron';
$interval = isset($_GET['interval']) ? intval($_GET['interval']) : 5; // Default to every 5 minutes

// ✅ Build cron string
$cronEntry = "*/{$interval} * * * * /usr/local/emhttp/plugins/automover/helpers/automover.sh &> /dev/null 2>&1\n";

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

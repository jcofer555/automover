<?php
$cfgPath    = '/boot/config/plugins/automover/settings.cfg';
$cronFile   = '/boot/config/plugins/automover/automover.cron';
$moverPath  = '/usr/local/sbin/mover';
$moverBackup = '/usr/local/sbin/mover.automover';
$moverOld   = '/usr/local/sbin/mover.old';

$settings = parse_ini_file($cfgPath) ?: [];
$disableSchedule = ($settings['DISABLE_UNRAID_MOVER_SCHEDULE'] ?? 'no') === 'yes';
$INTERVAL = isset($_GET['INTERVAL']) ? intval($_GET['INTERVAL']) : 60;

$response = [ 'status' => 'ok', 'messages' => [] ];

// === Handle mover schedule logic ===
if ($disableSchedule) {
    if (file_exists($moverOld)) {
        $response['messages'][] = '⚠️ Schedule remains enabled due to Mover Tuning plugin.';
    } else {
        if (file_exists($moverPath)) {
            unlink($moverPath);
        }
        file_put_contents($moverPath, "");
        chmod($moverPath, 0755);
        $response['messages'][] = 'Mover schedule disabled.';
    }
} else {
    if (!file_exists($moverOld)) {
        if (file_exists($moverPath)) {
            unlink($moverPath);
        }
        if (file_exists($moverBackup)) {
            copy($moverBackup, $moverPath);
            chmod($moverPath, 0755);
            $response['messages'][] = 'Mover schedule restored.';
        }
    } else {
        $response['messages'][] = 'Schedule cannot be disabled because mover tuning plugin is installed.';
    }
}

// === Handle cron update logic ===
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
?>

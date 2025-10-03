<?php
$cfgPath = '/boot/config/plugins/automover/settings.cfg';
$settings = parse_ini_file($cfgPath) ?: [];

$response = [ 'status' => 'ok', 'message' => '' ];

$moverPath   = '/usr/local/sbin/mover';
$moverBackup = '/usr/local/sbin/mover.automover';
$moverOld    = '/usr/local/sbin/mover.old';

$disableSchedule = ($settings['DISABLE_UNRAID_MOVER_SCHEDULE'] ?? 'no') === 'yes';

if ($disableSchedule) {
    // === DISABLE schedule ===
    if (file_exists($moverOld)) {
        // Mover Tuning controls schedule → leave everything untouched
        $response['message'] = '⚠️ Schedule will still be enabled due to Mover Tuning being installed.';
    } else {
        if (file_exists($moverPath)) {
            unlink($moverPath);
        }
        // Create empty stub
        file_put_contents($moverPath, "");
        chmod($moverPath, 0755);
    }
} else {
    // === ENABLE schedule ===
    if (file_exists($moverOld)) {
        // Mover Tuning controls → do nothing
    } else {
        if (file_exists($moverPath)) {
            unlink($moverPath);
        }
        if (file_exists($moverBackup)) {
            copy($moverBackup, $moverPath);
            chmod($moverPath, 0755);
        }
    }
}

header('Content-Type: application/json');
echo json_encode($response);

<?php
$cfgPath     = '/boot/config/plugins/automover/settings.cfg';
$cronFile    = '/boot/config/plugins/automover/automover.cron';
$moverPath   = '/usr/local/sbin/mover';
$moverBackup = '/usr/local/sbin/mover.automover';
$moverOld    = '/usr/local/sbin/mover.old';
$minSize     = 4096; // 4KB

$settings = parse_ini_file($cfgPath) ?: [];
$disableSchedule = ($settings['DISABLE_UNRAID_MOVER_SCHEDULE'] ?? 'no') === 'yes';

$response = [ 'status' => 'ok', 'messages' => [], 'flag_changed' => false ];

if ($disableSchedule) {
    // === When DISABLE_UNRAID_MOVER_SCHEDULE = "yes" ===
    if (file_exists($moverPath)) {
        $size = filesize($moverPath);
        if ($size >= $minSize) {
            // Backup and truncate mover
            if (@copy($moverPath, $moverBackup)) {
                @chmod($moverBackup, 0755);
                file_put_contents($moverPath, '');
            } else {
                $response['messages'][] = '⚠️ Failed to back up mover.';
                $settings['DISABLE_UNRAID_MOVER_SCHEDULE'] = 'no';
                $response['flag_changed'] = true;
                $configText = '';
                foreach ($settings as $key => $value) {
                    $configText .= "$key=\"$value\"\n";
                }
                file_put_contents($cfgPath, $configText);
            }
        } else {
            // Too small — do not copy or delete, revert flag to "no"
            $response['messages'][] = '⚠️ The mover file is not the right size so schedule was not disabled.';
            $settings['DISABLE_UNRAID_MOVER_SCHEDULE'] = 'no';
            $response['flag_changed'] = true;
            $configText = '';
            foreach ($settings as $key => $value) {
                $configText .= "$key=\"$value\"\n";
            }
            file_put_contents($cfgPath, $configText);
        }
    } else {
        // Mover missing — warn only, revert flag to "no"
        $response['messages'][] = '⚠️ Mover file not found, you\'ll need to reboot unraid to fix mover and then re-enable this setting.';
        $settings['DISABLE_UNRAID_MOVER_SCHEDULE'] = 'no';
        $response['flag_changed'] = true;
        $configText = '';
        foreach ($settings as $key => $value) {
            $configText .= "$key=\"$value\"\n";
        }
        file_put_contents($cfgPath, $configText);
    }

} else {
    // === When DISABLE_UNRAID_MOVER_SCHEDULE = "no" ===
    if (file_exists($moverBackup)) {
        $size = filesize($moverBackup);
        if ($size >= $minSize) {
            if (file_exists($moverPath)) {
                @unlink($moverPath);
            }
            if (@copy($moverBackup, $moverPath)) {
                @chmod($moverPath, 0755);
                @unlink($moverBackup); // delete backup after restore
            } else {
                $response['messages'][] = '⚠️ Failed to restore mover file.';
            }
        } else {
            $response['messages'][] = '⚠️ The mover.automover file is not the right size so schedule was not restored.';
        }
    } else {
        // === Fallback integrity check when mover.automover doesn't exist ===
        if (file_exists($moverPath)) {
            $size = filesize($moverPath);
            if ($size < $minSize) {
                if (!file_exists($moverOld)) {
                    $response['messages'][] = '⚠️ Mover file is not the right size, you\'ll need to reboot unraid to fix mover.';
                }
                // else: mover.old exists, do nothing
            }
            // else: mover ≥ 4KB, do nothing
        }
        // else: mover doesn't exist, silently skip
    }
}

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
?>

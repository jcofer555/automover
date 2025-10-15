<?php
$cfgPath      = '/boot/config/plugins/automover/settings.cfg';
$cronFile     = '/boot/config/plugins/automover/automover.cron';
$moverPath    = '/usr/local/sbin/mover';
$moverBackup  = '/usr/local/sbin/mover.automover';
$moverOld     = '/usr/local/sbin/mover.old';

$settings = parse_ini_file($cfgPath) ?: [];
$disableSchedule = ($settings['DISABLE_UNRAID_MOVER_SCHEDULE'] ?? 'no') === 'yes';
$INTERVAL = isset($_GET['INTERVAL']) ? intval($_GET['INTERVAL']) : 60;

$response = [ 'status' => 'ok', 'messages' => [] ];
$minSize = 4096; // 4KB

// === Handle mover schedule logic ===
if ($disableSchedule) {
    if (file_exists($moverOld)) {
        $size = filesize($moverOld);
        if ($size >= $minSize) {
            file_put_contents($moverBackup, "");
            copy($moverOld, $moverBackup);
            chmod($moverBackup, 0755);
            $response['messages'][] = '⚠️ Schedule cannot be disabled because mover tuning plugin is installed.';
        } else {
            $response['messages'][] = '⚠️ The mover file is not the right size so schedule was not disabled.';
        }
    } else {
        if (file_exists($moverPath)) {
            $size = filesize($moverPath);
            if ($size >= $minSize) {
                file_put_contents($moverBackup, "");
                copy($moverPath, $moverBackup);
                chmod($moverBackup, 0755);
            } else {
                $response['messages'][] = '⚠️ The mover file is not the right size so schedule was not disabled.';
            }
        } else {
            $response['messages'][] = '⚠️ Mover file not found, schedule was not disabled.';
        }
    }
} else {
    if (file_exists($moverOld)) {
        if (file_exists($moverBackup)) {
            $size = filesize($moverBackup);
            if ($size >= $minSize) {
                unlink($moverOld);
                copy($moverBackup, $moverOld);
                chmod($moverOld, 0755);
            } else {
                $response['messages'][] = '⚠️ The mover.automover file is not the right size so schedule was not restored.';
            }
        }
    } else {
        if (file_exists($moverBackup)) {
            $size = filesize($moverBackup);
            if ($size >= $minSize) {
                if (file_exists($moverPath)) {
                    unlink($moverPath);
                }
                copy($moverBackup, $moverPath);
                chmod($moverPath, 0755);
            } else {
                $response['messages'][] = '⚠️ The mover.automover file is not the right size so schedule was not restored.';
            }
        }
        // If mover.automover doesn't exist, do nothing silently
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

<?php
$cronFile   = '/boot/config/plugins/automover/automover.cron';
$logFile    = '/var/log/automover_last_run.log';
$bootFail   = '/var/tmp/automover_boot_failure';

$status     = 'Stopped';
$lastRun    = 'Cannot find last run';
$lastRunTs  = '';

// ✅ Autostart failure override
if (file_exists($bootFail)) {
    $status    = 'Autostart Failed';
    $lastRun   = trim(file_get_contents($bootFail));
    $lastRunTs = '';
} else {
    // ✅ Extract most recent valid timestamp
    if (file_exists($logFile)) {
        $lines = array_reverse(file($logFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES));
        foreach ($lines as $line) {
            if (preg_match('/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/', $line, $match)) {
                $lastRunTs = $match[0];
                break;
            }
        }
    }

    // ✅ Automover status from cron
    if (file_exists($cronFile) && strpos(file_get_contents($cronFile), 'automover.sh') !== false) {
        $status = 'Running';
    }

    // ✅ Parity check override
    if (file_exists('/var/local/emhttp/var.ini') && preg_match('/mdResync="([1-9][0-9]*)"/', file_get_contents('/var/local/emhttp/var.ini'))) {
        $status = 'Parity Check Running';
    }

    // ✅ Compute readable time difference
    if ($lastRunTs) {
        $lastTs = strtotime($lastRunTs);
        if ($lastTs) {
            $nowTs = time();
            $diff = $nowTs - $lastTs;

            if ($diff < 10) {
                $lastRun = "just now";
            } elseif ($diff < 60) {
                $lastRun = "$diff seconds ago";
            } elseif ($diff < 3600) {
                $min = floor($diff / 60);
                $lastRun = "$min minute" . ($min !== 1 ? "s" : "") . " ago";
            } elseif ($diff < 86400) {
                $hrs = floor($diff / 3600);
                $lastRun = "$hrs hour" . ($hrs !== 1 ? "s" : "") . " ago";
            } elseif ($diff < 604800) {
                $days = floor($diff / 86400);
                $lastRun = "$days day" . ($days !== 1 ? "s" : "") . " ago";
            } elseif ($diff < 2592000) {
                $weeks = floor($diff / 604800);
                $lastRun = "over $weeks week" . ($weeks !== 1 ? "s" : "") . " ago";
            } elseif ($diff < 7776000) {
                $months = floor($diff / 2592000);
                $lastRun = "over $months month" . ($months !== 1 ? "s" : "") . " ago";
            } else {
                $lastRun = "on " . date('M d, Y h:i A', $lastTs);
            }
        }
    }
}

// ✅ Output JSON
header('Content-Type: application/json');
echo json_encode([
    'status'       => $status,
    'last_run'     => $lastRun,
    'last_run_ts'  => $lastRunTs
]);
?>

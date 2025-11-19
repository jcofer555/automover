<?php
header("Content-Type: application/json");

$lock   = "/tmp/automover/automover_lock.txt";
$last   = "/tmp/automover/automover_last_run.log";
$status = "/tmp/automover/automover_status.txt";

$automover_log      = "/tmp/automover/automover_files_moved.log";
$automover_log_prev = "/tmp/automover/automover_files_moved_prev.log";

// ==============================
// CSRF VALIDATION
// ==============================
$cookie = $_COOKIE['csrf_token'] ?? '';
$posted = $_POST['csrf_token'] ?? '';

if ($_SERVER['REQUEST_METHOD'] !== 'POST' || !hash_equals($cookie, $posted)) {
    echo json_encode(["ok" => false, "error" => "Invalid CSRF token"]);
    exit;
}

// ==========================================================
// Prevent collision with Automover
// ==========================================================
if (file_exists($lock)) {
    $pid = trim(file_get_contents($lock));
    if ($pid && posix_kill((int)$pid, 0)) {
        echo json_encode(["ok" => false, "error" => "Automover already running"]);
        exit;
    }
}

// Acquire lock
file_put_contents($lock, getmypid());
file_put_contents($status, "Manual Rsync Running");

// ==========================================================
// Load settings.cfg (matches automover.sh)
// ==========================================================
$cfg_file = "/boot/config/plugins/automover/settings.cfg";
$settings = [];

if (file_exists($cfg_file)) {
    foreach (file($cfg_file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        if (strpos($line, "=") !== false) {
            list($key, $val) = array_map('trim', explode("=", $line, 2));
            $settings[$key] = trim($val, "\"");
        }
    }
}

// ==========================================================
// Notification configuration (MIRROR automover.sh behavior)
// ==========================================================
$WEBHOOK_URL = "";
if (isset($settings["WEBHOOK_URL"])) {
    $tmp = trim($settings["WEBHOOK_URL"]);
    if ($tmp !== "" && strtolower($tmp) !== "null") {
        $WEBHOOK_URL = $tmp;
    }
}

$ENABLE_NOTIFICATIONS = (
    isset($settings["ENABLE_NOTIFICATIONS"]) &&
    strtolower(trim($settings["ENABLE_NOTIFICATIONS"])) === "yes"
);

$DRY_RUN = (
    isset($settings["DRY_RUN"]) &&
    strtolower(trim($settings["DRY_RUN"])) === "yes"
);

$isDry  = $DRY_RUN;
$notify = $ENABLE_NOTIFICATIONS;

// ==========================================================
// Inputs
// ==========================================================
$src_raw = rtrim($_POST["source"] ?? "", "/");
$dst_raw = rtrim($_POST["dest"] ?? "", "/");

$copy = $_POST["copy"] ?? "0";
$del  = $_POST["delete"] ?? "0";
$full = $_POST["fullsync"] ?? "0";

$src_clean = $src_raw . "/";
$dst_clean = $dst_raw . "/";

$src = escapeshellarg($src_clean);
$dst = escapeshellarg($dst_clean);

// ==========================================================
// Determine rsync mode
// ==========================================================
if ($full === "1") {
    $cmd = "rsync -aH --delete --out-format='%n' $src_clean $dst_clean";
    $modeName = "full sync";
} elseif ($del === "1") {
    $cmd = "rsync -aH --remove-source-files --out-format='%n' $src_clean $dst_clean";
    $modeName = "delete source";
} else {
    $cmd = "rsync -aH --out-format='%n' $src_clean $dst_clean";
    $modeName = "copy";
}

// ==========================================================
// Dry run handling
// ==========================================================
if ($isDry) {
    if (strpos($cmd, "rsync ") === 0) {
        $cmd = "rsync --dry-run " . substr($cmd, strlen("rsync "));
    }
    $modeName .= " (dry run)";
}

// ==========================================================
// Write header to last_run_file
// ==========================================================
file_put_contents($last,
    "------------------------------------------------\n" .
    "Automover session started - " . date("Y-m-d H:i:s") . "\n" .
    "Manually rsyncing $src_clean -> $dst_clean using mode: $modeName\n",
    FILE_APPEND
);

if ($isDry) {
    file_put_contents($last, "Dry run active - no files will be moved\n", FILE_APPEND);
}

$start_time = time();

// ==========================================================
// START Notification
// ==========================================================
if ($notify) {
    if (!empty($WEBHOOK_URL)) {
        $json = json_encode([
            "embeds" => [[
                "title" => "Manual rsync started",
                "description" => "Manual rsync has started.\n$src_clean → $dst_clean",
                "color" => 16776960
            ]]
        ]);
        exec("curl -s -X POST -H 'Content-Type: application/json' -d '$json' \"$WEBHOOK_URL\" >/dev/null 2>&1");
    } else {
        exec("/usr/local/emhttp/webGui/scripts/notify -e 'Automover' -s 'Manual rsync started' -d 'Manual rsync operation has started' -i 'normal'");
    }
}

// ==========================================================
// Clear mover log
// ==========================================================
if (file_exists($automover_log)) {
    unlink($automover_log);
}

// ==========================================================
// CLEAR IN-USE FILE LIST EACH RUN
// ==========================================================
$inuse_file = "/tmp/automover/automover_in_use_files.txt";
file_put_contents($inuse_file, "");
$inuse_count = 0;

// ==========================================================
// RUN RSYNC WITH AUTOMOVER fuser CHECK
// ==========================================================

// Build list of files to check
$files = [];
exec("find " . escapeshellarg($src_clean) . " -type f 2>/dev/null", $files);

$output = [];

foreach ($files as $file) {

    if (trim($file) === "") continue;

    // Check if file is in use
    $fuser_output = shell_exec("fuser -m " . escapeshellarg($file) . " 2>/dev/null");
    if (!empty($fuser_output)) {
        file_put_contents($inuse_file, "$file\n", FILE_APPEND);
        $inuse_count++;
        continue;
    }

    // Run rsync on the file
    $safe_file = escapeshellarg($file);
    $single_cmd = "rsync -aH --out-format='%n' $safe_file " . escapeshellarg($dst_clean);
    if ($isDry) {
        $single_cmd = "rsync --dry-run -aH --out-format='%n' $safe_file " . escapeshellarg($dst_clean);
    }

    exec("$single_cmd 2>&1", $output);
}

// Log summary of in-use files
if ($inuse_count > 0) {
    file_put_contents($last, "Skipped $inuse_count in-use file(s)\n", FILE_APPEND);
}

// ==========================================================
// Parse moved files
// ==========================================================
$moved_any = false;
$shareCounts = [];

foreach ($output as $line) {
    $line = trim($line);
    if ($line === "") continue;

    if (
        $line === "sending incremental file list" ||
        preg_match('/^(sent|total|bytes|speedup|created|deleting)/i', $line)
    ) {
        continue;
    }

    $moved_any = true;

    $src_file = $src_clean . $line;
    $dst_file = $dst_clean . $line;

    file_put_contents($automover_log, "$src_file -> $dst_file\n", FILE_APPEND);

    $parts = explode("/", trim($dst_file, "/"));
    if (count($parts) >= 3 && $parts[1] === "user0") {
        $share = $parts[2];
        if (!isset($shareCounts[$share])) $shareCounts[$share] = 0;
        $shareCounts[$share]++;
    }
}

// ==========================================================
// Handle no-files-moved
// ==========================================================
if (!$moved_any) {
    file_put_contents($automover_log, "No files moved for this manual move\n", FILE_APPEND);
} else {
    copy($automover_log, $automover_log_prev);
}

// ==========================================================
// FINISH Notification
// ==========================================================
$end_time = time();
$duration = $end_time - $start_time;

if ($duration < 60) {
    $runtime = "{$duration}s";
} elseif ($duration < 3600) {
    $runtime = floor($duration / 60) . "m " . ($duration % 60) . "s";
} else {
    $runtime = floor($duration / 3600) . "h " . floor(($duration % 3600) / 60) . "m";
}

if ($notify) {

    if (!empty($WEBHOOK_URL)) {

        $body = "Manual rsync finished.\nMoved: " . ($moved_any ? "Yes" : "No") . "\nRuntime: $runtime";

        if ($moved_any && !empty($shareCounts)) {
            $body .= "\n\nPer share summary:";
            foreach ($shareCounts as $share => $count) {
                $body .= "\n• $share: $count file(s)";
            }
        }

        $json = json_encode([
            "embeds" => [[
                "title" => "Manual rsync finished",
                "description" => $body,
                "color" => 65280
            ]]
        ]);

        exec("curl -s -X POST -H 'Content-Type: application/json' -d '$json' \"$WEBHOOK_URL\" >/dev/null 2>&1");

    } else {

        $notif_cfg = "/boot/config/plugins/dynamix/dynamix.cfg";
        $agent_active = false;

        if (file_exists($notif_cfg)) {
            $normal_val = trim(shell_exec("grep -Po 'normal=\"\\K[0-9]+' $notif_cfg 2>/dev/null"));
            if (preg_match('/^(4|5|6|7)$/', $normal_val)) {
                $agent_active = true;
            } elseif ($normal_val === "0") {
                file_put_contents($last, "Unraid's notice notifications are disabled at Settings > Notifications\n", FILE_APPEND);
            }
        }

        $body = "Manual rsync finished. Runtime: $runtime.";

        if ($moved_any && !empty($shareCounts)) {

            if ($agent_active) {
                $body .= " - Per share summary: ";
                $first = true;
                foreach ($shareCounts as $share => $count) {
                    if ($first) {
                        $body .= "$share: $count file(s)";
                        $first = false;
                    } else {
                        $body .= " - $share: $count file(s)";
                    }
                }
            } else {
                $body .= "<br><br>Per share summary:<br>";
                foreach ($shareCounts as $share => $count) {
                    $body .= "• $share: $count file(s)<br>";
                }
            }
        }

        $body_escaped = escapeshellarg($body);

        $cmd = "/usr/local/emhttp/webGui/scripts/notify -e 'Automover' -s 'Manual rsync finished' -d $body_escaped -i 'normal'";
        exec("echo \"$cmd\" | at now + 1 minute");
    }
}

// ==========================================================
// Footer
// ==========================================================
file_put_contents($last,
    "Automover session finished - " . date("Y-m-d H:i:s") . "\n\n",
    FILE_APPEND
);

// ==========================================================
// Cleanup
// ==========================================================
unlink($lock);
file_put_contents($status, "Stopped");

echo json_encode(["ok" => true]);
?>

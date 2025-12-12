<?php
header("Content-Type: application/json");

$lock   = "/tmp/automover/automover_lock.txt";
$last   = "/tmp/automover/automover_last_run.log";
$status = "/tmp/automover/temp_logs/automover_status.txt";

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
$automover_running = false;
if (file_exists($lock)) {
    $pid = intval(trim(file_get_contents($lock)));
    if ($pid > 0 && posix_kill($pid, 0)) {
        $automover_running = true;
    } else {
        @unlink($lock);
    }
}
if ($automover_running) {
    echo json_encode(["ok" => false, "error" => "Automover already running"]);
    exit;
}

file_put_contents($lock, getmypid());
file_put_contents($status, "Manual Rsync Starting");
usleep(150000);
file_put_contents($status, "Manual Rsync Running");

// ==========================================================
// Load settings.cfg
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
// Flags from settings
// ==========================================================
$WEBHOOK_URL = "";
if (!empty($settings["WEBHOOK_URL"]) && strtolower(trim($settings["WEBHOOK_URL"])) !== "null") {
    $WEBHOOK_URL = trim($settings["WEBHOOK_URL"]);
}
$ENABLE_NOTIFICATIONS = (
    isset($settings["ENABLE_NOTIFICATIONS"]) &&
    strtolower(trim($settings["ENABLE_NOTIFICATIONS"])) === "yes"
);
$DRY_RUN = (
    isset($settings["DRY_RUN"]) &&
    strtolower(trim($settings["DRY_RUN"])) === "yes"
);
$ENABLE_CLEANUP = (
    isset($settings["ENABLE_CLEANUP"]) &&
    strtolower(trim($settings["ENABLE_CLEANUP"])) === "yes"
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

// ==========================================================
// Ensure destination exists with correct ownership
// ==========================================================
if (!is_dir($dst_clean)) {
    mkdir($dst_clean, 0777, true);
    $parent = dirname(rtrim($dst_clean, "/"));
    $parent_stat = @stat($parent);
    if ($parent_stat) {
        if (function_exists('posix_getpwuid')) {
            $pw = @posix_getpwuid($parent_stat['uid']);
            if (!empty($pw['name'])) {
                @chown($dst_clean, $pw['name']);
            }
        }
        if (function_exists('posix_getgrgid')) {
            $gr = @posix_getgrgid($parent_stat['gid']);
            if (!empty($gr['name'])) {
                @chgrp($dst_clean, $gr['name']);
            }
        }
    }
}

// ==========================================================
// Mode name (for logging)
// ==========================================================
if ($full === "1") {
    $modeName = "full sync";
} elseif ($del === "1") {
    $modeName = "delete source after";
} else {
    $modeName = "copy";
}
if ($isDry) {
    $modeName .= " (dry run)";
}

// ==========================================================
// Write header to last run log
// ==========================================================
file_put_contents(
    $last,
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
// Prepare logs
// ==========================================================
if (file_exists($automover_log)) {
    unlink($automover_log);
}

$inuse_file   = "/tmp/automover/automover_in_use_files.txt";
$exclude_file = "/tmp/automover/automover_manual_rsync_in_use_files.txt";

// Reset both files each run
file_put_contents($inuse_file, "");
file_put_contents($exclude_file, "");
$inuse_count = 0;

// ==========================================================
// RUN RSYNC
// ==========================================================
$output = [];
$moved_any = false;
$shareCounts = [];

if ($full === "1") {
    $exclude_file = "/tmp/automover/automover_manual_rsync_in_use_files.txt";
    $files_in_use = [];
    $all_files = [];

    exec("find " . escapeshellarg($src_clean) . " -type f 2>/dev/null", $all_files);

    foreach ($all_files as $file) {
        $fuser_output = shell_exec("fuser -m " . escapeshellarg($file) . " 2>/dev/null");
        if (!empty($fuser_output)) {
            $rel = substr($file, strlen($src_clean)); // relative path
            $files_in_use[] = $rel;
            file_put_contents($inuse_file, "$file\n", FILE_APPEND);
            $inuse_count++;
        }
    }

    $exclude_opt = "";
    if (!empty($files_in_use)) {
        file_put_contents($exclude_file, implode("\n", $files_in_use) . "\n");
        $exclude_opt = " --exclude-from=" . escapeshellarg($exclude_file);
    }

    // Ensure trailing slashes once, not re-assigned
    $src_clean = rtrim($src_raw, "/") . "/";
    $dst_clean = rtrim($dst_raw, "/") . "/";

    $cmd = $isDry
        ? "rsync --dry-run -aH --delete --out-format='%n'" . $exclude_opt . " " . escapeshellarg($src_clean) . " " . escapeshellarg($dst_clean)
        : "rsync -aH --delete --out-format='%n'" . $exclude_opt . " " . escapeshellarg($src_clean) . " " . escapeshellarg($dst_clean);

    exec("$cmd 2>&1", $output);

    if ($inuse_count > 0) {
        file_put_contents($last, "Skipped $inuse_count in-use file(s)\n", FILE_APPEND);
    }

} else {
    // Copy or delete mode: per-file loop
    $files = [];
    exec("find " . escapeshellarg($src_clean) . " -type f 2>/dev/null", $files);

    foreach ($files as $file) {
        if (trim($file) === "") continue;

        $fuser_output = shell_exec("fuser -m " . escapeshellarg($file) . " 2>/dev/null");
        if (!empty($fuser_output)) {
            file_put_contents($inuse_file, "$file\n", FILE_APPEND);
            $inuse_count++;
            continue;
        }

        $deleteFlag = ($del === "1") ? "--remove-source-files" : "";
        $safe_file = escapeshellarg($file);
        $single_cmd = $isDry
            ? "rsync --dry-run -aH $deleteFlag --out-format='%n' $safe_file " . escapeshellarg($dst_clean)
            : "rsync -aH $deleteFlag --out-format='%n' $safe_file " . escapeshellarg($dst_clean);

        exec("$single_cmd 2>&1", $output);
    }

    if ($inuse_count > 0) {
        file_put_contents($last, "Skipped $inuse_count in-use file(s)\n", FILE_APPEND);
    }
}

// ==========================================================
// Parse moved files
// ==========================================================
foreach ($output as $line) {
    $line = trim($line);
    if ($line === "") continue;
    if (preg_match('/^(sending incremental|sent|total|bytes|speedup|created|deleting)/i', $line)) {
        continue;
    }
    $moved_any = true;
    $src_file = $src_clean . $line;
    $dst_file = $dst_clean . $line;
    file_put_contents($automover_log, "$src_file -> $dst_file\n", FILE_APPEND);

    $parts = explode("/", trim($dst_file, "/"));
    if (count($parts) >= 3 && $parts[1] === "user0") {
        $share = $parts[2];
        $shareCounts[$share] = ($shareCounts[$share] ?? 0) + 1;
    }
}
if (!$moved_any) {
    file_put_contents($automover_log, "No files moved for this manual move\n", FILE_APPEND);
} else {
    copy($automover_log, $automover_log_prev);
}

// ==========================================================
// Cleanup empty directories if delete mode AND enabled
// ==========================================================
if ($del === "1" && !$isDry && $ENABLE_CLEANUP) {
    exec("find " . escapeshellarg($src_clean) . " -type d -empty -delete 2>/dev/null");
    file_put_contents($last, "Cleaned up empty directories from source\n", FILE_APPEND);
}

// ==========================================================
// FINISH Notification
// ==========================================================
$end_time = time();
$duration = $end_time - $start_time;

if ($duration < 60) {
    $runtime = $duration . "s";
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
        // Unraid Notification System
        $notif_cfg = "/boot/config/plugins/dynamix/dynamix.cfg";
        $agent_active = false;

        if (file_exists($notif_cfg)) {
            $normal_val = trim(shell_exec("grep -Po 'normal=\"\\K[0-9]+' $notif_cfg 2>/dev/null"));
            if (preg_match('/^(4|5|6|7)$/', $normal_val)) {
                $agent_active = true;
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
        exec("echo " . escapeshellarg($cmd) . " | at now + 1 minute");
    }
}

// ==========================================================
// Footer log
// ==========================================================
file_put_contents($last,
    "Automover session finished - " . date("Y-m-d H:i:s") . "\n\n",
    FILE_APPEND
);

// ==========================================================
// Cleanup
// ==========================================================
@unlink($lock);
file_put_contents($status, "Stopped");

echo json_encode(["ok" => true]);
?>

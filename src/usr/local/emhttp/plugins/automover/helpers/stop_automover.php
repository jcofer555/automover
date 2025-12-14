<?php
header("Content-Type: application/json");

$lock      = "/tmp/automover/lock.txt";
$status    = "/tmp/automover/temp_logs/status.txt";
$last      = "/tmp/automover/last_run.log";

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
// Set status to stopping
// ==========================================================
file_put_contents($status, "Stopping Automover…");

// ==========================================================
// Kill automover shell scripts and rsync operations
// ==========================================================

// Kill any automover.sh loops
exec("pkill -f 'automover.sh' 2>/dev/null");

// Kill any rsync processes started by automover
exec("pkill -f 'rsync -aH' 2>/dev/null");
exec("pkill -f 'rsync --dry-run' 2>/dev/null");

// Kill any find/fuser processes Automover may have spawned
exec("pkill -f 'fuser -m' 2>/dev/null");
exec("pkill -f 'find .*automover' 2>/dev/null");

// ==========================================================
// Kill process referenced by lock file (if alive)
// ==========================================================
if (file_exists($lock)) {
    $pid = intval(trim(file_get_contents($lock)));

    if ($pid > 0) {
        // If process is alive, kill it
        if (posix_kill($pid, 0)) {
            posix_kill($pid, SIGTERM);
            usleep(200000); // give it 0.2 sec to clean up
        }
    }

    @unlink($lock);
}

// ==========================================================
// Reset status file so WebUI sees everything stopped
// ==========================================================
file_put_contents($status, "Stopped");

// ==========================================================
// Success
// ==========================================================
echo json_encode(["ok" => true]);
?>

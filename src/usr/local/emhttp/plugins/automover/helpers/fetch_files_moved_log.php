<?php
$logFile = '/var/log/automover_files_moved.log';
$lastRunLog = '/var/log/automover_last_run.log';

$keyword = isset($_GET['filter']) ? strtolower(trim($_GET['filter'])) : null;

$lines = file_exists($logFile)
    ? file($logFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES)
    : [];

$matched = [];
$movedCount = 0;

// 🔍 Filter and count moved lines
foreach ($lines as $line) {
    $lower = strtolower($line);

    // Apply keyword filter if set
    if ($keyword && strpos($lower, $keyword) === false) {
        continue;
    }

    // Count every remaining line as a moved file
    $movedCount++;
    $matched[] = $line;
}

// 🔍 Check lastRunLog for dry run or no-op messages
$lastMessage = "No files moved for this run";

if (file_exists($lastRunLog)) {
    $lastRunLines = array_reverse(file($lastRunLog, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES));

    foreach ($lastRunLines as $line) {
        if (stripos($line, 'Dry run: No files would have been moved') !== false) {
            $lastMessage = 'Dry run: No files would have been moved';
            break;
        }
        if (stripos($line, 'No files moved for this run') !== false) {
            $lastMessage = 'No files moved for this run';
            break;
        }
    }
}

// ✅ Final log text
$logText = count($matched) > 0
    ? implode("\n", $matched)
    : $lastMessage;

// ⏱ Extract most recent duration
$duration = null;

if (file_exists($lastRunLog)) {
    foreach ($lastRunLines as $line) {
        if (stripos($line, 'Duration:') === 0) {
            $duration = trim(substr($line, 9));
            break;
        }
    }

    // Override duration if no files were moved
    if ($lastMessage === 'Dry run: No files would have been moved' || $lastMessage === 'No files moved for this run') {
        $duration = 'Nothing to track yet';
    }
}

header('Content-Type: application/json');
echo json_encode([
    'log' => $logText,
    'moved' => $movedCount,
    'duration' => $duration,
    'total' => count($matched)
]);

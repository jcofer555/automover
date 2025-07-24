<?php
$logFile = '/var/log/automover_files_moved.log';
$lastRunLog = '/var/log/automover_last_run.log';

$keyword = isset($_GET['filter']) ? strtolower(trim($_GET['filter'])) : null;

$lines = file_exists($logFile)
    ? file($logFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES)
    : [];

$matched = [];
$movedCount = 0;
$skippedCount = 0;

// ⏱ Parse start and end from the last run log
$start = $end = null;
if (file_exists($lastRunLog)) {
    $lastRunLines = file($lastRunLog, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);

    foreach ($lastRunLines as $line) {
        if (stripos($line, 'Automover session started -') === 0) {
            $start = trim(substr($line, 26)); // Extract timestamp
        }
        if (stripos($line, 'Automover session finished -') === 0) {
            $end = trim(substr($line, 27)); // Extract timestamp
        }
    }
}

// ⏱️ Compute duration
$duration = null;
if ($start && $end) {
    $startTime = strtotime($start);
    $endTime = strtotime($end);
    if ($startTime && $endTime && $endTime >= $startTime) {
        $duration = ($endTime - $startTime) . 's';
    }
}

foreach ($lines as $line) {
    $lower = strtolower($line);

    if ($lower === 'mover: started' || $lower === 'mover: finished') {
        continue;
    }

    if ($keyword && strpos($lower, $keyword) === false) {
        continue;
    }

    if (stripos($line, 'move:') === 0 && stripos($line, 'Success') !== false) {
        $movedCount++;
    }

    if (stripos($line, 'move:') === 0 && stripos($line, 'Skipped') !== false) {
        $skippedCount++;
    }

    $matched[] = $line;
}

$logText = count($matched) > 0
    ? implode("\n", $matched)
    : "No files moved for this run.";

header('Content-Type: application/json');
echo json_encode([
    'log' => $logText,
    'moved' => $movedCount,
    'skipped' => $skippedCount,
    'duration' => $duration,
    'total' => count($matched)
]);

<?php
$logFile = '/var/log/automover_files_moved.log';
$lastRunLog = '/var/log/automover_last_run.log';

$keyword = isset($_GET['filter']) ? strtolower(trim($_GET['filter'])) : null;

$lines = file_exists($logFile)
    ? file($logFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES)
    : [];

$matched = [];
$movedCount = 0;

// 🔍 Filter and count moved lines (excluding summary messages)
foreach ($lines as $line) {
    $lower = strtolower($line);

    if ($keyword && strpos($lower, $keyword) === false) {
        continue;
    }

    if (
        strpos($lower, 'no files moved for this run') !== false ||
        strpos($lower, 'dry run: no files would have been moved') !== false
    ) {
        continue;
    }

    $movedCount++;
    $matched[] = $line;
}

// 🔍 Check lastRunLog for dry run or no-op messages
$lastMessage = "No files moved for this run";

$lastRunLines = file_exists($lastRunLog)
    ? file($lastRunLog, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES)
    : [];

foreach (array_reverse($lastRunLines) as $line) {
    if (stripos($line, 'Dry run: No files would have been moved') !== false) {
        $lastMessage = 'Dry run: No files would have been moved';
        break;
    }
    if (stripos($line, 'No files moved for this run') !== false) {
        $lastMessage = 'No files moved for this run';
        break;
    }
}

// ✅ Final log text
$logText = count($matched) > 0
    ? implode("\n", $matched)
    : $lastMessage;

// ⏱ Extract duration from the last session block
$duration = null;
$sessionBlock = [];
$collecting = false;

for ($i = count($lastRunLines) - 1; $i >= 0; $i--) {
    $line = $lastRunLines[$i];

    if (stripos($line, 'Automover session finished') !== false) {
        $collecting = true;
    }

    if ($collecting) {
        array_unshift($sessionBlock, $line);
        if (stripos($line, 'Automover session started') !== false) {
            break; // full session block captured
        }
    }
}

foreach ($sessionBlock as $line) {
    if (stripos($line, 'Duration:') === 0) {
        $duration = trim(substr($line, 9));
        break;
    }
}

// ✅ Only override if duration is truly missing
if (
    $duration === null &&
    ($lastMessage === 'Dry run: No files would have been moved' || $lastMessage === 'No files moved for this run')
) {
    $duration = 'Nothing to track yet';
}

header('Content-Type: application/json');
echo json_encode([
    'log' => $logText,
    'moved' => $movedCount,
    'duration' => $duration,
    'total' => count($matched)
]);

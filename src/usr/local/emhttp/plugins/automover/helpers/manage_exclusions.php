<?php
header('Content-Type: application/json');

$file = '/boot/config/plugins/automover/exclusions.txt';
$action = $_GET['action'] ?? '';

function ensure_file($f) {
    if (!file_exists(dirname($f))) @mkdir(dirname($f), 0777, true);
    if (!file_exists($f)) @file_put_contents($f, "");
    return file_exists($f);
}

if ($action === 'get') {
    ensure_file($file);
    $content = @file_get_contents($file);
    if ($content === false) {
        echo json_encode(['ok' => false, 'error' => 'Could not read exclusions.txt']);
        exit;
    }
    echo json_encode(['ok' => true, 'content' => $content]);
    exit;
}

if ($action === 'save') {
    ensure_file($file);
    $data = $_POST['content'] ?? '';
    $lines = preg_split('/\r\n|\r|\n/', $data);
    $lines = array_values(array_filter(array_map('trim', $lines), fn($l) => $l !== ''));
    $result = @file_put_contents($file, implode("\n", $lines) . "\n");

    if ($result === false) {
        echo json_encode(['ok' => false, 'error' => 'Failed to write exclusions.txt']);
        exit;
    }

    echo json_encode(['ok' => true, 'message' => 'Saved successfully']);
    exit;
}

echo json_encode(['ok' => false, 'error' => 'Invalid action']);

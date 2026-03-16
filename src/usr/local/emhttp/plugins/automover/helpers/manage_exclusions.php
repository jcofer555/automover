<?php
declare(strict_types=1);

// ── Constants ─────────────────────────────────────────────────────────────────
const EXCLUSIONS_FILE = '/boot/config/plugins/automover/exclusions.txt';

// ── Utilities ─────────────────────────────────────────────────────────────────
function ensure_file(string $path_str): bool {
    $dir_str = dirname($path_str);
    if (!is_dir($dir_str)) {
        @mkdir($dir_str, 0777, true);
    }
    if (!file_exists($path_str)) {
        @file_put_contents($path_str, '');
    }
    return file_exists($path_str);
}

// ── Entry point ───────────────────────────────────────────────────────────────
header('Content-Type: application/json');

$action_str = $_GET['action'] ?? '';

// ── Get ───────────────────────────────────────────────────────────────────────
if ($action_str === 'get') {
    ensure_file(EXCLUSIONS_FILE);
    $content_str = @file_get_contents(EXCLUSIONS_FILE);
    if ($content_str === false) {
        echo json_encode(['ok' => false, 'error' => 'Could not read exclusions.txt']);
        exit;
    }
    echo json_encode([
        'status'    => 'success',
        'timestamp' => date('Y-m-d H:i:s'),
        'data'      => [
            'ok'      => true,
            'content' => $content_str,
        ],
    ]);
    exit;
}

// ── Save ──────────────────────────────────────────────────────────────────────
if ($action_str === 'save') {
    ensure_file(EXCLUSIONS_FILE);
    $raw_str    = $_POST['content'] ?? '';
    $lines_arr  = preg_split('/\r\n|\r|\n/', $raw_str);
    $clean_arr  = array_values(array_filter(array_map('trim', $lines_arr), fn($l) => $l !== ''));
    $result_int = @file_put_contents(EXCLUSIONS_FILE, implode("\n", $clean_arr) . "\n");

    if ($result_int === false) {
        echo json_encode(['ok' => false, 'error' => 'Failed to write exclusions.txt']);
        exit;
    }
    echo json_encode([
        'status'    => 'success',
        'timestamp' => date('Y-m-d H:i:s'),
        'data'      => [
            'ok'      => true,
            'message' => 'Saved successfully',
        ],
    ]);
    exit;
}

// ── Invalid action ────────────────────────────────────────────────────────────
echo json_encode(['ok' => false, 'error' => 'Invalid action']);
<?php
declare(strict_types=1);

// ── Constants ─────────────────────────────────────────────────────────────────
const DEFAULT_PATH = '/mnt';

// ── Entry point ───────────────────────────────────────────────────────────────
header('Content-Type: application/json');

// ── Input ─────────────────────────────────────────────────────────────────────
$path_str = $_GET['path'] ?? DEFAULT_PATH;
if (!is_dir($path_str)) {
    $path_str = DEFAULT_PATH;
}

// ── Core logic ────────────────────────────────────────────────────────────────
$dirs_arr  = [];
$files_arr = [];

foreach (scandir($path_str) as $entry_str) {
    if ($entry_str === '.' || $entry_str === '..') continue;

    $full_path_str = $path_str . '/' . $entry_str;

    if (is_dir($full_path_str)) {
        $dirs_arr[]  = ['name' => $entry_str, 'type' => 'dir'];
    } else {
        $files_arr[] = ['name' => $entry_str, 'type' => 'file'];
    }
}

usort($dirs_arr,  fn($a, $b) => strcasecmp($a['name'], $b['name']));
usort($files_arr, fn($a, $b) => strcasecmp($a['name'], $b['name']));

// ── Response ──────────────────────────────────────────────────────────────────
echo json_encode([
    'status'    => 'success',
    'timestamp' => date('Y-m-d H:i:s'),
    'data'      => [
        'path'    => $path_str,
        'entries' => array_merge($dirs_arr, $files_arr),
    ],
]);
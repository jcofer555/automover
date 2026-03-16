<?php
declare(strict_types=1);

// ── Entry point ───────────────────────────────────────────────────────────────
header('Content-Type: application/json');

// ── Input ─────────────────────────────────────────────────────────────────────
$parent_str = rtrim($_POST['parent'] ?? '', '/');
$name_str   = $_POST['name']        ?? '';

// ── Validation ────────────────────────────────────────────────────────────────
if ($parent_str === '' || $name_str === '') {
    echo json_encode(['ok' => false, 'error' => 'Missing parent or name']);
    exit;
}

if (!is_dir($parent_str)) {
    echo json_encode(['ok' => false, 'error' => 'Parent does not exist']);
    exit;
}

$new_path_str = $parent_str . '/' . $name_str;

if (file_exists($new_path_str)) {
    echo json_encode(['ok' => false, 'error' => 'Folder already exists']);
    exit;
}

// ── Core logic ────────────────────────────────────────────────────────────────
$stat_arr  = stat($parent_str);
$mode_int  = $stat_arr['mode'] & 0777;
$uid_int   = $stat_arr['uid'];
$gid_int   = $stat_arr['gid'];

if (!mkdir($new_path_str, $mode_int, true)) {
    echo json_encode(['ok' => false, 'error' => 'Failed to create folder']);
    exit;
}

chown($new_path_str, $uid_int);
chgrp($new_path_str, $gid_int);
chmod($new_path_str, $mode_int);

echo json_encode([
    'status'    => 'success',
    'timestamp' => date('Y-m-d H:i:s'),
    'data'      => [
        'ok'   => true,
        'path' => $new_path_str,
    ],
]);
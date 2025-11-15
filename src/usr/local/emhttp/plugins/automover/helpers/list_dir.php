<?php
header('Content-Type: application/json');

$path = $_GET['path'] ?? '/mnt';
if (!is_dir($path)) $path = '/mnt';

$dirs = [];
$files = [];

foreach (scandir($path) as $e) {
    if ($e === '.' || $e === '..') continue;

    $full = "$path/$e";

    if (is_dir($full)) {
        $dirs[] = ['name' => $e, 'type' => 'dir'];
    } else {
        $files[] = ['name' => $e, 'type' => 'file'];
    }
}

usort($dirs, function($a, $b) {
    return strcasecmp($a['name'], $b['name']);
});
usort($files, function($a, $b) {
    return strcasecmp($a['name'], $b['name']);
});

echo json_encode(['entries' => array_merge($dirs, $files)]);

<?php
header('Content-Type: application/json');

$action = $_GET['action'] ?? '';
$EXC_FILE = '/boot/config/plugins/automover/exclusions.txt';
$HIDE_MNT = ['user', 'user0', 'addons', 'remotes', 'disks', 'rootshare'];

// --- Utility Functions ---
function ensure_exclusions_file($file) {
    if (!file_exists(dirname($file))) @mkdir(dirname($file), 0777, true);
    if (!file_exists($file)) @file_put_contents($file, "");
    return file_exists($file);
}

function read_lines($file) {
    if (!file_exists($file)) return [];
    $lines = file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
    return array_values(array_filter(array_map('trim', $lines), fn($l) => $l !== ''));
}

function write_lines($file, $lines) {
    $unique = array_values(array_unique($lines));
    @file_put_contents($file, implode("\n", $unique) . (count($unique) ? "\n" : ""));
    return true;
}

// --- Actions ---
if ($action === 'list_dir') {
    $path = $_GET['path'] ?? '/mnt';
    if (!str_starts_with($path, '/mnt')) $path = '/mnt';
    $items = [];

    $output = [];
    @exec('ls -1A ' . escapeshellarg($path), $output);
    foreach ($output as $entry) {
        if ($path === '/mnt' && in_array($entry, $HIDE_MNT, true)) continue;
        $full = rtrim($path,'/') . '/' . $entry;
        $isDir = is_dir($full);
        $items[] = ['name'=>$entry, 'path'=>$full, 'isDir'=>$isDir];
    }

    usort($items, function($a,$b){
        return $a['isDir'] === $b['isDir'] ? strcasecmp($a['name'],$b['name']) : ($a['isDir'] ? -1 : 1);
    });

    echo json_encode(['ok'=>true,'path'=>$path,'items'=>$items]);
    exit;
}

// --- ADD EXCLUSIONS ---
if ($action === 'add_exclusions') {
    $paths = $_POST['paths'] ?? [];

    // Normalize any /mnt/diskX/... → /mnt/user0/...
    $normalized = [];
    foreach ($paths as $p) {
        if (preg_match('#^/mnt/disk[0-9]+/#', $p)) {
            $p = preg_replace('#^/mnt/disk[0-9]+/#', '/mnt/user0/', $p);
        }
        $normalized[] = $p;
    }
    $paths = $normalized;

    ensure_exclusions_file($EXC_FILE);
    $current = read_lines($EXC_FILE);

    foreach ($paths as $p) {
        $p = trim($p);
        if ($p === '') continue;
        if (!in_array($p, $current, true)) $current[] = $p;
    }

    write_lines($EXC_FILE, $current);
    echo json_encode(['ok'=>true,'count'=>count($current)]);
    exit;
}

// --- REMOVE EXCLUSIONS ---
if ($action === 'remove_exclusions') {
    $paths = $_POST['paths'] ?? [];

    // Normalize any /mnt/diskX/... → /mnt/user0/...
    $normalized = [];
    foreach ($paths as $p) {
        if (preg_match('#^/mnt/disk[0-9]+/#', $p)) {
            $p = preg_replace('#^/mnt/disk[0-9]+/#', '/mnt/user0/', $p);
        }
        $normalized[] = $p;
    }
    $paths = $normalized;

    ensure_exclusions_file($EXC_FILE);
    $current = read_lines($EXC_FILE);

    $remaining = array_values(array_filter($current, fn($l) => !in_array($l, $paths, true)));
    write_lines($EXC_FILE, $remaining);
    echo json_encode(['ok'=>true,'count'=>count($remaining)]);
    exit;
}

// --- GET COUNT ---
if ($action === 'get_exclusion_count') {
    ensure_exclusions_file($EXC_FILE);
    $count = count(read_lines($EXC_FILE));
    echo json_encode(['ok'=>true,'count'=>$count]);
    exit;
}

// --- ENSURE FILE EXISTS ---
if ($action === 'ensure_exclusions') {
    $ok = ensure_exclusions_file($EXC_FILE);
    echo json_encode(['ok'=>$ok]);
    exit;
}

echo json_encode(['ok'=>false,'error'=>'Unknown action']);

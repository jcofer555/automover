<?php
declare(strict_types=1);

// ── Constants ─────────────────────────────────────────────────────────────────
const EXCLUSIONS_FILE = '/boot/config/plugins/automover/exclusions.txt';
const HIDE_MNT_ARR    = ['user', 'user0', 'addons', 'remotes', 'disks', 'rootshare'];

// ── Utilities ─────────────────────────────────────────────────────────────────
function ensure_exclusions_file(string $path_str): bool {
    $dir_str = dirname($path_str);
    if (!is_dir($dir_str)) @mkdir($dir_str, 0777, true);
    if (!file_exists($path_str)) @file_put_contents($path_str, '');
    return file_exists($path_str);
}

function read_lines(string $path_str): array {
    if (!file_exists($path_str)) return [];
    $lines_arr = file($path_str, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
    return array_values(array_filter(array_map('trim', $lines_arr), fn($l) => $l !== ''));
}

function write_lines(string $path_str, array $lines_arr): void {
    $unique_arr = array_values(array_unique($lines_arr));
    @file_put_contents($path_str, implode("\n", $unique_arr) . (count($unique_arr) ? "\n" : ''));
}

function normalize_paths(array $paths_arr): array {
    return array_map(function(string $p_str): string {
        if (preg_match('#^/mnt/disk[0-9]+/#', $p_str)) {
            return preg_replace('#^/mnt/disk[0-9]+/#', '/mnt/user0/', $p_str);
        }
        return $p_str;
    }, $paths_arr);
}

// ── Entry point ───────────────────────────────────────────────────────────────
header('Content-Type: application/json');

$action_str = $_GET['action'] ?? '';

// ── List directory ────────────────────────────────────────────────────────────
if ($action_str === 'list_dir') {
    $path_str = $_GET['path'] ?? '/mnt';
    if (!str_starts_with($path_str, '/mnt')) $path_str = '/mnt';

    $entries_arr = [];
    $ls_arr      = [];
    @exec('ls -1A ' . escapeshellarg($path_str), $ls_arr);

    foreach ($ls_arr as $entry_str) {
        if ($path_str === '/mnt' && in_array($entry_str, HIDE_MNT_ARR, true)) continue;
        $full_str    = rtrim($path_str, '/') . '/' . $entry_str;
        $is_dir_bool = is_dir($full_str);
        $entries_arr[] = ['name' => $entry_str, 'path' => $full_str, 'isDir' => $is_dir_bool];
    }

    usort($entries_arr, fn($a, $b) =>
        $a['isDir'] === $b['isDir']
            ? strcasecmp($a['name'], $b['name'])
            : ($a['isDir'] ? -1 : 1)
    );

    echo json_encode([
        'status'    => 'success',
        'timestamp' => date('Y-m-d H:i:s'),
        'data'      => ['ok' => true, 'path' => $path_str, 'items' => $entries_arr],
    ]);
    exit;
}

// ── Add exclusions ────────────────────────────────────────────────────────────
if ($action_str === 'add_exclusions') {
    $paths_arr   = normalize_paths($_POST['paths'] ?? []);
    ensure_exclusions_file(EXCLUSIONS_FILE);
    $current_arr = read_lines(EXCLUSIONS_FILE);

    foreach ($paths_arr as $p_str) {
        $p_str = trim($p_str);
        if ($p_str === '' || in_array($p_str, $current_arr, true)) continue;
        $current_arr[] = $p_str;
    }

    write_lines(EXCLUSIONS_FILE, $current_arr);

    echo json_encode([
        'status'    => 'success',
        'timestamp' => date('Y-m-d H:i:s'),
        'data'      => ['ok' => true, 'count' => count($current_arr)],
    ]);
    exit;
}

// ── Remove exclusions ─────────────────────────────────────────────────────────
if ($action_str === 'remove_exclusions') {
    $paths_arr   = normalize_paths($_POST['paths'] ?? []);
    ensure_exclusions_file(EXCLUSIONS_FILE);
    $current_arr = read_lines(EXCLUSIONS_FILE);

    $remaining_arr = array_values(array_filter($current_arr, fn($l) => !in_array($l, $paths_arr, true)));
    write_lines(EXCLUSIONS_FILE, $remaining_arr);

    echo json_encode([
        'status'    => 'success',
        'timestamp' => date('Y-m-d H:i:s'),
        'data'      => ['ok' => true, 'count' => count($remaining_arr)],
    ]);
    exit;
}

// ── Get exclusion count ───────────────────────────────────────────────────────
if ($action_str === 'get_exclusion_count') {
    ensure_exclusions_file(EXCLUSIONS_FILE);
    $count_int = count(read_lines(EXCLUSIONS_FILE));

    echo json_encode([
        'status'    => 'success',
        'timestamp' => date('Y-m-d H:i:s'),
        'data'      => ['ok' => true, 'count' => $count_int],
    ]);
    exit;
}

// ── Ensure file exists ────────────────────────────────────────────────────────
if ($action_str === 'ensure_exclusions') {
    $ok_bool = ensure_exclusions_file(EXCLUSIONS_FILE);

    echo json_encode([
        'status'    => 'success',
        'timestamp' => date('Y-m-d H:i:s'),
        'data'      => ['ok' => $ok_bool],
    ]);
    exit;
}

// ── Unknown action ────────────────────────────────────────────────────────────
echo json_encode(['ok' => false, 'error' => 'Unknown action']);
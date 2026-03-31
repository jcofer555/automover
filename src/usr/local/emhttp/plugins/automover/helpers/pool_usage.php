<?php
declare(strict_types=1);

// ── Constants ─────────────────────────────────────────────────────────────────
const DISKS_INI      = '/var/local/emhttp/disks.ini';
const SKIP_NAMES_ARR = ['parity', 'parity2', 'flash'];

// ── Utilities ─────────────────────────────────────────────────────────────────
function get_zfs_usage(): array {
    $zfs_usage_arr = [];
    $raw_str = (string) shell_exec('zpool list -H -o name,cap 2>/dev/null');
    foreach (explode("\n", trim($raw_str)) as $line_str) {
        $line_str = trim($line_str);
        if ($line_str === '') continue;
        $parts_arr = preg_split('/\s+/', $line_str);
        if (count($parts_arr) < 2) continue;
        $zfs_usage_arr[$parts_arr[0]] = rtrim($parts_arr[1], '%');
    }
    return $zfs_usage_arr;
}

function get_df_usage(string $mount_str): string {
    $raw_str = (string) shell_exec('df --output=pcent ' . escapeshellarg($mount_str) . ' 2>/dev/null | tail -1');
    $val_str = trim(str_replace(['%', ' '], '', $raw_str));
    return $val_str !== '' ? $val_str : 'N/A';
}

// ── Entry point ───────────────────────────────────────────────────────────────
header('Content-Type: application/json');

$disk_data_arr = @parse_ini_file(DISKS_INI, true) ?: [];
$zfs_usage_arr = get_zfs_usage();
$result_arr    = [];

foreach ($disk_data_arr as $disk_arr) {
    if (!isset($disk_arr['name'])) continue;

    $name_str = $disk_arr['name'];

    if (in_array($name_str, SKIP_NAMES_ARR, true)) continue;
    if (strpos($name_str, 'disk') === 0)             continue;

    $mount_str = '/mnt/' . $name_str;

    $result_arr[$name_str] = array_key_exists($name_str, $zfs_usage_arr)
        ? $zfs_usage_arr[$name_str]
        : get_df_usage($mount_str);
}

echo json_encode([
    'status'    => 'success',
    'timestamp' => date('Y-m-d H:i:s'),
    'data'      => $result_arr,
]);
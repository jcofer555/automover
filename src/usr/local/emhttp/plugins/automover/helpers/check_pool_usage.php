<?php
declare(strict_types=1);

// ── Constants ─────────────────────────────────────────────────────────────────
const SHARES_CFG_DIR = '/boot/config/shares';

// ── Entry point ───────────────────────────────────────────────────────────────
header('Content-Type: application/json');

$pool_str    = $_GET['pool'] ?? '';
$in_use_bool = false;
$shares_arr  = [];

if ($pool_str !== '' && is_dir(SHARES_CFG_DIR)) {
    foreach (glob(SHARES_CFG_DIR . '/*.cfg') as $file_str) {
        $cfg_arr = parse_ini_file($file_str);
        if (!$cfg_arr) continue;

        $use_cache_str  = strtolower($cfg_arr['shareUseCache']  ?? '');
        $cache_pool1_str = $cfg_arr['shareCachePool']  ?? '';
        $cache_pool2_str = $cfg_arr['shareCachePool2'] ?? '';

        $pool_matches_bool = ($cache_pool1_str === $pool_str || $cache_pool2_str === $pool_str);
        $cache_active_bool = ($use_cache_str === 'yes' || $use_cache_str === 'prefer');

        if ($pool_matches_bool && $cache_active_bool) {
            $in_use_bool  = true;
            $shares_arr[] = basename($file_str, '.cfg');
        }
    }
}

echo json_encode([
    'status'    => 'success',
    'timestamp' => date('Y-m-d H:i:s'),
    'data'      => [
        'pool'   => $pool_str,
        'in_use' => $in_use_bool,
        'shares' => $shares_arr,
    ],
]);
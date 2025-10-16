<?php
header('Content-Type: application/json');

$pool = $_GET['pool'] ?? '';
$result = ['pool' => $pool, 'in_use' => false, 'shares' => []];

if ($pool && is_dir('/boot/config/shares')) {
    foreach (glob("/boot/config/shares/*.cfg") as $file) {
        $cfg = parse_ini_file($file);
        if (!$cfg) continue;

        $useCache = strtolower($cfg['shareUseCache'] ?? '');
        $cachePool1 = $cfg['shareCachePool'] ?? '';
        $cachePool2 = $cfg['shareCachePool2'] ?? '';

        if (($cachePool1 === $pool || $cachePool2 === $pool) &&
            ($useCache === 'yes' || $useCache === 'prefer')) {
            $result['in_use'] = true;
            $result['shares'][] = basename($file, '.cfg');
        }
    }
}

echo json_encode($result);

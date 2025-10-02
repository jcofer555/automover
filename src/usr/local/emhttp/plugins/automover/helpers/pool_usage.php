<?php
// Return updated pool usage as JSON
$diskData = @parse_ini_file("/var/local/emhttp/disks.ini", true) ?: [];
$result = [];

// Get ZFS pool usage upfront
$zfsUsageRaw = shell_exec("zpool list -H -o name,cap");
$zfsUsage = [];
foreach (explode("\n", trim($zfsUsageRaw)) as $line) {
    [$zfsName, $cap] = preg_split('/\s+/', $line);
    $zfsUsage[$zfsName] = rtrim($cap, '%');
}

foreach ($diskData as $disk) {
    if (!isset($disk['name'])) continue;
    $name = $disk['name'];
    if (in_array($name, ['parity', 'parity2', 'flash']) || strpos($name, 'disk') !== false) continue;

    $mountPoint = "/mnt/$name";

    // Check if this is a ZFS pool
    if (array_key_exists($name, $zfsUsage)) {
        $result[$name] = $zfsUsage[$name];
    } else {
        $usedPercent = trim(shell_exec("df --output=pcent $mountPoint | tail -1 | tr -d ' %\n'"));
        $result[$name] = $usedPercent ?: 'N/A';
    }
}

header('Content-Type: application/json');
echo json_encode($result);

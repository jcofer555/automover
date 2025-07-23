<?php
// Return updated pool usage as JSON
$diskData = @parse_ini_file("/var/local/emhttp/disks.ini", true) ?: [];
$result = [];

foreach ($diskData as $disk) {
    if (!isset($disk['name'])) continue;
    $name = $disk['name'];
    if (in_array($name, ['parity', 'parity2', 'flash']) || strpos($name, 'disk') !== false) continue;

    $mountPoint = "/mnt/$name";
    $usedPercent = trim(shell_exec("df --output=pcent $mountPoint | tail -1 | tr -d ' %\n'"));
    $result[$name] = $usedPercent ?: 'N/A';
}

header('Content-Type: application/json');
echo json_encode($result);

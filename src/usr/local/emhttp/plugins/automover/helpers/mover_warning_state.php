<?php
$flag = '/boot/config/plugins/automover/mover_warning_dismissed.txt';

if ($_SERVER['REQUEST_METHOD'] === 'GET') {
    echo json_encode(['dismissed' => file_exists($flag)]);
    exit;
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    file_put_contents($flag, 'dismissed');
    echo json_encode(['ok' => true]);
    exit;
}
?>

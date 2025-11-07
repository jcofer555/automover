<?php
header('Content-Type: application/json');
$lockFile = '/tmp/automover/automover_lock.txt';
echo json_encode(['locked' => file_exists($lockFile)]);

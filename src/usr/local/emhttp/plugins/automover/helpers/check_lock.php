<?php
header('Content-Type: application/json');
$lockFile = '/tmp/automover/lock.txt';
echo json_encode(['locked' => file_exists($lockFile)]);

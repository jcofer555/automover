<?php
header('Content-Type: application/json');
$lockFile = '/tmp/automover/automover.lock';
echo json_encode(['locked' => file_exists($lockFile)]);

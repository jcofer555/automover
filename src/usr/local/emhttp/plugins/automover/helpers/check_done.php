<?php
header('Content-Type: application/json');
$doneFile = '/tmp/automover/temp_logs/automover_done.txt';
echo json_encode(['done' => file_exists($doneFile)]);

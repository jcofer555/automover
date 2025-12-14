<?php
header('Content-Type: application/json');
$doneFile = '/tmp/automover/temp_logs/done.txt';
echo json_encode(['done' => file_exists($doneFile)]);

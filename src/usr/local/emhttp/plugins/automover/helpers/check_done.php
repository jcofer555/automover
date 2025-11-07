<?php
header('Content-Type: application/json');
$doneFile = '/tmp/automover/automover_done.txt';
echo json_encode(['done' => file_exists($doneFile)]);

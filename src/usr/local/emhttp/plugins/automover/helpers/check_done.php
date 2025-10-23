<?php
header('Content-Type: application/json');
$doneFile = '/tmp/automover/automover.done';
echo json_encode(['done' => file_exists($doneFile)]);

<?php
header("Content-Type: application/json");

$parent = $_POST["parent"] ?? "";
$name   = $_POST["name"] ?? "";
$csrf   = $_POST["csrf_token"] ?? "";

if ($parent === "" || $name === "") {
    echo json_encode(["ok" => false, "error" => "Missing parent or name"]);
    exit;
}

$parent = rtrim($parent, "/");
$newpath = $parent . "/" . $name;

// Must be directory
if (!is_dir($parent)) {
    echo json_encode(["ok" => false, "error" => "Parent does not exist"]);
    exit;
}

if (file_exists($newpath)) {
    echo json_encode(["ok" => false, "error" => "Folder already exists"]);
    exit;
}

// Get parent permissions + ownership
$stat = stat($parent);
$mode = $stat['mode'] & 0777;   // strip extra bits
$uid  = $stat['uid'];
$gid  = $stat['gid'];

// Create folder
if (!mkdir($newpath, $mode, true)) {
    echo json_encode(["ok" => false, "error" => "Failed to create folder"]);
    exit;
}

// Apply correct owner + permissions
chown($newpath, $uid);
chgrp($newpath, $gid);
chmod($newpath, $mode);

echo json_encode(["ok" => true, "path" => $newpath]);

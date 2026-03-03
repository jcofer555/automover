<?php
header('Content-Type: application/json');

$cronFile = '/boot/config/plugins/automover/automover.cron';

// Try to remove cron file
if (file_exists($cronFile)) {
    $result = @unlink($cronFile);

    if ($result) {
        exec("update_cron");
        echo json_encode([
            "status" => "success",
            "message" => "automover cron stopped"
        ]);
    } else {
        echo json_encode([
            "status" => "error",
            "message" => "Failed to remove cron file"
        ]);
    }
} else {
    echo json_encode([
        "status" => "success",
        "message" => "automover was already stopped"
    ]);
}
?>

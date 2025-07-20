<?php
$lastRunFile = "/boot/config/plugins/automover/automover_last_run.txt";
if (file_exists($lastRunFile)) {
    echo trim(file_get_contents($lastRunFile));
} else {
    echo "Never";
}
?>

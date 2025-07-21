<?php
$lastRunFile = "/var/log/automover_last_run.log";
if (file_exists($lastRunFile)) {
    echo trim(file_get_contents($lastRunFile));
} else {
    echo "Never";
}
?>

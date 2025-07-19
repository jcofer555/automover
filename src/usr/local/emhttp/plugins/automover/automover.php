<?php
$config_path = "/boot/config/plugins/automover/settings.cfg";
$trigger_log_path = "/boot/config/plugins/automover/last_triggered.log";
$log_path = "/var/log/automover.log";

// Check if Python is installed
$python_installed = shell_exec("command -v python3");
$python_missing = empty($python_installed);

// Parse disks.ini and filter pool disks
$disks_ini = parse_ini_file("/var/local/emhttp/disks.ini", true);
$pool_disks = [];
foreach ($disks_ini as $disk => $info) {
  if ($info['type'] !== 'Array') {
    $usage = isset($info['used'], $info['size']) && $info['size'] > 0
      ? number_format(($info['used'] / $info['size']) * 100, 1)
      : 'N/A';
    $pool_disks[$disk] = "$disk ({$usage}% used)";
  }
}

// Load config
$config = file_exists($config_path) ? parse_ini_file($config_path, true) : [];
$thresholds = $config['Thresholds'] ?? [];
$continuous = $config['Continuous'] ?? [];
$settings = $config['Settings'] ?? [];
$scan_interval = $settings['scan_interval'] ?? 60;
$dry_run = $settings['dry_run'] ?? 'no';
$mode = $settings['check_mode'] ?? 'realtime';
$cron_schedule = $settings['cron_schedule'] ?? '0 * * * *';
$last_triggered = file_exists($trigger_log_path) ? file_get_contents($trigger_log_path) : '—';

// Save form
if ($_SERVER['REQUEST_METHOD'] === 'POST' && !$python_missing) {
  $cfg = "[Thresholds]\n";
  foreach ($_POST['disks'] ?? [] as $disk) {
    $val = $_POST["threshold_$disk"] ?? 90;
    $cfg .= "$disk = $val\n";
  }
  $cfg .= "\n[Continuous]\n";
  foreach ($_POST['disks'] ?? [] as $disk) {
    $mode_val = $_POST["continuous_$disk"] ?? 'no';
    $cfg .= "$disk = $mode_val\n";
  }
  $cfg .= "\n[Settings]\n";
  $cfg .= "scan_interval = " . ($_POST['scan_interval'] ?? 60) . "\n";
  $cfg .= "dry_run = " . ($_POST['dry_run'] ?? 'no') . "\n";
  $cfg .= "check_mode = " . ($_POST['check_mode'] ?? 'realtime') . "\n";
  $cfg .= "cron_schedule = " . ($_POST['cron_schedule'] ?? '0 * * * *') . "\n";
  file_put_contents($config_path, $cfg);

  // Auto-register cron
  if ($_POST['check_mode'] === 'scheduled') {
    file_put_contents("/boot/config/plugins/automover/automover.cron", $_POST['cron_schedule'] . " /usr/local/bin/automover_monitor.sh\n");
    exec("update_cron");
  }

  echo "<div style='color:green; margin:10px 0;'>✅ Settings saved successfully.</div>";
}

// Tooltip styling + JS for disabling continuous toggles
echo <<<STYLE
<style>
  .tooltip { position: relative; cursor: help; }
  .tooltip .tooltiptext {
    visibility: hidden;
    background-color: #333;
    color: #fff;
    padding: 6px;
    border-radius: 4px;
    position: absolute;
    top: 100%; left: 0;
    white-space: nowrap;
    z-index: 2;
  }
  .tooltip:hover .tooltiptext { visibility: visible; }
</style>
<script>
function toggleContinuousLock() {
  const isScheduled = document.getElementById('check_mode').value === 'scheduled';
  document.querySelectorAll('.continuous-toggle').forEach(e => e.disabled = isScheduled);
}
window.onload = toggleContinuousLock;
</script>
STYLE;

// Python alert box
if ($python_missing) {
  echo <<<HTML
  <div style="background:#ffdddd; border:1px solid red; padding:10px; margin:10px 0;">
    ❌ <strong>Python3 is not installed.</strong><br>
    This plugin requires Python to function. Please install it via the
    <a href="https://forums.unraid.net/topic/175402-plugin-python-3-for-unraid-611/" target="_blank">Unraid Python plugin</a>
    or from <a href="https://www.python.org/downloads/" target="_blank">python.org</a>.
  </div>
  HTML;
}
?>

<form method="POST">
  <h3>🧩 Disk Selection</h3>
  <select name="disks[]" multiple size="5">
    <?php foreach ($pool_disks as $disk => $label): ?>
      <option value="<?= $disk ?>" <?= isset($thresholds[$disk]) ? "selected" : "" ?>><?= $label ?></option>
    <?php endforeach ?>
  </select>

  <?php foreach ($thresholds as $disk => $value): ?>
    <div style="margin-top:10px;">
      <label>📊 <?= $disk ?> Threshold (%):</label>
      <input type="number" name="threshold_<?= $disk ?>" value="<?= $value ?>" min="1" max="100">

      <div class="tooltip">
        <label>🔁 Continuous Scan:</label>
        <span class="tooltiptext">Enable auto-rechecking if threshold is exceeded</span>
      </div>
      <select name="continuous_<?= $disk ?>" class="continuous-toggle">
        <option value="yes" <?= ($continuous[$disk] ?? 'no') === 'yes' ? 'selected' : '' ?>>Yes</option>
        <option value="no" <?= ($continuous[$disk] ?? 'no') === 'no' ? 'selected' : '' ?>>No</option>
      </select>
    </div>
  <?php endforeach ?>

  <h3 style="margin-top:20px;">⚙️ Settings</h3>

  <div class="tooltip">
    <label>⏱️ Scan Interval (seconds):</label>
    <span class="tooltiptext">Time between checks during continuous scan</span>
  </div>
  <input type="number" name="scan_interval" value="<?= $scan_interval ?>" min="10">

  <div class="tooltip">
    <label>🧪 Dry Run Mode:</label>
    <span class="tooltiptext">Log activity without triggering the mover</span>
  </div>
  <select name="dry_run">
    <option value="no" <?= $dry_run === 'no' ? 'selected' : '' ?>>No</option>
    <option value="yes" <?= $dry_run === 'yes' ? 'selected' : '' ?>>Yes</option>
  </select>

  <div class="tooltip">
    <label>📈 Threshold Check Mode:</label>
    <span class="tooltiptext">Realtime = monitor now; Scheduled = monitor on schedule</span>
  </div>
  <select name="check_mode" id="check_mode" onchange="toggleContinuousLock()">
    <option value="realtime" <?= $mode === 'realtime' ? 'selected' : '' ?>>Realtime</option>
    <option value="scheduled" <?= $mode === 'scheduled' ? 'selected' : '' ?>>Scheduled</option>
  </select>

  <label>📅 Cron Expression:</label>
  <input type="text" id="cron_schedule" name="cron_schedule" value="<?= $cron_schedule ?>">
  <select onchange="document.getElementById('cron_schedule').value=this.value;">
    <option value="">— Common Schedules —</option>
    <option value="0 * * * *">Hourly</option>
    <option value="0 0 * * *">Daily</option>
    <option value="0 6 * * 1">Weekly</option>
    <option value="0 0 1 * *">Monthly</option>
  </select>
  <a href="https://crontab.guru" target="_blank" style="margin-left:10px;">🧠 Crontab Help</a>

  <p style="margin-top:10px;">🕒 Last Triggered: <strong><?= $last_triggered ?></strong></p>

  <label>📜 Log Viewer:</label><br>
  <textarea rows="10" cols="80"><?= htmlspecialchars(@file_get_contents($log_path)) ?></textarea>

  <br><br>
  <?php if ($python_missing): ?>
    <input type="submit" value="💾 Save Settings" disabled title="Python3 is required to apply changes.">
  <?php else: ?>
    <input type="submit" value="💾 Save Settings">
  <?php endif ?>
</form>

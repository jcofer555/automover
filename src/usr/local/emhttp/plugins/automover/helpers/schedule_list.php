<?php
declare(strict_types=1);

define('SCHEDULES_CFG', '/boot/config/plugins/automover/schedules.cfg');

function yes_no(string $value): string {
    $v = strtolower($value);
    return ($v === 'yes' || $v === '1' || $v === 'true') ? 'Yes' : 'No';
}

// Display value for the CLEANUP three-state field
function cleanup_label(string $value): string {
    switch (strtolower($value)) {
        case 'yes': return 'Yes';
        case 'top': return 'Top';
        default:    return 'No';
    }
}

function human_cron(string $cron): string {
    $cron  = trim($cron);
    $parts = preg_split('/\s+/', $cron);
    if (count($parts) !== 5) return $cron;
    [$min, $hour, $dom, $month, $dow] = $parts;

    if ($min === '0' && preg_match('/^\*\/(\d+)$/', $hour, $m) && $dom === '*' && $month === '*' && $dow === '*') {
        $n = (int)$m[1];
        return "Every {$n} hours";
    }
    if (preg_match('/^\d+$/', $min) && preg_match('/^\d+$/', $hour) && $dom === '*' && $month === '*' && $dow === '*') {
        $t = date('g:i A', mktime((int)$hour, (int)$min));
        return "Runs daily at {$t}";
    }
    if (preg_match('/^\d+$/', $min) && preg_match('/^\d+$/', $hour) && $dom === '*' && $month === '*' && preg_match('/^\d+$/', $dow)) {
        $days = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
        $t    = date('g:i A', mktime((int)$hour, (int)$min));
        $d    = $days[(int)$dow] ?? $dow;
        return "Every {$d} at {$t}";
    }
    if (preg_match('/^\d+$/', $min) && preg_match('/^\d+$/', $hour) && preg_match('/^\d+$/', $dom) && $month === '*' && $dow === '*') {
        $t      = date('g:i A', mktime((int)$hour, (int)$min));
        $dom_i  = (int)$dom;
        $suffix = match(true) {
            $dom_i % 10 === 1 && $dom_i !== 11 => 'st',
            $dom_i % 10 === 2 && $dom_i !== 12 => 'nd',
            $dom_i % 10 === 3 && $dom_i !== 13 => 'rd',
            default                             => 'th',
        };
        return "Monthly on the {$dom_i}{$suffix} at {$t}";
    }

    return $cron;
}

$schedules = [];
if (file_exists(SCHEDULES_CFG)) {
    $parsed = parse_ini_file(SCHEDULES_CFG, true, INI_SCANNER_RAW);
    if (is_array($parsed)) $schedules = $parsed;
}

if (empty($schedules)) return;
?>
<div class="TableContainer">
<table class="amb-schedules-table">
<colgroup>
  <col style="width:160px">
  <col style="width:58px">
  <col style="width:58px">
  <col style="width:72px">
  <col style="width:62px">
  <col style="width:55px">
  <col style="width:45px">
  <col style="width:45px">
  <col style="width:45px">
  <col style="width:55px">
  <col style="width:55px">
  <col style="width:55px">
  <col style="width:220px">
</colgroup>
<thead>
<tr>
  <th style="text-align:left;padding-left:14px;">Scheduling</th>
  <th>Pool</th>
  <th>Thresh</th>
  <th>Stop Thresh</th>
  <th>Dry Run</th>
  <th>Notify</th>
  <th>Age</th>
  <th>Size</th>
  <th>Excl</th>
  <th>Hidden</th>
  <th>Clean Folders</th>
  <th>Clean ZFS</th>
  <th>Actions</th>
</tr>
</thead>
<tbody>
<?php foreach ($schedules as $id => $s): ?>
<?php
    $enabledBool = strtolower((string)($s['ENABLED'] ?? 'yes')) === 'yes';
    $btnText     = $enabledBool ? 'Disable' : 'Enable';
    $toggleTip   = $enabledBool ? 'Disable this schedule' : 'Enable this schedule';
    $dotClass    = $enabledBool ? 'enabled' : 'disabled';
    $cron        = (string)($s['CRON'] ?? '');
    $settings    = [];
    if (!empty($s['SETTINGS'])) {
        $decoded = json_decode(stripslashes($s['SETTINGS']), true);
        if (is_array($decoded)) $settings = $decoded;
    }
    $pool        = $settings['POOL_NAME']            ?? '—';
    $thresh      = isset($settings['THRESHOLD'])      ? $settings['THRESHOLD'].'%'      : '—';
    $stopThreshRaw = $settings['STOP_THRESHOLD'] ?? null;
    $stopThresh    = $stopThreshRaw !== null ? $stopThreshRaw.'%' : '—';
    $dryRun      = isset($settings['DRY_RUN'])             ? yes_no($settings['DRY_RUN'])             : '—';
    $notify      = isset($settings['NOTIFICATIONS']) ? yes_no($settings['NOTIFICATIONS']) : '—';
    $age         = isset($settings['AGE_BASED_FILTER'])     ? yes_no($settings['AGE_BASED_FILTER'])     : '—';
    $size        = isset($settings['SIZE_BASED_FILTER'])    ? yes_no($settings['SIZE_BASED_FILTER'])    : '—';
    $excl        = isset($settings['EXCLUSIONS'])   ? yes_no($settings['EXCLUSIONS'])   : '—';
    $hidden      = isset($settings['HIDDEN_FILTER'])        ? yes_no($settings['HIDDEN_FILTER'])        : '—';
    $cleanFolders = isset($settings['CLEANUP'])             ? cleanup_label($settings['CLEANUP'])       : '—';
    $cleanZfs     = isset($settings['CLEANUP_ZFS_DATASETS']) ? yes_no($settings['CLEANUP_ZFS_DATASETS']) : '—';
    $id_esc      = htmlspecialchars($id);
    $humanCron   = human_cron($cron);
    $tipText     = htmlspecialchars($humanCron . ' — ' . $cron);
?>
<tr>
  <td style="text-align:left !important;padding-left:10px !important;">
    <div style="display:flex;align-items:center;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">
      <span class="amb-sched-dot <?= $dotClass ?>"></span>
      <span data-tipster="<?= $tipText ?>" style="cursor:pointer;"><?= htmlspecialchars($humanCron) ?></span>
    </div>
  </td>
  <td><?= htmlspecialchars($pool) ?></td>
  <td><?= htmlspecialchars($thresh) ?></td>
  <td><?= htmlspecialchars($stopThresh) ?></td>
  <td><?= htmlspecialchars($dryRun) ?></td>
  <td><?= htmlspecialchars($notify) ?></td>
  <td><?= htmlspecialchars($age) ?></td>
  <td><?= htmlspecialchars($size) ?></td>
  <td><?= htmlspecialchars($excl) ?></td>
  <td><?= htmlspecialchars($hidden) ?></td>
  <td><?= htmlspecialchars($cleanFolders) ?></td>
  <td><?= htmlspecialchars($cleanZfs) ?></td>
  <td>
    <div class="sched-actions">
      <button type="button" data-tipster="Edit this schedule" data-action="edit" data-id="<?= $id_esc ?>">Edit</button>
      <button type="button" data-tipster="<?= htmlspecialchars($toggleTip) ?>" data-action="toggle" data-id="<?= $id_esc ?>" data-enabled="<?= $enabledBool ? 'true' : 'false' ?>"><?= htmlspecialchars($btnText) ?></button>
      <button type="button" data-tipster="Delete this schedule" data-action="delete" data-id="<?= $id_esc ?>">Delete</button>
      <button type="button" data-tipster="Run this schedule now" class="amb-schedule-run-btn" data-action="run" data-id="<?= $id_esc ?>">Run</button>
    </div>
  </td>
</tr>
<?php endforeach; ?>
</tbody>
</table>
</div>
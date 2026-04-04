<?php
ob_start();

register_shutdown_function(function () {
    $err = error_get_last();
    if ($err && in_array($err['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR], true)) {
        if (ob_get_level() > 0) ob_end_clean();
        header('Content-Type: application/json');
        http_response_code(500);
        echo json_encode([
            'status'  => 'error',
            'message' => 'PHP fatal: ' . $err['message'] . ' in ' . $err['file'] . ':' . $err['line'],
        ]);
    }
});

define('CFG_PATH', '/boot/config/plugins/automover/settings.cfg');

header('Content-Type: application/json');

// No CSRF validation needed — these helpers are protected by Unraid's own
// nginx authentication layer. All other automover helpers (schedule_delete,
// schedule_toggle, run_schedule, etc.) follow the same pattern.

set_error_handler(function ($errno, $errstr, $errfile, $errline) {
    global $_amb_err;
    $_amb_err = "PHP error [$errno]: $errstr in $errfile:$errline";
    return true;
});
global $_amb_err;
$_amb_err = null;

function get_str($key, $default = '') {
    return isset($_POST[$key]) ? trim((string) $_POST[$key]) : $default;
}

function normalize_container_names($raw) {
    if ($raw === '') return '';
    return trim(preg_replace('/,\s*/', ',', $raw));
}

// Validate CLEANUP value — must be one of: no, yes, top
function validate_cleanup($val) {
    return in_array($val, ['no', 'yes', 'top'], true) ? $val : 'no';
}

$settings = [
    'AGE_BASED_FILTER'            => get_str('AGE_BASED_FILTER',            'no'),
    'AGE_DAYS'                    => get_str('AGE_DAYS',                    '1'),
    'ALLOW_DURING_PARITY'         => get_str('ALLOW_DURING_PARITY',         'no'),
    'CLEANUP'                     => validate_cleanup(get_str('CLEANUP',    'no')),
    'CLEANUP_ZFS_DATASETS'        => get_str('CLEANUP_ZFS_DATASETS',        'no'),
    'CPU_AND_IO_PRIORITIES'       => get_str('CPU_AND_IO_PRIORITIES',       'no'),
    'CPU_PRIORITY'                => get_str('CPU_PRIORITY',                '0'),
    'DRY_RUN'                     => get_str('DRY_RUN',                     'no'),
    'EXCLUSIONS'                  => get_str('EXCLUSIONS',                  'no'),
    'FORCE_TURBO_WRITE'           => get_str('FORCE_TURBO_WRITE',           'no'),
    'HASH_LOCATION'               => get_str('HASH_LOCATION',               '/mnt/user/appdata'),
    'HIDDEN_FILTER'               => get_str('HIDDEN_FILTER',               'no'),
    'IO_PRIORITY'                 => get_str('IO_PRIORITY',                 'normal'),
    'JDUPES'                      => get_str('JDUPES',                      'no'),
    'NOTIFICATION_SERVICE'        => get_str('NOTIFICATION_SERVICE',        ''),
    'NOTIFICATIONS'               => get_str('NOTIFICATIONS',               'no'),
    'POOL_NAME'                   => get_str('POOL_NAME',                   'cache'),
    'POST_SCRIPT'                 => get_str('POST_SCRIPT',                 ''),
    'PRE_AND_POST_SCRIPTS'        => get_str('PRE_AND_POST_SCRIPTS',        'no'),
    'PRE_SCRIPT'                  => get_str('PRE_SCRIPT',                  ''),
    'PUSHOVER_USER_KEY'           => get_str('PUSHOVER_USER_KEY',           ''),
    'QBITTORRENT_DAYS_FROM'       => get_str('QBITTORRENT_DAYS_FROM',       '0'),
    'QBITTORRENT_DAYS_TO'         => get_str('QBITTORRENT_DAYS_TO',         '2'),
    'QBITTORRENT_HOST'            => get_str('QBITTORRENT_HOST',            ''),
    'QBITTORRENT_MOVE_SCRIPT'     => get_str('QBITTORRENT_MOVE_SCRIPT',     'no'),
    'QBITTORRENT_PASSWORD'        => get_str('QBITTORRENT_PASSWORD',        ''),
    'QBITTORRENT_STATUS'          => get_str('QBITTORRENT_STATUS',          'completed'),
    'QBITTORRENT_USERNAME'        => get_str('QBITTORRENT_USERNAME',        ''),
    'SIZE'                        => get_str('SIZE',                        '1'),
    'SIZE_BASED_FILTER'           => get_str('SIZE_BASED_FILTER',           'no'),
    'SIZE_UNIT'                   => get_str('SIZE_UNIT',                   'MB'),
    'STOP_ALL_CONTAINERS'         => get_str('STOP_ALL_CONTAINERS',         'no'),
    'STOP_CONTAINERS'             => normalize_container_names(get_str('STOP_CONTAINERS')),
    'STOP_THRESHOLD'              => get_str('STOP_THRESHOLD',              '0'),
    'SSD_TRIM'                    => get_str('SSD_TRIM',                    'no'),
    'THRESHOLD'                   => get_str('THRESHOLD',                   '0'),
    'WEBHOOK_DISCORD'             => get_str('WEBHOOK_DISCORD',             ''),
    'WEBHOOK_GOTIFY'              => get_str('WEBHOOK_GOTIFY',              ''),
    'WEBHOOK_NTFY'                => get_str('WEBHOOK_NTFY',                ''),
    'WEBHOOK_PUSHOVER'            => get_str('WEBHOOK_PUSHOVER',            ''),
    'WEBHOOK_SLACK'               => get_str('WEBHOOK_SLACK',               ''),
];
ksort($settings);

$cfg_dir = dirname(CFG_PATH);
if (!is_dir($cfg_dir)) {
    if (!mkdir($cfg_dir, 0755, true) && !is_dir($cfg_dir)) {
        $stray = ob_get_clean();
        echo json_encode(['status' => 'error', 'message' => 'Could not create config directory: ' . $cfg_dir, 'stray' => trim($stray)]);
        exit;
    }
}

$cfg_out = '';
foreach ($settings as $key => $val) {
    $cfg_out .= $key . '="' . $val . '"' . "\n";
}

$tmp = CFG_PATH . '.tmp.' . getmypid();
if (file_put_contents($tmp, $cfg_out) === false) {
    $stray = ob_get_clean();
    echo json_encode(['status' => 'error', 'message' => 'Failed to write tmp file: ' . $tmp, 'stray' => trim($stray)]);
    exit;
}
if (!rename($tmp, CFG_PATH)) {
    @unlink($tmp);
    $stray = ob_get_clean();
    echo json_encode(['status' => 'error', 'message' => 'Failed to move config into place: ' . CFG_PATH, 'stray' => trim($stray)]);
    exit;
}

$stray = ob_get_clean();
echo json_encode([
    'status'    => 'ok',
    'timestamp' => date('Y-m-d H:i:s'),
    'stray'     => trim($stray),
    'php_error' => $_amb_err,
]);
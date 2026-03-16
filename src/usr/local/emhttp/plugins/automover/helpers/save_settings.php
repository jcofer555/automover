<?php
declare(strict_types=1);

ob_start();

// ── Constants ─────────────────────────────────────────────────────────────────
define('CFG_PATH', '/boot/config/plugins/automover/settings.cfg');

// ── Entry point ───────────────────────────────────────────────────────────────
header('Content-Type: application/json');

// ── CSRF validation (matches other helpers) ───────────────────────────────────
$csrf_header = $_SERVER['HTTP_X_CSRF_TOKEN'] ?? '';
$csrf_post   = $_POST['csrf_token']          ?? '';
$csrf_cookie = $_COOKIE['csrf_token']        ?? '';

if (empty($csrf_header) && empty($csrf_post)) {
    ob_end_clean();
    http_response_code(403);
    echo json_encode(['status' => 'error', 'message' => 'Missing CSRF token']);
    exit;
}
if ($csrf_header !== $csrf_cookie && $csrf_post !== $csrf_cookie) {
    ob_end_clean();
    http_response_code(403);
    echo json_encode(['status' => 'error', 'message' => 'Invalid CSRF token']);
    exit;
}

// ── Catch stray warnings ──────────────────────────────────────────────────────
set_error_handler(function(int $errno, string $errstr, string $errfile, int $errline): bool {
    global $_amb_err;
    $_amb_err = "PHP error [$errno]: $errstr in $errfile:$errline";
    return true;
});
global $_amb_err;
$_amb_err = null;

// ── Utilities ─────────────────────────────────────────────────────────────────
function get_str(string $key, string $default = ''): string {
    return isset($_POST[$key]) ? trim((string)$_POST[$key]) : $default;
}

function normalize_container_names(string $raw): string {
    if ($raw === '') return '';
    return trim(preg_replace('/,\s*/', ',', $raw));
}

// ── Input ─────────────────────────────────────────────────────────────────────
$settings = [
    'POOL_NAME'                  => get_str('POOL_NAME',                  'cache'),
    'THRESHOLD'                  => get_str('THRESHOLD',                  '0'),
    'STOP_THRESHOLD'             => get_str('STOP_THRESHOLD',             '0'),
    'DRY_RUN'                    => get_str('DRY_RUN',                    'no'),
    'ALLOW_DURING_PARITY'        => get_str('ALLOW_DURING_PARITY',        'no'),
    'AUTOSTART'                  => get_str('AUTOSTART',                  'no'),
    'MANUAL_MOVE'                => get_str('MANUAL_MOVE',                'no'),
    'CRON_MODE'                  => get_str('CRON_MODE',                  'daily'),
    'CRON_EXPRESSION'            => get_str('CRON_EXPRESSION',            ''),
    'HOURLY_FREQUENCY'           => get_str('HOURLY_FREQUENCY',           '4'),
    'DAILY_TIME'                 => get_str('DAILY_TIME',                 '00:00'),
    'WEEKLY_DAY'                 => get_str('WEEKLY_DAY',                 ''),
    'WEEKLY_TIME'                => get_str('WEEKLY_TIME',                ''),
    'MONTHLY_DAY'                => get_str('MONTHLY_DAY',                ''),
    'MONTHLY_TIME'               => get_str('MONTHLY_TIME',               ''),
    'CONTAINER_NAMES'            => normalize_container_names(get_str('CONTAINER_NAMES')),
    'STOP_ALL_CONTAINERS'        => get_str('STOP_ALL_CONTAINERS',        'no'),
    'AGE_BASED_FILTER'           => get_str('AGE_BASED_FILTER',           'no'),
    'AGE_DAYS'                   => get_str('AGE_DAYS',                   '1'),
    'SIZE_BASED_FILTER'          => get_str('SIZE_BASED_FILTER',          'no'),
    'SIZE_MB'                    => get_str('SIZE_MB',                    '1'),
    'SIZE_UNIT'                  => get_str('SIZE_UNIT',                  'MB'),
    'HIDDEN_FILTER'              => get_str('HIDDEN_FILTER',              'no'),
    'EXCLUSIONS_ENABLED'         => get_str('EXCLUSIONS_ENABLED',         'no'),
    'FORCE_RECONSTRUCTIVE_WRITE' => get_str('FORCE_RECONSTRUCTIVE_WRITE', 'no'),
    'ENABLE_CLEANUP'             => get_str('ENABLE_CLEANUP',             'no'),
    'ENABLE_JDUPES'              => get_str('ENABLE_JDUPES',              'no'),
    'HASH_PATH'                  => get_str('HASH_PATH',                  '/mnt/user/appdata'),
    'ENABLE_TRIM'                => get_str('ENABLE_TRIM',                'no'),
    'ENABLE_SCRIPTS'             => get_str('ENABLE_SCRIPTS',             'no'),
    'PRE_SCRIPT'                 => get_str('PRE_SCRIPT',                 ''),
    'POST_SCRIPT'                => get_str('POST_SCRIPT',                ''),
    'PRIORITIES'                 => get_str('PRIORITIES',                 'no'),
    'PROCESS_PRIORITY'           => get_str('PROCESS_PRIORITY',           '0'),
    'IO_PRIORITY'                => get_str('IO_PRIORITY',                'normal'),
    'ENABLE_NOTIFICATIONS'       => get_str('ENABLE_NOTIFICATIONS',       'no'),
    'NOTIFICATION_SERVICE'       => get_str('NOTIFICATION_SERVICE',       ''),
    'PUSHOVER_USER_KEY'          => get_str('PUSHOVER_USER_KEY',          ''),
    'WEBHOOK_DISCORD'            => get_str('WEBHOOK_DISCORD',            ''),
    'WEBHOOK_GOTIFY'             => get_str('WEBHOOK_GOTIFY',             ''),
    'WEBHOOK_NTFY'               => get_str('WEBHOOK_NTFY',               ''),
    'WEBHOOK_PUSHOVER'           => get_str('WEBHOOK_PUSHOVER',           ''),
    'WEBHOOK_SLACK'              => get_str('WEBHOOK_SLACK',              ''),
    'QBITTORRENT_SCRIPT'         => get_str('QBITTORRENT_SCRIPT',         'no'),
    'QBITTORRENT_HOST'           => get_str('QBITTORRENT_HOST',           ''),
    'QBITTORRENT_USERNAME'       => get_str('QBITTORRENT_USERNAME',       ''),
    'QBITTORRENT_PASSWORD'       => get_str('QBITTORRENT_PASSWORD',       ''),
    'QBITTORRENT_DAYS_FROM'      => get_str('QBITTORRENT_DAYS_FROM',      '0'),
    'QBITTORRENT_DAYS_TO'        => get_str('QBITTORRENT_DAYS_TO',        '2'),
    'QBITTORRENT_STATUS'         => get_str('QBITTORRENT_STATUS',         'completed'),
];

// ── Ensure config directory exists ────────────────────────────────────────────
$cfg_dir = dirname(CFG_PATH);
if (!is_dir($cfg_dir)) {
    if (!mkdir($cfg_dir, 0755, true) && !is_dir($cfg_dir)) {
        $stray = ob_get_clean();
        echo json_encode(['status' => 'error', 'message' => 'Could not create config directory: ' . $cfg_dir, 'stray' => trim($stray)]);
        exit;
    }
}

// ── Build config content ──────────────────────────────────────────────────────
$cfg_out = '';
foreach ($settings as $key => $val) {
    $cfg_out .= $key . '="' . $val . '"' . "\n";
}

// ── Write atomically ──────────────────────────────────────────────────────────
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

// ── Respond ───────────────────────────────────────────────────────────────────
$stray = ob_get_clean();
echo json_encode([
    'status'    => 'success',
    'timestamp' => date('Y-m-d H:i:s'),
    'stray'     => trim($stray),
    'php_error' => $_amb_err,
    'data'      => ['ok' => true],
]);
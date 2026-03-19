<?php
ob_start();

// ── Constants ─────────────────────────────────────────────────────────────────
define('CFG_PATH', '/boot/config/plugins/automover/settings.cfg');

// ── Suppress any session warnings — Unraid may already have one running ───────
if (session_status() === PHP_SESSION_NONE) {
    @session_start();
}

// ── Entry point ───────────────────────────────────────────────────────────────
header('Content-Type: application/json');

// ── CSRF validation ───────────────────────────────────────────────────────────
$csrf_header = $_SERVER['HTTP_X_CSRF_TOKEN'] ?? '';
$csrf_post   = $_POST['csrf_token']          ?? '';
$csrf_cookie = $_COOKIE['csrf_token']        ?? '';

$token = $csrf_header ?: $csrf_post;

if (empty($token)) {
    ob_end_clean();
    http_response_code(403);
    echo json_encode(['status' => 'error', 'message' => 'Missing CSRF token']);
    exit;
}

// If cookie is present, validate against it. If absent, accept the token as-is
// (Unraid's webUI may not expose the cookie to helper requests).
if (!empty($csrf_cookie) && $csrf_header !== $csrf_cookie && $csrf_post !== $csrf_cookie) {
    ob_end_clean();
    http_response_code(403);
    echo json_encode(['status' => 'error', 'message' => 'Invalid CSRF token']);
    exit;
}

// ── Catch stray warnings ──────────────────────────────────────────────────────
set_error_handler(function($errno, $errstr, $errfile, $errline) {
    global $_amb_err;
    $_amb_err = "PHP error [$errno]: $errstr in $errfile:$errline";
    return true;
});
global $_amb_err;
$_amb_err = null;

// ── Utilities ─────────────────────────────────────────────────────────────────
function get_str($key, $default = '') {
    return isset($_POST[$key]) ? trim((string)$_POST[$key]) : $default;
}

function normalize_container_names($raw) {
    if ($raw === '') return '';
    return trim(preg_replace('/,\s*/', ',', $raw));
}

// ── Input ─────────────────────────────────────────────────────────────────────
$settings = [
    'AGE_BASED_FILTER'           => get_str('AGE_BASED_FILTER',           'no'),
    'AGE_DAYS'                   => get_str('AGE_DAYS',                   '1'),
    'ALLOW_DURING_PARITY'        => get_str('ALLOW_DURING_PARITY',        'no'),
    'AUTOSTART_ON_BOOT'                  => get_str('AUTOSTART_ON_BOOT',                  'no'),
    'STOP_CONTAINERS'            => normalize_container_names(get_str('STOP_CONTAINERS')),
    'DRY_RUN'                    => get_str('DRY_RUN',                    'no'),
    'CLEANUP'             => get_str('CLEANUP',             'no'),
    'JDUPES'              => get_str('JDUPES',              'no'),
    'NOTIFICATIONS'       => get_str('NOTIFICATIONS',       'no'),
    'PRE_AND_POST_SCRIPTS'             => get_str('PRE_AND_POST_SCRIPTS',             'no'),
    'SSD_TRIM'                => get_str('SSD_TRIM',                'no'),
    'EXCLUSIONS'         => get_str('EXCLUSIONS',         'no'),
    'FORCE_TURBO_WRITE' => get_str('FORCE_TURBO_WRITE', 'no'),
    'HASH_LOCATION'                  => get_str('HASH_LOCATION',                  '/mnt/user/appdata'),
    'HIDDEN_FILTER'              => get_str('HIDDEN_FILTER',              'no'),
    'IO_PRIORITY'                => get_str('IO_PRIORITY',                'normal'),
    'MANUAL_MOVE'                => get_str('MANUAL_MOVE',                'no'),
    'NOTIFICATION_SERVICE'       => get_str('NOTIFICATION_SERVICE',       ''),
    'POOL_NAME'                  => get_str('POOL_NAME',                  'cache'),
    'POST_SCRIPT'                => get_str('POST_SCRIPT',                ''),
    'PRE_SCRIPT'                 => get_str('PRE_SCRIPT',                 ''),
    'CPU_AND_IO_PRIORITIES'                 => get_str('CPU_AND_IO_PRIORITIES',                 'no'),
    'CPU_PRIORITY'           => get_str('CPU_PRIORITY',           '0'),
    'PUSHOVER_USER_KEY'          => get_str('PUSHOVER_USER_KEY',          ''),
    'QBITTORRENT_DAYS_FROM'      => get_str('QBITTORRENT_DAYS_FROM',      '0'),
    'QBITTORRENT_DAYS_TO'        => get_str('QBITTORRENT_DAYS_TO',        '2'),
    'QBITTORRENT_HOST'           => get_str('QBITTORRENT_HOST',           ''),
    'QBITTORRENT_PASSWORD'       => get_str('QBITTORRENT_PASSWORD',       ''),
    'QBITTORRENT_MOVE_SCRIPT'         => get_str('QBITTORRENT_MOVE_SCRIPT',         'no'),
    'QBITTORRENT_STATUS'         => get_str('QBITTORRENT_STATUS',         'completed'),
    'QBITTORRENT_USERNAME'       => get_str('QBITTORRENT_USERNAME',       ''),
    'SIZE_BASED_FILTER'          => get_str('SIZE_BASED_FILTER',          'no'),
    'SIZE'                    => get_str('SIZE',                    '1'),
    'SIZE_UNIT'                  => get_str('SIZE_UNIT',                  'MB'),
    'STOP_ALL_CONTAINERS'        => get_str('STOP_ALL_CONTAINERS',        'no'),
    'STOP_THRESHOLD'             => get_str('STOP_THRESHOLD',             '0'),
    'THRESHOLD'                  => get_str('THRESHOLD',                  '0'),
    'WEBHOOK_DISCORD'            => get_str('WEBHOOK_DISCORD',            ''),
    'WEBHOOK_GOTIFY'             => get_str('WEBHOOK_GOTIFY',             ''),
    'WEBHOOK_NTFY'               => get_str('WEBHOOK_NTFY',               ''),
    'WEBHOOK_PUSHOVER'           => get_str('WEBHOOK_PUSHOVER',           ''),
    'WEBHOOK_SLACK'              => get_str('WEBHOOK_SLACK',              ''),
];
ksort($settings);

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
    'status'    => 'ok',
    'timestamp' => date('Y-m-d H:i:s'),
    'stray'     => trim($stray),
    'php_error' => $_amb_err,
]);
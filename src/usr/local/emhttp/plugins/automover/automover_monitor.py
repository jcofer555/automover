import configparser, subprocess, time, os, sys

CONFIG_PATH = '/boot/config/plugins/automover/settings.cfg'
DISK_INFO_PATH = '/var/local/emhttp/disks.ini'
LOG_PATH = '/var/log/automover.log'
TRIGGER_LOG = '/boot/config/plugins/automover/last_triggered.log'

def log(msg):
    with open(LOG_PATH, 'a') as f:
        f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} - {msg}\n")
    print(msg)

# Check if Python is installed
if not shutil.which("python3"):
    log("❌ Python3 not found — aborting monitor.")
    sys.exit(1)

config = configparser.ConfigParser()
config.read(CONFIG_PATH)

dry_run = config['Settings'].get('dry_run', 'no') == 'yes'
mode = config['Settings'].get('check_mode', 'realtime')
scan_interval = int(config['Settings'].get('scan_interval', 60))

thresholds = config['Thresholds'] if 'Thresholds' in config else {}
continuous_cfg = config['Continuous'] if 'Continuous' in config else {}

def mover_running():
    result = subprocess.run(['pgrep', '-f', 'mover'], capture_output=True, text=True)
    return bool(result.stdout.strip())

def trigger_mover():
    if not mover_running():
        if not dry_run:
            subprocess.run(['mover', 'start'])
            with open(TRIGGER_LOG, 'w') as f:
                f.write(time.strftime('%Y-%m-%d %H:%M:%S'))
        log("⚠️ Mover triggered")
    else:
        log("🚫 Mover already running — skipped")

def check_disks(thresholds):
    disk_info = configparser.ConfigParser()
    disk_info.read(DISK_INFO_PATH)
    exceeded = []

    for disk, threshold_str in thresholds.items():
        if disk not in disk_info or disk_info[disk].get('type') == 'Array':
            continue
        try:
            used = float(disk_info[disk]['used'])
            size = float(disk_info[disk]['size'])
            percent = (used / size) * 100
            threshold = float(threshold_str)
        except:
            continue
        log(f"{disk}: {percent:.2f}% used (threshold {threshold}%)")
        if percent > threshold:
            exceeded.append(disk)
    return exceeded

if mode == 'scheduled':
    exceeded = check_disks(thresholds)
    if exceeded:
        log(f"🔥 Scheduled trigger — exceeded: {', '.join(exceeded)}")
        trigger_mover()
    else:
        log("✅ Scheduled check — all disks below threshold")

elif mode == 'realtime':
    exceeded = check_disks(thresholds)
    if exceeded:
        log(f"🔥 Realtime trigger — exceeded: {', '.join(exceeded)}")
        trigger_mover()

        # Continuous scan loop
        while True:
            time.sleep(scan_interval)
            still_exceeded = check_disks({d: thresholds[d] for d in exceeded if continuous_cfg.get(d, 'no') == 'yes'})
            if not still_exceeded:
                log("✅ All continuous disks below threshold — exiting loop")
                break
            log(f"⏳ Continuing scan — still exceeded: {', '.join(still_exceeded)}")

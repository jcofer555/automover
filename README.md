# 🛡️ Automover Plugin for unRAID

**Monitor pool disks, trigger the mover when thresholds are exceeded, and log what's been moved.**

## 📦 Features

- Monitor selected pool disks only (cache, other pools — excludes array)
- Enable dry-run mode to simulate triggers
- Won't run if mover is already running
- Easy-to-use settings page
- Selected pool usage % displayed
- Threshold setting to prevent moving unless pool is at least that % full
- Logging to /var/log/automover_last_run.log and /var/log/automover_files_moved.log
- Autostart at boot option
- Allow or deny moving to run when parity is checking
- Interval setting to check threshold with a minimum of 1 minute
- Ability to disable unraids built in mover schedule
- Recommend not combining with mover tuning plugin

<img width="1917" height="758" alt="image" src="https://github.com/user-attachments/assets/7a544076-b4c9-48a5-bb11-a3463c08ae54" />


# 🛡️ Auto Mover Plugin for Unraid

**Monitor pool disks, trigger the mover when thresholds are exceeded, and keep your system tidy — all through a smart, customizable UI.**

## 📦 Features

- Monitor selected **pool disks only** (cache, other pools — excludes array)
- Enable **dry-run mode** to simulate triggers
- Automatically blocks mover if already running
- Easy-to-use settings page in Unraid’s **Settings** tab
- Selected pool usage % displayed
- Threshold setting to prevent moving unless pool is at least that % full
- Logging to /var/log/automover_last_run.log and /var/log/automover_files_moved.log
- Autostart at boot option
- Allow or deny moving to run when parity is checking
- Interval setting to check threshold with a minimum of 1 minute

<img width="1915" height="740" alt="image" src="https://github.com/user-attachments/assets/c73730cd-81c2-4215-a2cd-40244c7c318d" />

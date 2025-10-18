### Automover Plugin for unRAID ###

**Monitor pool disks, move files from pool only when thresholds are exceeded, and log what's been moved.**

## Features ##

- Monitor selected pool disks only (cache, other pools — excludes array)
- Enable dry-run mode to simulate triggers
- Selected pool's usage % is displayed
- Threshold setting to prevent moving unless pool is at least that % full
- Autostart at boot option
- Allow or deny moving when parity is checking
- Interval setting to check threshold with a minimum of 5 minute
- Ability to manually set file/folder excludes
- Ability to disable unraids built in mover schedule
- Ability to exclude files from moving unless they are X amount of days or older
- Ability to exclude files from moving unless they are at least X MB in size or larger
- Logging to /var/log/automover_last_run.log and /var/log/automover_files_moved.log
- Recommend not combining with mover tuning plugin

<img width="1917" height="829" alt="image" src="https://github.com/user-attachments/assets/72dbfc38-cc09-4ca2-90f5-3700e2195d19" />





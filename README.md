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
- Ability to disable unraids built in mover schedule
- Ability to exclude files from moving unless they are X amount of days or older
- Ability to exclude files from moving unless they are at least X MB in size or larger
- Logging to /var/log/automover_last_run.log and /var/log/automover_files_moved.log
- Recommend not combining with mover tuning plugin

<img width="1000" height="480" alt="image thumb png 96e376ee5b030002898480ba738df32f" src="https://github.com/user-attachments/assets/7642f963-39f5-49b3-8723-c3d26ab073c8" />




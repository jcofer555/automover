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
- Logging to /var/log/automover_last_run.log and /var/log/automover_files_moved.log
- Recommend not combining with mover tuning plugin

<img width="1000" height="479" alt="image thumb png 578135af9fd232ad42238fec22f76930" src="https://github.com/user-attachments/assets/58acd420-f6ed-420f-9c73-1a3d1b0eebca" />



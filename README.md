### Automover Plugin for unRAID ###

**Monitor pool disks, move files from pool only when thresholds are exceeded, and log what's been moved.**

## Features ##

- Monitor selected pool disks only (cache, other pools — excludes array)
- Enable dry-run mode to simulate triggers
- Selected pool's usage % is displayed
- Only moves from pool -> array or pool -> pool and skips any shares set to array -> pool
- Threshold setting to prevent moving unless pool is at least that % full
- Autostart at boot option
- Move now button to bypass filters
- Allow or deny moving when parity is checking
- Two schedule modes interval and cron expression to choose from
- Built in trash guides mover script to pause and resume active torrents so the files can be moved
- Jdupes option built in to re-hardlink any files after every move
- Option to stop containers before moves and start them back after finish
- Ability to force turbo write on during move
- Ability to disable unraids built in mover schedule
- Ability to manually set file/folder excludes
- Ability to skip hidden folders/files
- Ability to exclude files from moving unless they are X amount of days or older
- Ability to exclude files from moving unless they are at least X MB in size or larger
- Logging available in the webui
- Recommend not combining with mover tuning plugin

<img width="1000" height="461" alt="image thumb png eaff00c943be13079f4fab5f1149eb5a" src="https://github.com/user-attachments/assets/47f66d67-c423-454f-8161-80a51276c6e7" />









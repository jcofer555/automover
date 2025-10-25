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
- Interval setting to check threshold with a minimum of 1 minute
- Built in trash guides mover script to pause and resume active torrents so the files can be moved
- Ability to force turbo write on during move
- Ability to disable unraids built in mover schedule
- Ability to manually set file/folder excludes
- Ability to skip hidden folders/files
- Ability to exclude files from moving unless they are X amount of days or older
- Ability to exclude files from moving unless they are at least X MB in size or larger
- Logging available in the webui
- Recommend not combining with mover tuning plugin

<img width="1000" height="454" alt="image thumb png 7400e14e87d560712419c1783bdb4796" src="https://github.com/user-attachments/assets/16d7b0ee-8e74-4f8c-af6c-d110abe30932" />







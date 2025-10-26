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

<img width="1000" height="462" alt="image thumb png de0c40f96c770341b4db0c6e79c5819b" src="https://github.com/user-attachments/assets/53e18fef-a134-4832-a9ca-4b16cd947c51" />








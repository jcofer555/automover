### Automover Plugin for unRAID ###

**Monitor pool disks, move files from pool only when thresholds are exceeded, and log what's been moved.**

## Features ##

- Monitor selected pool disks only (cache, other pools — excludes array)
- Enable dry-run mode to simulate triggers
- Selected pool's usage % is displayed
- Only moves from pool -> array or pool -> pool and skips any shares set to array -> pool
- Threshold setting to prevent moving unless pool is at least that % full
- Stop threshold setting to stop moving once pool reaches that %
- Autostart at boot option
- Move now button to bypass filters
- Allow or deny moving when parity is checking
- Two schedule modes interval and cron expression to choose from
- Option to have start and finish notifications sent to unraid or discord
- Option to do a manual move using rsync where you pick the source and destination
- Built in trash guides mover script to pause and resume active torrents so the files can be moved
- Jdupes option built in to re-hardlink any files after every move
- Manual rsync option usin the manual move checkbox
- Option to stop containers before moves and start them back after finish
- Ability to force turbo write on during move
- Ability to manually set file/folder excludes
- Ability to skip hidden folders/files
- Ability to exclude files from moving unless they are X amount of days or older
- Ability to exclude files from moving unless they are at least X MB in size or larger
- Logging available in the webui
- Recommend not combining with mover tuning plugin

<img width="1000" height="411" alt="image thumb png f0eee4e72bc985e6d53e1856dd8b976a" src="https://github.com/user-attachments/assets/8b8297b5-b5f4-4218-8d30-061071a8fde7" />

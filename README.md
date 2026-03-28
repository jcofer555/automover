### Automover Plugin ###

**Monitor pool disks, move files from pool only when thresholds are exceeded, and log what's been moved.**

## Features ##
- Scheduler available
- Able to schedule different settings for different pools
- Dry-run mode to simulate a run
- Only moves from pool -> array or pool -> pool and skips any shares set to array -> pool
- Threshold setting to prevent moving unless pool is at least that % full
- Stop threshold setting to stop moving once pool reaches that %
- Allow or deny moving when parity is checking
- Option to trim ssd disks after files are moved
- Option to run a script pre move and/or post move
- Notification support for discord, gotify, ntfy, pushover, slack, and unraids built in
- Ability to set cpu and i/o priorities
- Built in trash guides mover script to pause and resume active torrents so the files can be moved
- Jdupes option to re-hardlink any files after every move
- Option to stop containers before moves and start them back after finish
- Ability to force turbo write on during move
- Ability to manually set file/folder excludes
- Ability to skip hidden folders/files
- Ability to exclude files from moving unless they are X number of days or older
- Ability to exclude files from moving unless they are at least X MB in size or larger
- Logging available in the webui and at /tmp/automover
- Recommend disabling unraids built in mover schedule at settings > scheduler which requires unraid 7.2.1+
- Recommend not combining with mover tuning plugin

<img width="1000" height="468" alt="image" src="https://github.com/user-attachments/assets/afb07648-6aed-4c42-8d88-29675acb5061" />

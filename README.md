# Backup Monitor

**[Download Backup Monitor (DMG)](https://github.com/Oz-Color/BackupMonitor/releases/latest/download/BackupMonitor.dmg)** · [all releases](https://github.com/Oz-Color/BackupMonitor/releases)

Follows Silverstack offload, verify and transcode progress at the top of the screen and in the menu bar, and warns when a card copies too slowly. For Silverstack XT and Silverstack Lab; Offload Manager is not supported. Not affiliated with Pomfort. Original idea from Joe Jamieson.

Open the DMG and drag Backup Monitor to Applications. Apple Silicon and Intel, macOS 13 or later. Signed by Oz Color and notarized by Apple, so it opens like any downloaded app. At first launch, allow notifications.

## Island

On a MacBook with a notch, the island grows out of the notch while a job runs and stays hidden otherwise. Without a notch it drops from the top centre of the screen (off by default there, see Settings). Hover it for details, queued jobs, recently completed jobs, mounted volumes, Settings and Quit. Edit, beside the Mounted volumes heading, hides volumes such as master drives; Hidden volumes in Settings has the same list as switches. Mounted disk images (DMGs) are never listed. A green tick means every file now on the volume was copied by a successful Silverstack job, a blue tick that every clip on it has also been transcoded.

## Menu bar

While a job runs the icon can show its percentage, speed, time remaining, the number of jobs and a progress wheel, in any mix (chosen in Settings). The menu lists mounted volumes, Settings, About and Quit.

## Slow copy warning

Each card being copied is checked on its own, on its real speed: the size of each file read from it over the time its copy phase took (until verify starts, or until the file is done when there is no verify). This is lower than the speed Silverstack shows, which overstated real throughput by about half on test offloads. A file still copying can only be as fast as its size over the time so far, so a long clip that is clearly too slow is caught before it ends. After 30 seconds of copying, under the minimum for its group, the job turns orange with for example `Slow: 208 MB/s (min 500) · A015CAZH`, the menu bar readout turns orange and a notification is sent. Copy phase only.

A card's group comes from the entries in Settings, separated by commas: a single letter is a camera letter, the first letter of reel-style names like `A015CAZH` or `D902_261103` (the names Card Rename gives); anything longer matches the start of a card name, so `CANTAR_SD` also covers `CANTAR_SD_2`. Defaults, all editable:

| Group | Entries | Minimum |
| --- | --- | --- |
| Camera cards | A, B, C, D, E, F, G, H | 500 MB/s |
| Audio cards | CANTAR_SD | 40 MB/s |
| Other sources | everything else, such as `SSD_01` or `DJI` | 150 MB/s |

## Settings

Island and menu bar icon on or off (one of them always stays on), menu bar readouts, entries and minimum speed per group, mounted volumes to hide, notifications (slow copy on by default; job finished, failed or stopped and unreadable logs off, as Silverstack has its own), Open at Login, Show Demo, version and About. Settings opens on first launch, and whenever the app is opened again from Finder or Applications, which is the way back when the icon is hidden. While Settings or About is open, the app shows in the Dock and Cmd-Tab.

The app checks the latest GitHub release once a day. A newer version shows in Settings and at the top of the menu, with a Download button, and one notification.

## How it reads Silverstack

Read-only: it follows Silverstack's logs in `~/Library/Logs/Silverstack */` and reads each job's size and source volumes from the project database. It never writes to either, and never tells Silverstack to do anything.

These are undocumented internals, so a Silverstack update could change them. When Silverstack is running but its log can't be read any more, the island and the menu say so. Always trust Silverstack's own job status for sign-off.

## Build

```bash
./build.sh
```

Needs only the Command Line Tools. Runs the tests, then builds a universal `build/Backup Monitor.app`. `./build.sh install` also copies it to Applications and opens it; `./build.sh dmg` makes the signed and notarized DMG for a release.

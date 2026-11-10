# Changelog

## 1.0.5 - 2026-11-10

- Fixes progress, speed and time left freezing or jumping during copies and verifies with newer Silverstack XT 9 versions. Those also write a FileToolService log in the same folder, and while it was the newest file Backup Monitor read it instead of Silverstack's own log. Only Silverstack's own log is followed now, and switching between log files never reads one again from the start.

## 1.0.4 - 2026-11-10

- Verify jobs are named after the disk they check, with the card in the details ("A6MT3_20TB", "Verify D004"). The verify of the card itself shows as "D004 (card)", and a Silverstack Lab job that checks every copy at once shows "Verify on 3 disks".
- Speed and time left are measured by Backup Monitor: the real throughput over the last 20 s, using the last 3 s until 20 s have passed, and nothing for the first 3 s. They change every 5 s, or 1, 2 or 10 s, set in Settings. "—" means nothing moved in the last 20 s. Time left no longer counts the wait before a job starts, which made a 5-minute verify read over an hour.
- Settings chooses what each side of the closed island shows: up to two of the ring, percentage, time left, speed and number of jobs, with a live preview. Without a notch both sides sit next to each other.
- The open island and the menu list up to 8 jobs: the first 3 in full, the others on one line each with a thin progress bar, then "+N more".
- Silverstack Lab: source cards and ingest ticks are read from Lab's own file table.

## 1.0.3 - 2026-11-10

- The island appears with the same timing as the menu bar pill: it fades in, grows out of the notch, then its ring and text fade in; when it goes, the contents fade out and it shrinks back into the notch. Opened by hovering the notch between jobs, it still shows and hides at once.
- If the pill would be hidden by the notch or pushed off a full menu bar, it leaves out the number of jobs, then the wheel, then the percentage, then the speed, for that job.
- With no readouts chosen (or none that fit), the drive icon itself takes the job's colour: orange, red or green.
- Show Demo copies from a sample camera card and shows the slow warning and notification when its speed is under the camera minimum.
- The Island and Menu bar icon switches no longer look greyed out; switching off the last one beeps and keeps it on.
- Updates install themselves: Install and Relaunch in Settings or the menu downloads the new version, checks it is Backup Monitor, newer, signed by Oz Color and accepted by macOS, swaps it in and reopens. Download stays for when the app can't replace itself.
- The menu bar menu shows the same job rows as the island: progress bars, details, current file, queued and recently completed jobs, updating while the menu is open.
- The menu bar readout fits its text, and grows or shrinks over half a second when the text gets longer or shorter, so the icons beside it move gently instead of jumping. A longer text waits until the pill has room for it, so nothing is ever cut off. Each part keeps room for two-digit percentages and seconds and for speeds up to 999.9 MB/s, so the pill changes size far less often. Numbers sit at the right of their room, so "%", "MB/s" and "s" stay in place.
- The readout sits on a pill that fades in as a circle and widens over one second, each part of the text (percentage, speed, time) fading in once it fits whole; at the end the text fades out, then the pill folds back the same way. In step with the display, drawn on whole pixels, and drawn as the button's own image, so menu bar managers like Ice never show their background beside it while it changes size. Neutral while copying, orange when a card is slow or the log goes quiet, red for errors or a failed job (until dismissed), green with "Done" for 2 seconds after the last job succeeds. Drawn by the app, so the text is no longer cut short with "…" while the width changes.

## 1.0.2 - 2026-11-09

- Check for Updates button at the bottom of Settings, with the result of the last check.

## 1.0.1 - 2026-11-09

- Cmd-W closes Settings and About; Cmd-C, Cmd-V, Cmd-X, Cmd-A and Cmd-Z work in the Settings fields (the app now has a main menu while a window is open).

## 1.0 - 2026-11-09

First public release, as Backup Monitor (previously Silverstack Island).

- Slow copy warning per source card on its real speed (file sizes over copy times), with camera letters or full card names and a minimum speed for camera cards, audio cards (CANTAR_SD by default) and other sources.
- Settings window: island and menu bar icon on or off, menu bar readouts, card groups, volumes to hide, notifications, Open at Login, Show Demo, version. The menu keeps only volumes, Settings, About and Quit.
- Menu bar readouts: percentage, speed, time remaining, number of jobs, progress wheel.
- Notifications for slow copies (on by default), jobs finished, failed or stopped, and unreadable logs.
- Warning when Silverstack is running but its log can't be read.
- Mounted volumes checklist in Settings to hide volumes; disk images (DMGs) are no longer listed.
- New app icon: a stack of drives inside a progress ring.
- Universal build for Apple Silicon and Intel Macs.
- Update check against GitHub releases, About window.

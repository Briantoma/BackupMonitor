# Changelog

## 1.0.3 - 2026-11-10

- The menu bar menu shows the same job rows as the island: progress bars, details, current file, queued and recently completed jobs, updating while the menu is open.
- The menu bar readout keeps one width for the whole job, sized for the widest numbers it can show, so the icons beside it no longer shift.

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

# Changelog

## 1.0.3 - 2026-11-10

- The island appears with the same timing as the menu bar pill: it fades in, grows out of the notch, then its ring and text fade in; when it goes, the contents fade out and it shrinks back into the notch. Opened by hovering the notch between jobs, it still shows and hides at once.
- The menu bar menu shows the same job rows as the island: progress bars, details, current file, queued and recently completed jobs, updating while the menu is open.
- The menu bar readout fits its text, and grows or shrinks over half a second when the text gets longer or shorter, so the icons beside it move gently instead of jumping. A longer text waits until the pill has room for it, so nothing is ever cut off.
- The readout sits on a pill that fades in as a circle and widens over one second, each part of the text (percentage, speed, time) fading in once it fits whole; at the end the text fades out, then the pill folds back the same way. In step with the display, and drawn on whole pixels so coloured pills keep clean edges. Neutral while copying, orange when a card is slow or the log goes quiet, red for errors or a failed job (until dismissed), green with "Done" for 2 seconds after the last job succeeds. Drawn by the app, so the text is no longer cut short with "…" while the width changes.

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

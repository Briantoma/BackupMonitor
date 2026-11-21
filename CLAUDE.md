# Backup Monitor

macOS menu bar and notch app that follows Pomfort Silverstack XT / Lab offloads, verifies and transcodes by reading Silverstack's log and project database (read-only). Swift + AppKit/SwiftUI, no Xcode project: `build.sh` compiles with `swiftc`. Published as GitHub releases on Briantoma/BackupMonitor; the app updates itself from the latest release.

## Build, test, release

- `zsh ./build.sh`: runs the tests (`tests/main.swift`, compiled with `Sources/Core.swift` and `Sources/Log.swift`), then builds `build/Backup Monitor.app` as a universal binary (arm64 + x86_64, macOS 13+), signed.
- `zsh ./build.sh install`: also copies to /Applications and opens it.
- `zsh ./build.sh dmg`: also builds `build/BackupMonitor.dmg`, notarised and stapled. It needs the **Developer ID Application: Oz Color Shop (8HMFSMY38P)** certificate in the keychain and a notarytool keychain profile named **oz-color-notary**. Both were set up on the MacBook only; on another Mac, check `security find-identity -v -p codesigning` and `xcrun notarytool history --keychain-profile oz-color-notary` before releasing.
- Release: raise `CFBundleShortVersionString` and `CFBundleVersion` in Info.plist, add a CHANGELOG entry (newest first), build the DMG, then `gh release create vX.Y.Z build/BackupMonitor.dmg --repo Briantoma/BackupMonitor --title "Backup Monitor X.Y.Z" --notes-file <notes> --target main`. Notes = that version's CHANGELOG section plus an install line. Check `gh api repos/Briantoma/BackupMonitor/releases/latest` returns the new tag. Only release when Thomas says so.
- Thomas sometimes edits README.md on GitHub: fetch and rebase (`--autostash`) before pushing. Don't commit the local `.gitignore` change or `.ignore`.

## Testing without Silverstack running

- `MONITOR_LOG_ROOT` and `MONITOR_DATA_ROOT` point the app at other log and database folders.
- To screenshot the island or Settings: copy `Sources/` to a scratch folder, add a probe in `applicationDidFinishLaunching` that runs `store.runDemo()`, sets `store.isHovering`, opens Settings and captures windows with `screencapture -x -o -l <windowNumber>`, build it as a separate bundle ID (e.g. `fr.oz-color.backupmonitor.probe`) so its preferences don't touch the real app.
- Replay a real log: compile `Sources/Core.swift Sources/Database.swift` with a small main that feeds lines to `Tracker`, looks up `ProjectDatabase.info`, and samples `Pace` every 0.5 s of log time. When replaying old logs, zero `alreadyDoneBytes/Tasks`, as the database by then marks every task finished.

## Decisions to keep

- Logs: follow only Silverstack's own log (`com.pomfort.SilverstackXT9 …`, `…Lab8 …`). Newer XT 9 also writes `com.pomfort.SilverstackFileToolService …` in the same folder; following it froze progress (fixed in 1.0.5). Each file keeps its own read position.
- XT 9 runs one verify job per destination disk plus one for the card; they are titled by the disk (from the verify-resource link table, whose name `Z_<n>VERIFYRESOURCES` differs between versions; Lab 8 keeps files in ZFILERESOURCE, XT 9 in ZVIDEORESOURCE).
- Speed and time left are measured by the app (`Pace`): real throughput over the last 20 s, the last 3 s until 20 s have passed, nothing for the first 3 s, "—" when nothing moved for 20 s. Shown values refresh every 5 s (1/2/5/10 in Settings). Silverstack's own logged speed overstates real throughput.
- Slow-copy warning: copy phase only, real throughput per card group (camera letters A–H 500 MB/s, audio CANTAR_SD 40 MB/s, others 150 MB/s).
- Island: up to two items per side of the notch, chosen in Settings with a preview; without a notch both sides sit together. Open list: 3 full job rows, then one-line rows up to 8, then "+N more". Optional hover delay (0.1–1 s).
- Menu bar pill: drawn as the status item's own image (menu bar managers like Ice show a grey box otherwise; a faint one remains on macOS 26, accepted). Each job row in the menu is its own menu item so long menus scroll.
- Past jobs: saved 14 days in UserDefaults (`pastJobs.saved`), shown in the island and menu as Today / This week / Last 5, 10, 20, or hidden.
- Self-update: downloads the release DMG, checks bundle ID, newer version, Oz Color team signature and Gatekeeper, swaps the app and relaunches.
- About: Oz Color logo and link, "Original idea from Joe Jamieson", for Silverstack XT and Lab only (Offload Manager not supported), not affiliated with Pomfort.

## Open

- On Thomas's other Mac (XT 9, five parallel verifies), the island showed 15% / 1m 41s while Silverstack's verifies were nearly done. Likely the log bug fixed in 1.0.5; not confirmed. If it recurs on 1.0.6, get Silverstack's own log from that Mac (not the FileToolService one) and replay it.
- Offload speed swings (about 145–400 MB/s in one copy) because each file's progress covers copy then verify. Not changed yet.
- Not seen on screen: the no-notch island layout, one-line rows of running jobs, the menu and Settings on a real 1920x1080 display, the Dock icon fix.

# Silverstack Island

Shows Silverstack offload, verify and transcode progress in the MacBook notch. Stays hidden when nothing is running. Hover for details, queued jobs and recently completed jobs. Hovering the notch between jobs opens the recent list on its own.

Open `Silverstack Island.app`. Hovering the notch opens the island at any time, with mounted volumes and Show Demo, Open at Login and Quit at the bottom. The same list is in the menu bar dropdown, when macOS has room to show the icon (on a full menu bar it may not). Edit, beside the Mounted volumes heading, chooses which volumes to hide, such as master drives. In the volume list, a green tick means every file now on the volume was copied by a successful Silverstack job, and a blue tick means every clip on it has also been transcoded. To rebuild after changing the code (this also runs the tests):

```bash
./build.sh
```

Read-only: it follows Silverstack's logs in `~/Library/Logs/Silverstack */` and reads each job's size once from the project database. It never writes to either, and it never tells Silverstack to do anything.

These are undocumented internals, so a Silverstack update could change them. If that happens the island shows less or nothing; check it after updating. Always trust Silverstack's own job status for sign-off.

# Shelf Sync (KOReader plugin)

Shelf Sync keeps a folder on a KOReader device matching one Grimmory shelf.

- **New books** on the shelf download when the Kindle wakes up, or when Wi-Fi connects.
- **Books taken off the shelf**, or deleted from Grimmory, are removed on the next sync. Their KOReader sidecar, history entry and collections go with them.
- **Safety rules:**
  - It only deletes files that it downloaded itself.
  - It never deletes or replaces the book that is currently open. That change waits until the next sync after the book is closed.
  - An automatic sync refuses to remove more than 10 books at once when that would be over half of what it manages. A manual "Sync now" asks first.
- **Downloads happen in a background process,** so the reader never freezes. Each file downloads to a `.part` file, is size-checked, and is only then renamed. A sync that gets interrupted by sleep simply resumes next time. A download that breaks off (Wi-Fi blip, Tailscale restarting) gets one automatic retry.
- **You can see it working.** "Sync now" shows a live box: which file, percent, speed and time left. Tap it to hide it; the sync keeps going. Automatic syncs show short toasts instead: when downloads start, at 25/50/75 % of big files, and a summary at the end. While a sync runs, the Shelf Sync menu's last line reads "Syncing now: …" and tapping it brings the live box back.
- **Fast at home.** The home address is tried as a direct connection first, so at home the download does not pass through the Tailscale proxy (which costs a third of the speed and a share of the Kindle's single CPU core). The away address goes through the proxy, as it must. The "Last sync" line says which route was used.
- **Files are byte-identical to the server copy.** That keeps KOReader's progress sync (KOSync, set to Binary matching) working with Grimmory.

## How long should a sync take?
On this Kindle a plain novel (2–6 MB) lands in a second or two. Photo-heavy cookbooks and comics can be 100–400 MB; at the measured 4 MB/s at home that is 30 s to 2 min per book, and longer through Tailscale or while you are reading at the same time (one CPU core does both). The live box or the toasts show the speed, so "slow" and "stuck" look different.

## Install on the Kindle
1. Connect the Kindle over USB.
2. Copy the `shelfsync.koplugin` folder into `koreader/plugins/` on the Kindle's drive.
3. Eject the Kindle and restart KOReader.

## Set up (once per Kindle)
Open **Tools → Shelf Sync (Grimmory)**.

1. **Server and account**
   - Home address: `http://192.168.0.9:6060`
   - Away address: `http://100.95.26.46:6060` (Tailscale)
   - Username and password: that person's Grimmory login.
2. **Choose shelf.** Pick that person's shelf, for example "Kindle".
3. **Folder.** The default is `Grimmory` inside the KOReader home folder.
4. Leave **Sync automatically** and **Remove books taken off the shelf** turned on.
5. Tap **Sync now** once to confirm it works.

**Grimmory side.** Each person needs their own Grimmory user, with the **download** permission turned on. Each person also needs their own shelf. Shelves are private per user, and the plugin mirrors the logged-in user's shelf.

## Develop / test
- Unit tests for the sync rules: `luajit spec/plan_spec.lua`
- End-to-end test: `harness/run.sh`. It starts a throwaway Grimmory and headless KOReader in Docker, then runs four rounds: first sync, changes on the server, the open-book guard, and sidecar cleanup. `harness/run.sh down` removes it all.

## Files
- `main.lua`: menu, wake and Wi-Fi triggers, applying results, safe deletes.
- `shelfsync/job.lua`: the network half, which runs in a subprocess.
- `shelfsync/api.lua`: a minimal Grimmory REST client.
- `shelfsync/plan.lua`: the pure sync rules, unit-tested.

License: AGPL-3.0, the same license as KOReader.

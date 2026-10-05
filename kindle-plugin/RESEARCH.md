
## 2026-10-04 (late): Shelf Sync speed and visibility

Kris: "it has taken over 5 minutes to sync 2 books" and no indicator of working vs stalled.

Findings (measured on his Kindle over SSH):
- The "2 books" were True Comfort (258 MB, a photo cookbook) and Marshmallow Madness! (15 MB). 45 books in the library are over 50 MB; the biggest is 400 MB.
- Sustained 264 MB pull on a quiet Kindle: 4.0 MB/s direct to flash, 3.2 MB/s through the Tailscale userspace proxy (KOReader's HTTP proxy 127.0.0.1:1056 applies to the LAN address too). The real sync ran at ~0.65 MB/s: the KT6 has ONE 1 GHz core shared by KOReader (Kris was opening a book), tailscaled (proxying every byte) and the download. The first attempt also died at 21:38 ("closed" then "connection refused") when the proxy went away mid-transfer, and the retry started from zero.
- Wi-Fi power management is on (period 2); not touched.

Changes (plugin, harness 17/17, unit 14/14):
- Routes: LAN addresses connect direct first, then via proxy; Tailscale/other addresses via proxy first, then direct. Pure `Plan.routes` + `Plan.isPrivateHost`, unit-tested. Api instances carry their own proxy and swap `http.PROXY` around each request (safe in the main process too).
- Progress file (`settings/shelfsync_progress.json`, atomic rename, ≤1 write/s) from the subprocess; main polls it. "Sync now" = live InfoMessage box (file, %, speed, ETA; tap hides; 2 s repaint). Automatic = toasts at plan, each file, 25 % steps of files ≥ 20 MB, and the summary. Menu last line shows "Syncing now: …" while running and reopens the box. InfoMessage's dismiss_callback fires on our own close too, hence the box_closing guard.
- One retry per file after a 3 s pause. Per-file speed logged to crash.log; last_result now says "(direct)" or "(via Tailscale)".
- Docs: plugin README (how long a sync should take), FAMILY-GUIDE (sizes on cards, how to watch).

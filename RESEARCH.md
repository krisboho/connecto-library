# Book Stack — Feasibility Research (2026-09-27)

Goal (Kris): one app combining BookLore + Shelfmark to search/download books in Docker and sync them to a jailbroken Kindle.

## TL;DR
- **BookLore is no longer a good foundation.** Its developer deleted it in March 2026. It came back, then went into maintenance mode on 2026-09-19 and named BookOrbit as its "official successor". The community fork **Grimmory** is where most users went.
- **Merging the two codebases isn't worth it.** Grimmory is Java/Spring + Angular + MariaDB (AGPL-3.0). Shelfmark is Python/Flask + React (MIT). Merging them means a rewrite, and then keeping up with two fast-moving upstreams forever.
- **Most of the pipeline already exists.** Shelfmark has a built-in "Grimmory (API)" output mode that uploads finished downloads straight into a Grimmory library, hands-off.
- **The real gap is the Kindle end.** The Kindle has to *pull*, because it sleeps and drops Wi-Fi. KOReader's built-in OPDS sync is a manual one tap. Automatic pull needs a third-party plugin or a small one we write. That's where custom dev earns its keep.

## Component status

### Shelfmark (github.com/calibrain/shelfmark)
- MIT. v1.4.0 released 2026-09-26, releases every few days.
- **Health risk:** the top maintainer (alexhb1) stepped down in 2026-06. The project is "feature stable, best-effort" (issue #1050). PRs are still merged.
- Stack: Python 3.14 Flask/SocketIO + React 19.
- Images:
  - `ghcr.io/calibrain/shelfmark` bundles Chromium for the Cloudflare bypass (~2 GB RAM).
  - `shelfmark-lite` uses an external FlareSolverr instead.
- Port 8084, volumes `/config` and `/books`.
- Sources:
  - Anna's Archive / LibGen / Welib / Z-Lib direct download. Off by default; you supply the mirror URLs yourself.
  - Prowlarr, Newznab, torrent clients (qBit, Transmission, Deluge, rTorrent, debrid services), SABnzbd/NZBGet, IRC, AudiobookBay.
  - Fragile: domains churn, Cloudflare blocks, and Z-Lib's "DiamWall" challenge is unhandled (#1386).
- Output modes (`BOOKS_OUTPUT_MODE`):
  - `folder`
  - `email`
  - `booklore`, which uploads via the Grimmory API to a library or to BookDrop.
- API: JSON under `/api/`. Since v1.4.0 you can set `SHELFMARK_API_KEY`; it grants admin, which is root-equivalent. Flow:
  1. `GET /api/metadata/search`
  2. `GET /api/releases`
  3. `POST /api/releases/download`
  4. Poll `GET /api/status`
- Metadata: Open Library (default), Hardcover (key), Google Books (key).
- Its README says it will **not** manage a library, watch authors or series, or queue downloads for later.

### BookLore (github.com/booklore-app/booklore): maintenance mode
- AGPL-3.0. Single maintainer (acx10). Issues disabled. The docs site is down (TLS error).
- Timeline: AI-PR/paywall controversy, then the repo was deleted around 2026-03-23 and later restored. v2.4.0 (2026-09-19) points users to BookOrbit.

### Grimmory (github.com/grimmory-tools/grimmory): recommended library
- Community fork, AGPL-3.0. Has a written GOVERNANCE.md with multiple maintainers. 159 commits in the last 30 days. v3.5.0 (2026-09-21) included 3 security fixes.
- Java/Spring + Angular + **MariaDB**. Needs 2 GB RAM minimum, 4 GB recommended.
- Getting books in:
  - The BookDrop watch folder **always** requires a manual "Finalize".
  - `POST /api/v1/files/upload` goes straight into a library. This is the path Shelfmark uses.
- API: OpenAPI docs via `API_DOCS_ENABLED`. Logins issue JWTs (2 h access, 30-day refresh). **No API keys and no webhooks.**
- Devices:
  - OPDS 1.x (Basic auth, separate OPDS users) plus a Komga-compatible API.
  - KOSync-compatible progress sync at `/api/koreader`. Matching is by binary hash, so the file must be byte-identical to the one on the server.
  - Kobo sync.
  - Send-to-Kindle email (sends as-is, no conversion).
  - grimmory.koplugin (ALPHA).
- Migrating from BookLore is an image swap. From 2.3.1+ there's a known DB-migration clash with a SQL fix (#2486).

### BookOrbit (github.com/bookorbit/bookorbit): the alternative "already combined" app
- AGPL-3.0 plus ADDITIONAL_TERMS.md (attribution and trademark). A NestJS + Vue rewrite needing Postgres 18 + pgvector, 512 MB–1 GB RAM.
- It already does most of the "one app" idea:
  - Library.
  - Built-in **Book Requests**: Prowlarr/Torznab/Newznab handing off to torrent and usenet clients. No direct-download/IRC sources yet (#1400).
  - A mature KOReader plugin with two-way highlights.
  - OPDS, Kobo, Send-to-Kindle, and an iOS app.
  - Book Dock watch folder **with auto-finalize**.
- Risks:
  - Effectively one developer, very likely the same person as BookLore's. Trust controversy, including a call-out repo with unverified claims.
  - No Discussions or Discord.
- **Shelfmark's API mode does NOT work with it** (no `/files/upload` route). The workaround is Shelfmark folder mode feeding an auto-finalizing Book Dock.

## Kindle side
- **Jailbreak depends on model and firmware.** Current firmware is 5.19.6.
  - **Véra** covers 5.17.1–5.19.6: KT5/6, PW5/6, Colorsoft, Scribe 2022/2024.
  - **SpiderCat** covers up to 5.19.5.
  - Scribe 3rd gen and Scribe Colorsoft are **not** jailbreakable.
  - Any future firmware (5.19.7+) will probably close Véra.
- **Block updates now if the Kindle isn't jailbroken yet.** Use airplane mode, delete any `update*.bin`, and fill storage to 50–90 MB free. Source: kindlemodding.org.
- **Reader: KOReader** (v2026.07.1). It reads EPUB natively and has an OPDS browser, KOSync, SSH, and Calibre wireless.
  - The native Kindle reader can't read sideloaded EPUB. It would need AZW3/KFX conversion, which neither Grimmory nor BookOrbit does.
- **Delivery has to be a pull.** Wi-Fi drops in full sleep, so server push is unreliable.
- Delivery options:
  1. KOReader built-in OPDS sync: new items only, **manual tap**. Per-catalog folders land in 2026.09.
  2. OPDSfoldersync.koplugin: automatic on wake, on network connect, and every 24 h. But it's a 9-star fork last touched 2025-12, so it drifts from KOReader's 2026 OPDS changes.
  3. Syncthing on the Kindle: two-way files, but flaky I/O reports.
  4. SSH push via Tailscale or USBNetwork: works only while the Kindle is awake.
  5. Send-to-Kindle email: **avoid**. It needs Wi-Fi and Amazon registration, which risks an OTA update, and it only reaches the native reader.
- Progress sync: KOSync to Grimmory. Highlights don't sync back via KOSync.

## Legal / operational risk (factual)
- Anna's Archive in 2026:
  - OCLC default judgment (Jan).
  - Spotify/labels injunction (Jan 16) and a $322M default judgment (Apr 15).
  - 13 publishers won $19.5M plus a registrar takedown order (May 19).
  - Domains seized (.org, .se, .li). ISP blocks in Italy, the Netherlands, the UK, Belgium and Germany.
- Z-Library had FBI seizures in 2022–2024. LibGen faces a publisher suit (2023).
- No GitHub DMCA notices against downloader *tools* were found. Shelfmark is still hosted.
- ISP notices mostly come from torrent-swarm monitoring. That's relevant if you use Prowlarr or torrent sources.
- Legitimate sources:
  - Project Gutenberg (via harvest or feeds, rate-limited).
  - Standard Ebooks (new-releases feed free; full OPDS needs Patrons Circle).
  - LibriVox.
  - Your own DRM-free purchases.

## Licensing
- Merging MIT Shelfmark into AGPL Grimmory is allowed, but the result is AGPL, and you'd owe the source to network users.
- A separate wrapper app that talks to both over HTTP can carry any license. That's the common view, not case law.

## Sources
The agent reports cite these:
- github.com/calibrain/shelfmark: README, docs/api-access.md, issues #1050, #1386.
- github.com/booklore-app/booklore
- github.com/grimmory-tools/grimmory: GOVERNANCE.md, #2486.
- github.com/bookorbit/bookorbit, bookorbit.app/book-requests, /book-dock, /migration.
- kindlemodding.org/jailbreaks.json
- blog.the-ebook-reader.com: Véra 2026-08-11, SpiderCat 2026-09-01.
- github.com/koreader/koreader PRs #13946, #15615.
- github.com/koesac/OPDSfoldersync.koplugin
- xda-developers.com single-maintainer article (2026-03-31).
- AAP press release on the Anna's Archive judgment.
- ElfHosted blog 2026-08-10.

---

# Round 2: Kris's requirements (2026-09-27)

What Kris wants:
- **One web page** to search, download, manage and send books to devices. It can be backed by a stack of apps.
- Download sources: Anna's Archive direct download, and Prowlarr → usenet.
- A jailbroken Kindle that **auto-syncs on wake** and removes books that were deleted on the site at the next sync.
- iPad reading when needed.
- Family use.
- Hosted on Unraid.
- Independence from Shelfmark's developer. Kris wants to fix things like Anna's Archive domain changes without waiting on them.
- Current setup: Shelfmark, then BookLore, then a manual KOReader sync. The Kindle is already jailbroken.

## Proposed architecture
```
                ┌────────────── the one site (custom, ours) ──────────────┐
 family logins →│ search · download queue · library · send-to-device · delete │
                └───┬───────────────┬───────────────────┬─────────────────┘
      Anna's Archive│        Prowlarr│API          library│API
       (Shelfmark,  │   → SABnzbd    │             (Grimmory: files, metadata,
        headless,   │   (existing)   │              OPDS, KOSync) + MariaDB
        API key)    │                │                    │
                    └── finished files uploaded into Grimmory ┘
                                                          │ pull on wake
                  Kindle: KOReader + our sync plugin ─────┤ (mirror: add/remove)
                  iPad:   Readest (OPDS + KOSync) ────────┘
```

- **Shelfmark is kept as a headless engine** for Anna's Archive, driven through its v1.4.0 API key.
  - Mirror URLs are already a runtime setting, so a domain change never needs its developer.
  - If Anna's Archive code breaks and Shelfmark stalls, we fork it. It's MIT-licensed; we'd own the one Python module involved.
  - Prowlarr and SABnzbd are called directly because their APIs are stable and documented. That takes Shelfmark off the usenet path entirely.
- **Grimmory replaces BookLore** by swapping the image. There is a known SQL fix if BookLore is 2.3.1+ (Grimmory #2486).
  - Per-user permission flags: upload, download, delete_book, OPDS access, KOReader sync.
  - Deleting a book through the API also removes the file from disk.
- **Kindle plugin: fork grimmory.koplugin** (AGPL, alpha). It already auto-downloads the books on chosen shelves and can remove books deleted on the server. We add:
  - A trigger on resume and on network connect, following KOSync's pattern.
  - A guard so it never deletes the book that's currently open. Wallabag's plugin shows how.
  - Deletion through `FileManager:deleteFile`, which also purges the book's sidecar folder, history and collections.
  - Deletion only of files that the plugin itself downloaded.
  - A connectivity check that only asks "am I connected", not "can I reach the internet". The internet check fails on a LAN-only VLAN.
  - Self-update. Grimmory's plugin already does this, with a sha256 check on the download.
  - **KOReader's "Action when Wi-Fi is off" setting must be "turn on".**
  - It's unverified whether the network-connected event fires after a short sleep, so we also retry after resume. **This needs an on-device test.**
- **Gotcha:** Grimmory shelves are per user, and an admin can't fill another user's shelf. Two options:
  - Our site keeps its own "device → books" assignments and serves the manifest to the plugin itself. This is the likely choice.
  - Or it logs in as each user.
- **iPad: Readest** (free, open source). Add Grimmory's OPDS feed and point Readest's KOReader sync at `/api/koreader` with Binary matching.
  - Position lands roughly, within a few percent. PDFs don't sync progress.
  - Each family member needs their own Grimmory user.
  - The BookOrbit iOS app isn't native on iPad yet.
- **Why not BookOrbit:** it's a single-developer project with a trust controversy, which is the same risk Kris wants to get away from.
  - Its plugin has no auto-download and no deletion.
  - Its license adds extra terms on top of AGPL.
  - Shelfmark's API mode doesn't work with it.

## Mirror resilience
- The site will get an editable mirror list, a health check, and an alert when a mirror fails.
- I will NOT build automatic discovery of new Anna's Archive domains. Its purpose would be routing around court-ordered seizures.

## Roadmap v2
0. **Migrate BookLore → Grimmory.** It's an image swap. Shelfmark switches to its Grimmory API output mode. Nothing else changes.
1. **Kindle auto-sync plugin.** This is the biggest daily win, and it works with the current UIs.
2. **iPad via Readest.** Configuration only, no code.
3. **The one site.** Search, queue, library, per-device sending, delete, and family logins. Shelfmark and Grimmory become hidden backends.
4. **Hardening.** Mirror health checks and alerts, a Shelfmark adapter that's ready to fork, backups, and GHCR CI following Kris's usual pattern.

---

# Round 3: answers + Unraid inventory (2026-09-27)

## Kris's answers
- **Deleting:** both options. "Delete" removes a book from the server and all devices. "Remove from my Kindle" affects only that person. **Only Kris can delete.**
- **Kindle contents:** each person has their own list of what goes on their Kindle.
- **Family:** 4 people, 2 Kindles, several iPads.
- **Remote sync:** needed away from home. Tailscale is already live.
- **Kindle:** the 2024 basic Kindle, called 11th gen by Kris; KT6 in the jailbreak data. Firmware 5.17.1.0.4, already jailbroken.
- **BookLore:** 2.4.0. Kris estimates 415 books; the database has 453. Reading progress needs to carry over for one family member only.
- **Downloads:** Prowlarr and NZBGet on Unraid. Kris has an Anna's Archive donation key.

## Unraid inventory
Read-only SSH over the `unraid` alias, using key ~/.ssh/claude_unraid.
- **Server:** Unraid 7.1.4, 31 GB RAM (about 21 GB available), 16 cores. Tailscale runs natively (node `hydrillagorilla`, 100.95.26.46). The Tailscale container is only "Created", not used.
- **BookLore v2.4.0:** container `BookLore`, port :6060, bridge network.
  - Mounts: /mnt/user/appdata/booklore → /app/data, /mnt/user/books → /books. There is **no bookdrop mount**.
  - Database: container `MariaDB-booklore` (official mariadb image) on :3306, data at /mnt/user/appdata/mariadb-official.
  - Schema at Flyway V133 (2026-06-27). BookLore 2.4.0 added no migrations after that.
  - Contents: 1 library ("Koreader", path /books), 453 books, 456 book files on disk, 3 shelves.
  - Users: krisboho and bohannonbs. Only krisboho has KOReader progress, and only 3 rows. The one KOReader sync user is krisboho.
- **Shelfmark v1.4.0:** container `shelfmark`, port :8084.
  - Output mode is set to **booklore**, pointing at http://192.168.0.9:6060, so it already uploads over the API.
  - Anna's Archive base URL: annas-archive.pk. The Prowlarr usenet client is nzbget.
  - Mounts: /mnt/user/downloads/Books → /books and /downloads/Books.
- **Prowlarr:** :9696. **NZBGet** runs as container `nzbget-test` (nzbgetcom/nzbget), port 5678 → 6789, with /mnt/user/downloads → /downloads.
  - binhex-sabnzbd is also running on :8080. NZBHydra2 is also running.
- **Reverse proxy:** SWAG on :180/:1443 and a Cloudflared tunnel exist, but aren't needed if everything goes over Tailscale.
- **Takeaway:** Grimmory's migration risk depends on whether its migrations collide with V129–V133. The progress at stake is tiny (3 rows), so losing it wouldn't matter much.

## Round 3 verification
- **Migration:** V1–V132 are identical in BookLore and Grimmory. **V133 collides:** BookLore's version adds an Open Library setting, while Grimmory's adds a `book_file.is_fixed_layout` column. BookLore 2.4.0 added no new migrations, and Grimmory is at V148.
  - The automatic fix (Grimmory PR #2722, a beforeRepair callback) is only in develop/nightly, not in v3.5.0.
  - On v3.5.0, the maintainer's manual fix from #2486 applies: delete the BookLore V133 row from `flyway_schema_history` before first boot.
  - Otherwise Flyway's repair would probably relabel the row and skip adding the column, leading to unknown-column errors. That's inferred, not tested.
  - **The migration is one-way** (V144 converts icons to Lucide), so a dump is the only rollback.
  - KOReader progress and credential tables carry over unchanged.
- **Files are not rewritten:** Kris's BookLore has `saveToOriginalFile` off for every format, and move/rename off, and those settings carry over to Grimmory. OPDS serves the original bytes, so KOSync hashes stay stable.
- **Tailscale on the KT6 (5.17.1):**
  - Plan on the **koreader-tailscale plugin** (v1.3.0, 2026-09-16), which fixed a freeze on the 11th-gen basic Kindle. Use userspace/proxy mode with plain-HTTP 100.x IPs; MagicDNS is off in this plugin.
  - Our sync plugin must honor KOReader's HTTP proxy. HTTPS through the proxy is broken in KOReader (#14693).
  - TUN mode depends on `/dev/net/tun` existing on KT6, which is unverified. Test it on the device.
  - Fallback: the existing Cloudflared tunnel with HTTPS directly to the sync endpoint and auth. That's more exposure.
- **KOReader:** v2026.07.1, `kindlehf` package, recognized as KindleBasic5.
- **Sizes:** MariaDB data 180 MB. Books 8.3 GB.

## Phase 0 dry run: planned, awaiting Kris's OK
1. `mariadb-dump` the booklore database to /mnt/user/appdata/book-stack/backup/booklore-YYYYMMDD.sql. This is also the rollback point.
2. Create a new container `mariadb-grimmory-test` with its own data dir and restore the dump into it. Delete the BookLore V133 flyway row **in the copy only**.
3. Create `grimmory-test` (v3.5.0) on :6061, using a copy of /mnt/user/appdata/booklore as /app/data and **/mnt/user/books mounted read-only**.
4. Verify:
   - 453 books, both users, and 3 shelves are present.
   - krisboho's KOReader progress survived.
   - `is_fixed_layout` exists.
   - The OPDS feed works.
   - The KOSync endpoint answers.
5. Production BookLore, Shelfmark and the database are left untouched.
6. Cutover later: stop BookLore, take a fresh dump, run Grimmory on :6060 so the Kindle's sync URL doesn't change, and repoint Shelfmark.

## Phase 0 dry run: DONE 2026-09-28, passed
- **Backup:** /mnt/user/appdata/book-stack/backup/booklore-20260927.sql (2.1 MB, complete).
  - Routines were skipped, because the live MariaDB's system tables were never upgraded after going from 12.1.2 to 13.0.2. `mysql.proc` has the wrong column count, which needs `mariadb-upgrade`.
  - BookLore has 0 triggers and doesn't use routines. **I did not fix the live server; flagged to Kris.**
- **Test containers:** `mariadb-grimmory-test` (same image as production) and `grimmory-test` (v3.5.0) on :6061, on docker network `book-stack-test`.
  - Data in /mnt/user/appdata/book-stack/test/ with generated credentials in `.env` (mode 600). Books mounted **read-only**.
- **Fix applied to the copy only:** deleted the BookLore V133 flyway row, one row affected.
- **Migration:** Grimmory validated 146 migrations, went from V132 to V148, and started in about 12 s.
  - V137 gave 2 "key too long" warnings. These are non-fatal; MariaDB created the filter indexes with shortened keys.
- **Verified:** 453 books, 455 files, 3 shelves, 1 library, both users, krisboho's 3 KOReader progress rows, 1 KOReader user, and the `is_fixed_layout` column.
  - Healthcheck 200, UI 200. OPDS and KOSync return 401, meaning they're up and require auth.
  - RAM: Grimmory about 1.2 GB, test DB about 170 MB.
- **Not yet verified:** a logged-in UI walkthrough and an OPDS/KOSync test with real credentials. Kris needs to log in at :6061.
- **Cleanup when done:** `docker rm -f grimmory-test mariadb-grimmory-test; docker network rm book-stack-test`. Keep the backup.

---

# Status 2026-09-28 (end of session)
- **Phase 0: DONE. Grimmory v3.5.0 is live on Unraid :6060.**
  - It runs as container `Grimmory` with the template my-Grimmory.xml and is on autostart.
  - Same MariaDB (MariaDB-booklore) and same mounts. Schema is at v148.
  - All 453 books, users, shelves and KOReader progress carried over. Shelfmark logged in successfully with its saved settings.
  - BookLore was renamed `BookLore-retired`, stopped, and removed from autostart. **It must never start again**, because the DB now belongs to Grimmory.
  - Backups are in /mnt/user/appdata/book-stack/backup/: the pre-cutover SQL and a tarball of the appdata folder.
  - **DONE 2026-09-28:** repaired the stale system tables on MariaDB-booklore with a one-off container (MARIADB_AUTO_UPGRADE=1, same image, same data dir, user 99:100). The entrypoint saved a system-table backup (system_mysql_backup_12.1.2-MariaDB.sql.zst in the data dir), and full dumps with routines now work. A DB backup taken just before is in backup/grimmory-20260928-pre-mariadb-upgrade.sql.
- **Phase 1: the plugin is BUILT and passes the harness.** Code is in kindle-plugin/ (Shelf Sync, AGPL-3.0). Plan unit tests pass 12/12, and the Docker harness (throwaway Grimmory + headless KOReader) passes 14/14.
  - The install zip is kindle-plugin/dist/shelfsync.koplugin.zip, and setup steps are in kindle-plugin/README.md.
  - **Still needs on-device checks:**
    - Is Wi-Fi reconnected within about 60 s of wake? The plugin polls `isConnected` every 5 s after resume, and also listens for NetworkConnected.
    - Does Tailscale work on the KT6 with the koreader-tailscale plugin, over plain HTTP to 100.95.26.46:6060?
- **Next steps:**
  - Kris installs the plugin on his Kindle.
  - Create Grimmory users with download permission, plus a "Kindle" shelf per person.
  - Point the Kindle's KOSync at Grimmory. Use the Tailscale IP once Tailscale on the Kindle is confirmed.
  - Then Phase 2 (iPad/Readest) and Phase 3 (the one site).
- The local git repo in ~/claude/book-stack has one commit (bea18dd). No remote yet.

## Round 4 decisions (2026-09-30): the one site = "Connecto Library"
- Logins reuse Grimmory accounts.
- Anyone in the family can search and download; only Kris can delete.
- Reachable over both Tailscale and the Cloudflare tunnel (BookLore already went through the tunnel).
- Code goes to a private GitHub repo.

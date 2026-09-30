# Connecto Library — spec v0.1 (2026-09-30)

One website for the family: search for a book, download it, keep the library tidy, and send books to each person's Kindle. Shelfmark, Grimmory, Prowlarr and NZBGet keep doing the work behind it; nobody opens them directly.

Mockup: https://claude.ai/artifact/Ey9tW8h61az6cLXeD4rjnN

## Decisions (Kris, 2026-09-30)
- Logins reuse Grimmory accounts. One password per person.
- Anyone in the family can search and download. Only Kris (Grimmory admin) can delete or change settings.
- Reachable over Tailscale and the Cloudflare tunnel, like BookLore was (booklore.krisboho.com with Cloudflare Access).
- Name: Connecto Library. Repo: github.com/krisboho/connecto-library (private).

## Mockup feedback (Kris, 2026-09-30)
- "Send to my Kindle" wording stays.
- Downloads page shows only your own downloads; admins see everyone's.
- Add **Read online** on every library card (Grimmory's web reader; the site proxies it so no second login).
- Phone layout gets an iOS-native-style bottom tab bar (translucent, icon + label, home-indicator safe area). Add-to-Home-Screen (PWA) so it feels like an app.

## Screens
1. **Search.** One box. Results from Anna's Archive (via Shelfmark) and usenet (via Prowlarr) in one list, best copy first, "already in your library" marked. A Download button per result.
2. **Library.** Grid of Grimmory books with filter and "On my Kindle" view. Per book: **Send to my Kindle** / **Remove from my Kindle**, a menu with "Send to <other person>'s Kindle" (admin), Edit details, and **Delete from library** (admin only).
3. **Downloads.** Your own downloads (admins see everyone's), newest first: in progress (with cancel), importing, in library, failed (with retry and "other copies").
4. **Settings (admin).** Source health (Anna's Archive, usenet, Grimmory, last Kindle syncs), the Anna's Archive mirror list (edit, test, reorder, save without restart), and the people/Kindle table. Push alert when every mirror has failed for 30 minutes.
5. **Phone layout** of all of the above (the same pages, responsive).

## How each action maps to the stack
| Action | What happens |
|---|---|
| Log in | POST Grimmory `/api/v1/auth/login`; the site keeps the Grimmory JWT + refresh token in a server-side session cookie. Admin = Grimmory admin flag. |
| Search | Shelfmark `GET /api/metadata/search` + `GET /api/releases` (API key, server-side) and Prowlarr `GET /api/v1/search?type=book` (API key). Merge and rank. Cross-check against Grimmory books for "in library". |
| Download (Anna's Archive) | Shelfmark `POST /api/releases/download`; Shelfmark's booklore output mode uploads into Grimmory when done. |
| Download (usenet) | Prowlarr grab → NZBGet. A watcher moves the finished file into Grimmory via `POST /api/v1/files/upload` (same as Shelfmark does). |
| Send to my Kindle | Grimmory `POST /api/v1/books/shelves` as that user, assigning their "Kindle" shelf. Shelf Sync on the Kindle does the rest. |
| Remove from my Kindle | Same call, unassign. |
| Read online | Opens Grimmory's reader for the book through the site's own reverse proxy (`/reader/...`), which injects the user's Grimmory token, so there is no second login. |
| Delete | Grimmory `DELETE /api/v1/books?ids=` as admin (removes the file from disk). Every Kindle drops it on next sync. |
| Mirrors | Site keeps the list; pushes it to Shelfmark's mirrors setting via its API. Health check = HEAD each mirror every 15 min. |
| Kindle shelves for others | Grimmory shelves are per user; the site logs in as each person only through their own session. For "Send to Ben's Kindle" the admin path uses a per-person service token stored server-side (set up once per person). |

## Build
- **Stack:** Python 3.12 + FastAPI + HTMX server-rendered pages (fast to build, no JS build step, easy to keep). Docker image `ghcr.io/krisboho/connecto-library`, port 8430 on Unraid, same push → CI → image → pull pattern as fan-sync.
- **Config:** env vars for Grimmory/Shelfmark/Prowlarr URLs and keys; a small SQLite for download history, mirror list, health, and service tokens. Secrets never in the repo.
- **Auth for the tunnel:** Cloudflare Access in front (as BookLore had), plus the site's own Grimmory login. Over Tailscale, just the site's login.
- **Kindle plugin stays as is.** It already mirrors shelves; the site only edits shelves.

## Milestones
1. Login + Library page with Send/Remove to my Kindle (proves the Grimmory pass-through).
2. Search + Download via Shelfmark (Anna's Archive) + Downloads page.
3. Usenet via Prowlarr/NZBGet with the import watcher.
4. Settings: mirrors, health, alerts, people table. Delete.
5. Deploy on Unraid, tunnel hostname `library.krisboho.com`, Tailscale.
6. Polish: phone layout, per-person "Send to X's Kindle", edit details.

## Open points
- Cover images: Grimmory serves covers at `/api/v1/books/{id}/cover`; the site proxies them with the user's token.
- Shelfmark's API key is root-equivalent; it lives only in the site's env and is never sent to browsers.
- Anna's Archive mirror list: editable here; no automatic domain discovery (Kris agreed).

"""Connecto Library: one site for the family's books.

Milestone 1: log in with a Grimmory account, browse the library,
send books to / remove them from your own Kindle shelf, read online.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any
from urllib.parse import quote

from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from itsdangerous import BadSignature, URLSafeSerializer

from .config import Settings
from .grimmory import AuthError, Grimmory, GrimmoryError, Tokens, User
from .shelfmark import Shelfmark, ShelfmarkError
from .store import Store
from .health import Health, normalize_urls

BASE = Path(__file__).parent
settings = Settings.from_env()
grimmory = Grimmory(settings.grimmory_url)
shelfmark = Shelfmark(settings.shelfmark_url, settings.shelfmark_api_key)
store = Store(Path(settings.data_dir) / "connecto.db")
health = Health(settings, store, shelfmark)
signer = URLSafeSerializer(settings.session_secret, salt="connecto-session")
templates = Jinja2Templates(directory=str(BASE / "templates"))

app = FastAPI(title="Connecto Library", docs_url=None, redoc_url=None)
app.mount("/static", StaticFiles(directory=str(BASE / "static")), name="static")

SESSION_COOKIE = "connecto_session"
FLASH_COOKIE = "connecto_flash"


# ---------------------------------------------------------------- sessions

class Session:
    """What we keep in the signed cookie. Small on purpose."""

    def __init__(self, data: dict[str, Any]) -> None:
        self.tokens = Tokens(access=data["access"], refresh=data["refresh"])
        self.user = User(**data["user"])
        self.kindle_shelf_id: int | None = data.get("kindle_shelf_id")
        self.dirty = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "access": self.tokens.access,
            "refresh": self.tokens.refresh,
            "user": self.user.__dict__,
            "kindle_shelf_id": self.kindle_shelf_id,
        }


def _read_session(request: Request) -> Session | None:
    raw = request.cookies.get(SESSION_COOKIE)
    if not raw:
        return None
    try:
        return Session(signer.loads(raw))
    except (BadSignature, KeyError, TypeError, ValueError):
        return None


def _write_session(response: Response, session: Session) -> None:
    response.set_cookie(SESSION_COOKIE, signer.dumps(session.to_dict()), max_age=30 * 24 * 3600,
                        httponly=True, samesite="lax", secure=settings.secure_cookies)


def _clear_session(response: Response) -> None:
    response.delete_cookie(SESSION_COOKIE)


def _flash(response: Response, text: str, kind: str = "ok") -> None:
    response.set_cookie(FLASH_COOKIE, signer.dumps({"t": text, "k": kind}), max_age=60,
                        httponly=True, samesite="lax", secure=settings.secure_cookies)


def _pop_flash(request: Request) -> dict[str, str] | None:
    raw = request.cookies.get(FLASH_COOKIE)
    if not raw:
        return None
    try:
        return signer.loads(raw)
    except BadSignature:
        return None


async def _call(session: Session, fn, *args, **kwargs):
    """Call a Grimmory method; refresh the token once on 401."""
    try:
        return await fn(session.tokens.access, *args, **kwargs)
    except AuthError:
        session.tokens = await grimmory.refresh(session.tokens.refresh)
        session.dirty = True
        return await fn(session.tokens.access, *args, **kwargs)


def _login_redirect(request: Request) -> RedirectResponse:
    next_url = request.url.path
    if request.url.query:
        next_url += "?" + request.url.query
    return RedirectResponse(f"/login?next={quote(next_url, safe='')}", status_code=303)


def _render(request: Request, name: str, session: Session | None, **ctx: Any) -> HTMLResponse:
    flash = _pop_flash(request)
    response = templates.TemplateResponse(request, name, {
        "user": session.user if session else None,
        "flash": flash,
        "grimmory_public_url": settings.grimmory_public_url,
        **ctx,
    })
    if flash:
        response.delete_cookie(FLASH_COOKIE)
    if session and session.dirty:
        _write_session(response, session)
    return response


# ------------------------------------------------------------------- views

@app.get("/login", response_class=HTMLResponse)
async def login_form(request: Request, next: str = "/"):
    return _render(request, "login.html", None, next=next, error=None)


@app.post("/login")
async def login(request: Request, username: str = Form(...), password: str = Form(...), next: str = Form("/")):
    try:
        tokens = await grimmory.login(username.strip(), password)
        user = await grimmory.me(tokens.access)
    except AuthError as e:
        return _render(request, "login.html", None, next=next, error=str(e))
    except (GrimmoryError, Exception):
        return _render(request, "login.html", None, next=next, error="Could not reach the library server. Try again in a moment.")
    session = Session({"access": tokens.access, "refresh": tokens.refresh, "user": user.__dict__, "kindle_shelf_id": None})
    session.kindle_shelf_id = await _find_kindle_shelf(session)
    target = next if next.startswith("/") and not next.startswith("//") else "/"
    response = RedirectResponse(target, status_code=303)
    _write_session(response, session)
    return response


@app.post("/logout")
async def logout():
    response = RedirectResponse("/login", status_code=303)
    _clear_session(response)
    return response


@app.get("/")
async def home():
    return RedirectResponse("/library", status_code=303)


@app.get("/library", response_class=HTMLResponse)
async def library(request: Request, q: str = "", view: str = "all", cursor: str | None = None):
    session = _read_session(request)
    if not session:
        return _login_redirect(request)
    try:
        if session.kindle_shelf_id is None:
            session.kindle_shelf_id = await _find_kindle_shelf(session)
            session.dirty = session.kindle_shelf_id is not None

        kindle_ids: set[int] = set()
        if session.kindle_shelf_id is not None:
            shelf_books = await _call(session, grimmory.shelf_books, session.kindle_shelf_id)
            kindle_ids = {int(b["id"]) for b in shelf_books}

        next_cursor = None
        total = None
        if view == "kindle":
            raw_books = shelf_books if session.kindle_shelf_id is not None else []
            if q:
                needle = q.lower()
                raw_books = [b for b in raw_books if needle in _title(b).lower() or needle in _authors(b).lower()]
            total = len(raw_books)
        else:
            page = await _call(session, grimmory.books_page, query=q or None, cursor=cursor, size=settings.page_size)
            raw_books = page.get("content") or []
            meta = page.get("page") or {}
            total = meta.get("totalElements")
            for link in page.get("links") or []:
                if link.get("rel") == "next" and link.get("href"):
                    next_cursor = _cursor_from(link["href"])
    except AuthError:
        response = _login_redirect(request)
        _clear_session(response)
        return response
    except GrimmoryError as e:
        return _render(request, "error.html", session, message=str(e))

    books = [_card(b, kindle_ids) for b in raw_books]
    store.touch_person(session.user.id, session.user.username, session.user.name, session.kindle_shelf_id, len(kindle_ids))
    return _render(request, "library.html", session, books=books, q=q, view=view, total=total,
                   kindle_count=len(kindle_ids), next_cursor=next_cursor,
                   kindle_shelf_missing=session.kindle_shelf_id is None,
                   kindle_shelf_name=settings.kindle_shelf_name)


@app.post("/books/{book_id}/kindle")
async def toggle_kindle(request: Request, book_id: int, on: str = Form("1"), back: str = Form("/library")):
    session = _read_session(request)
    if not session:
        return _login_redirect(request)
    target = back if back.startswith("/") and not back.startswith("//") else "/library"
    response = RedirectResponse(target, status_code=303)
    if session.kindle_shelf_id is None:
        session.kindle_shelf_id = await _find_kindle_shelf(session)
        if session.kindle_shelf_id is None:
            _flash(response, f"You don't have a \"{settings.kindle_shelf_name}\" shelf yet. Create it first.", "warn")
            return response
    try:
        await _call(session, grimmory.set_shelf, book_id, session.kindle_shelf_id, on=(on == "1"))
        _flash(response, "Added to your Kindle. It arrives the next time it wakes up." if on == "1"
               else "Removed from your Kindle. It disappears the next time it syncs.")
    except AuthError:
        response = _login_redirect(request)
        _clear_session(response)
        return response
    except GrimmoryError as e:
        _flash(response, str(e), "warn")
    if session.dirty:
        _write_session(response, session)
    return response


@app.post("/kindle-shelf")
async def create_kindle_shelf(request: Request):
    session = _read_session(request)
    if not session:
        return _login_redirect(request)
    response = RedirectResponse("/library", status_code=303)
    try:
        shelf = await _call(session, grimmory.create_shelf, settings.kindle_shelf_name)
        session.kindle_shelf_id = int(shelf["id"])
        session.dirty = True
        _flash(response, f"Your \"{settings.kindle_shelf_name}\" shelf is ready. Point Shelf Sync on your Kindle at it.")
    except (GrimmoryError, AuthError) as e:
        _flash(response, str(e), "warn")
    if session.dirty:
        _write_session(response, session)
    return response


@app.get("/cover/{book_id}")
async def cover(request: Request, book_id: int):
    session = _read_session(request)
    if not session:
        return Response(status_code=401)
    r = await grimmory.thumbnail(session.tokens.access, book_id)
    if r.status_code == 401:
        try:
            session.tokens = await grimmory.refresh(session.tokens.refresh)
        except AuthError:
            return Response(status_code=401)
        r = await grimmory.thumbnail(session.tokens.access, book_id)
    if r.status_code != 200:
        return Response(content=_placeholder_cover(request.query_params.get("t") or "Book"), media_type="image/svg+xml",
                        headers={"Cache-Control": "private, max-age=3600"})
    return Response(content=r.content, media_type=r.headers.get("content-type", "image/jpeg"),
                    headers={"Cache-Control": "private, max-age=86400"})


@app.get("/search", response_class=HTMLResponse)
async def search_page(request: Request, q: str = ""):
    session = _read_session(request)
    if not session:
        return _login_redirect(request)
    q = q.strip()
    results, error = [], None
    if q:
        try:
            body = await shelfmark.search(q)
            results = [_search_hit(b) for b in body.get("books") or []]
        except ShelfmarkError as e:
            error = str(e)
    return _render(request, "search.html", session, q=q, results=results, error=error,
                   enabled=shelfmark.enabled)


@app.get("/search/copies", response_class=HTMLResponse)
async def copies_page(request: Request, provider: str, book_id: str, title: str = "", author: str = "", q: str = ""):
    session = _read_session(request)
    if not session:
        return _login_redirect(request)
    releases, book, error, notes = [], None, None, []
    try:
        body = await shelfmark.releases(provider, book_id, title=title, author=author)
        book = _search_hit(body.get("book") or {"title": title, "authors": [author], "provider": provider, "provider_id": book_id})
        releases = [_release_view(r) for r in body.get("releases") or []]
        releases.sort(key=lambda r: r["rank"])
        notes = [str(e) for e in body.get("errors") or []]
    except ShelfmarkError as e:
        error = str(e)
    return _render(request, "copies.html", session, q=q, book=book, releases=releases, error=error, notes=notes)


@app.post("/downloads")
async def start_download(request: Request, release: str = Form(...), q: str = Form("")):
    session = _read_session(request)
    if not session:
        return _login_redirect(request)
    response = RedirectResponse("/downloads", status_code=303)
    try:
        payload = json.loads(release)
        if not isinstance(payload, dict) or not payload.get("source") or not payload.get("source_id"):
            raise ValueError("bad release")
    except ValueError:
        _flash(response, "That copy couldn't be queued (bad release data).", "warn")
        return response
    try:
        await shelfmark.download(payload)
    except ShelfmarkError as e:
        _flash(response, str(e), "warn")
        return response
    store.add_download(str(payload["source_id"]), session.user.id, session.user.name or session.user.username,
                       str(payload.get("title") or "Untitled"), _author_of(payload), str(payload.get("source") or ""),
                       payload.get("format"), payload.get("size"))
    _flash(response, f"Queued \"{payload.get('title') or 'the book'}\". It lands in the library when it finishes.")
    return response


@app.get("/downloads", response_class=HTMLResponse)
async def downloads_page(request: Request):
    session = _read_session(request)
    if not session:
        return _login_redirect(request)
    mine = store.list_downloads(None if session.user.is_admin else session.user.id)
    live: dict[str, dict[str, Any]] = {}
    error = None
    if mine and shelfmark.enabled:
        try:
            status = await shelfmark.status()
            for bucket, tasks in (status or {}).items():
                if isinstance(tasks, dict):
                    for task_id, task in tasks.items():
                        if isinstance(task, dict):
                            live[str(task_id)] = {**task, "bucket": bucket}
        except ShelfmarkError as e:
            error = str(e)
    rows = [_download_row(d, live.get(d["task_id"])) for d in mine]
    for row in rows:
        if row["status"] != row["stored_status"]:
            store.update_status(row["task_id"], row["status"], row["message"])
    active = [r for r in rows if r["is_active"]]
    done = [r for r in rows if not r["is_active"]]
    return _render(request, "downloads.html", session, in_progress=active, finished=done, error=error,
                   everyone=session.user.is_admin, enabled=shelfmark.enabled)


@app.post("/downloads/{task_id}/cancel")
async def cancel_download(request: Request, task_id: str):
    return await _download_action(request, task_id, "cancel")


@app.post("/downloads/{task_id}/retry")
async def retry_download(request: Request, task_id: str):
    return await _download_action(request, task_id, "retry")


async def _download_action(request: Request, task_id: str, action: str):
    session = _read_session(request)
    if not session:
        return _login_redirect(request)
    response = RedirectResponse("/downloads", status_code=303)
    row = store.get(task_id)
    if not row or (row["user_id"] != session.user.id and not session.user.is_admin):
        _flash(response, "That download isn't yours.", "warn")
        return response
    try:
        if action == "cancel":
            await shelfmark.cancel(task_id)
            store.update_status(task_id, "cancelled", None)
            _flash(response, "Cancelled.")
        else:
            await shelfmark.retry(task_id)
            store.update_status(task_id, "queued", None)
            _flash(response, "Retrying.")
    except ShelfmarkError as e:
        _flash(response, str(e), "warn")
    return response


@app.get("/scover")
async def shelfmark_cover(request: Request, u: str):
    """Proxy a Shelfmark-cached cover (its /api/covers/... needs the API key)."""
    session = _read_session(request)
    if not session:
        return Response(status_code=401)
    if not u.startswith("/api/covers/"):
        return Response(status_code=404)
    r = await shelfmark.cover(u)
    if r.status_code != 200:
        return Response(status_code=404)
    return Response(content=r.content, media_type=r.headers.get("content-type", "image/jpeg"),
                    headers={"Cache-Control": "private, max-age=86400"})


@app.get("/settings", response_class=HTMLResponse)
async def settings_page(request: Request):
    session = _read_session(request)
    if not session:
        return _login_redirect(request)
    if not session.user.is_admin:
        return RedirectResponse("/library", status_code=303)

    # Sources
    grimmory_info: dict[str, Any] = {"ok": False}
    try:
        ver = await _call(session, grimmory.version)
        page = await _call(session, grimmory.books_page, size=1)
        users = await _call(session, grimmory.users)
        grimmory_info = {"ok": True, "version": ver.get("current"), "latest": ver.get("latest"),
                         "books": (page.get("page") or {}).get("totalElements"), "users": len(users)}
    except (AuthError, GrimmoryError) as e:
        grimmory_info = {"ok": False, "error": str(e)}
        users = []

    shelf_info: dict[str, Any] = {"ok": False, "configured": shelfmark.enabled}
    mirrors: list[str] = []
    primary = "auto"
    mirror_error = None
    queue_counts: dict[str, int] = {}
    if shelfmark.enabled:
        shelf_info["ok"] = await shelfmark.health()
        try:
            mirrors, primary = await health.read_mirrors()
        except ShelfmarkError as e:
            mirror_error = str(e)
        try:
            status = await shelfmark.status()
            queue_counts = {k: len(v) for k, v in (status or {}).items() if isinstance(v, dict) and v}
        except ShelfmarkError:
            pass

    mh = store.mirror_health()
    mirror_rows = []
    for u in mirrors:
        h = mh.get(u)
        mirror_rows.append({
            "url": u, "primary": u == primary, "checked": bool(h),
            "ok": bool(h and h["ok"]), "ms": h and h.get("ms"), "error": h and h.get("error"),
            "failing_for": _mins_since(h["failing_since"]) if h and h.get("failing_since") else None,
        })
    all_down, since = health.all_down()
    last_run = store.get_kv("last_health_run")

    # People
    people_rows = []
    seen = store.people()
    for u in users:
        perms = u.get("permissions") or {}
        admin = bool(perms.get("admin") or perms.get("isAdmin"))
        p = seen.get(int(u["id"]), {})
        people_rows.append({
            "name": u.get("name") or u.get("username"), "username": u.get("username"), "admin": admin,
            "download": admin or bool(perms.get("canDownload")), "delete": admin or bool(perms.get("canDeleteBook")),
            "kindle": (f"{p.get('kindle_count')} book{'s' if p.get('kindle_count') != 1 else ''}" if p.get("kindle_shelf_id") else None),
            "last_seen": _ago(p.get("last_seen")) if p.get("last_seen") else "never used the site",
        })

    return _render(request, "settings.html", session, grimmory=grimmory_info, shelf=shelf_info,
                   mirrors=mirror_rows, primary=primary, mirror_error=mirror_error, all_down=all_down,
                   down_for=_mins_since(since) if since else None, queue=queue_counts,
                   last_run=_ago(float(last_run)) if last_run else None, people=people_rows,
                   webhook=bool(settings.alert_webhook_url), interval=settings.health_interval_min,
                   alert_after=settings.alert_after_min, last_alert=_last_alert())


@app.post("/settings/mirrors")
async def save_mirrors(request: Request, urls: str = Form(""), primary: str = Form("auto")):
    session = _read_session(request)
    if not session:
        return _login_redirect(request)
    response = RedirectResponse("/settings", status_code=303)
    if not session.user.is_admin:
        return response
    mirrors = normalize_urls(urls)
    primary = primary.strip().rstrip("/")
    try:
        await health.write_mirrors(mirrors, primary if primary in mirrors else "auto")
        await health.run_once()
        _flash(response, f"Saved {len(mirrors)} mirror(s) to Shelfmark and tested them.")
    except ShelfmarkError as e:
        _flash(response, str(e), "warn")
    return response


@app.post("/settings/check")
async def check_now(request: Request):
    session = _read_session(request)
    if not session:
        return _login_redirect(request)
    response = RedirectResponse("/settings", status_code=303)
    if session.user.is_admin:
        try:
            await health.run_once()
            _flash(response, "Checked all mirrors and services.")
        except ShelfmarkError as e:
            _flash(response, str(e), "warn")
    return response


@app.post("/settings/test-alert")
async def test_alert(request: Request):
    session = _read_session(request)
    if not session:
        return _login_redirect(request)
    response = RedirectResponse("/settings", status_code=303)
    if session.user.is_admin:
        ok = await health.notify("Connecto Library: test alert", "If you can read this, alerts work.", "default")
        _flash(response, "Test alert sent." if ok else "No alert went out. Set ALERT_WEBHOOK_URL in the site's settings file.", "ok" if ok else "warn")
    return response


@app.get("/books/{book_id}/delete", response_class=HTMLResponse)
async def delete_confirm(request: Request, book_id: int, back: str = "/library"):
    session = _read_session(request)
    if not session:
        return _login_redirect(request)
    if not session.user.can_delete:
        return RedirectResponse("/library", status_code=303)
    try:
        book = await _call(session, grimmory.book, book_id)
    except (AuthError, GrimmoryError) as e:
        return _render(request, "error.html", session, message=str(e))
    return _render(request, "delete.html", session, book=_card(book, set()), back=back)


@app.post("/books/{book_id}/delete")
async def delete_book(request: Request, book_id: int, back: str = Form("/library")):
    session = _read_session(request)
    if not session:
        return _login_redirect(request)
    target = back if back.startswith("/") and not back.startswith("//") else "/library"
    response = RedirectResponse(target, status_code=303)
    if not session.user.can_delete:
        _flash(response, "Only an admin can delete books.", "warn")
        return response
    try:
        await _call(session, grimmory.delete_books, [book_id])
        _flash(response, "Deleted from the library. Every Kindle drops it at its next sync.")
    except (AuthError, GrimmoryError) as e:
        _flash(response, str(e), "warn")
    if session.dirty:
        _write_session(response, session)
    return response


@app.get("/healthz")
async def healthz():
    return {"ok": True}


# ----------------------------------------------------------------- helpers

async def _find_kindle_shelf(session: Session) -> int | None:
    shelves = await _call(session, grimmory.shelves)
    wanted = settings.kindle_shelf_name.lower()
    for shelf in shelves:
        if str(shelf.get("name", "")).strip().lower() == wanted:
            return int(shelf["id"])
    return None


def _title(book: dict[str, Any]) -> str:
    meta = book.get("metadata") or {}
    return meta.get("title") or book.get("title") or (book.get("primaryFile") or {}).get("fileName") or "Untitled"


def _authors(book: dict[str, Any]) -> str:
    meta = book.get("metadata") or {}
    authors = meta.get("authors") or []
    return ", ".join(a for a in authors if a)


def _progress(book: dict[str, Any]) -> int | None:
    for key in ("koreaderProgress", "epubProgress", "pdfProgress", "cbxProgress"):
        p = book.get(key) or {}
        pct = p.get("percentage")
        if isinstance(pct, (int, float)) and pct > 0:
            return int(round(pct))
    return None


def _reader_path(book: dict[str, Any]) -> str:
    kind = str((book.get("primaryFile") or {}).get("bookType") or "").upper()
    if kind == "PDF":
        return f"/pdf-reader/book/{book['id']}"
    if kind == "CBX":
        return f"/cbx-reader/book/{book['id']}"
    if kind == "AUDIOBOOK":
        return f"/audiobook-player/book/{book['id']}"
    return f"/ebook-reader/book/{book['id']}"


def _card(book: dict[str, Any], kindle_ids: set[int]) -> dict[str, Any]:
    pf = book.get("primaryFile") or {}
    size_kb = pf.get("fileSizeKb")
    return {
        "id": int(book["id"]),
        "title": _title(book),
        "authors": _authors(book),
        "format": str(pf.get("bookType") or "").replace("CBX", "Comic") or "",
        "size": _size_label(size_kb),
        "on_kindle": int(book["id"]) in kindle_ids,
        "progress": _progress(book),
        "read_status": (book.get("readStatus") or "").replace("_", " ").title(),
        "reader_path": _reader_path(book),
        "added_on": (book.get("addedOn") or "")[:10],
    }


SOURCE_LABELS = {
    "direct_download": "Anna's Archive", "libgen": "LibGen", "prowlarr": "Usenet", "newznab": "Usenet",
    "irc": "IRC", "audiobookbay": "AudiobookBay",
}
ACTIVE_STATUSES = {"queued", "resolving", "locating", "downloading"}
NICE_STATUS = {"queued": "Queued", "resolving": "Finding file", "locating": "Finding file", "downloading": "Downloading",
               "complete": "In library", "error": "Failed", "cancelled": "Cancelled"}


def _author_of(obj: dict[str, Any]) -> str:
    authors = obj.get("authors")
    if isinstance(authors, list):
        return ", ".join(str(a) for a in authors if a)
    return str(obj.get("author") or "")


def _cover_src(url: str | None) -> str | None:
    if not url:
        return None
    if url.startswith("/api/covers/"):
        return "/scover?u=" + quote(url, safe="")
    return url if url.startswith("http") else None


def _search_hit(b: dict[str, Any]) -> dict[str, Any]:
    library = b.get("library") if isinstance(b.get("library"), dict) else {}
    owned = any(v == "owned" for v in library.values())
    return {
        "provider": b.get("provider") or "", "book_id": str(b.get("provider_id") or ""),
        "title": b.get("title") or "Untitled", "author": _author_of(b), "year": b.get("publish_year"),
        "publisher": b.get("publisher"), "cover": _cover_src(b.get("cover_url")), "owned": owned,
        "series": (f"{b['series_name']} #{b['series_position']:g}" if b.get("series_name") and b.get("series_position") else b.get("series_name")),
    }


def _release_view(r: dict[str, Any]) -> dict[str, Any]:
    source = str(r.get("source") or "")
    fmt = str(r.get("format") or "").upper()
    extra = r.get("extra") if isinstance(r.get("extra"), dict) else {}
    speed = str(extra.get("tier") or extra.get("speed") or "")
    label = SOURCE_LABELS.get(source, source.replace("_", " ").title())
    if r.get("indexer"):
        label = f"{label} · {r['indexer']}"
    rank = 0 if fmt == "EPUB" else 1 if fmt in ("AZW3", "MOBI", "KEPUB") else 2 if fmt == "PDF" else 3
    if source in ("prowlarr", "newznab"):
        rank += 0.5
    return {
        "title": r.get("title") or "", "source": source, "source_label": label, "format": fmt or "?",
        "size": r.get("size") or "", "language": r.get("language") or "", "speed": speed,
        "protocol": r.get("protocol") or "", "info_url": r.get("info_url"), "json": json.dumps(r), "rank": rank,
    }


def _download_row(d: dict[str, Any], live: dict[str, Any] | None) -> dict[str, Any]:
    status = str((live or {}).get("status") or d.get("last_status") or "queued").lower()
    if live and live.get("bucket") in NICE_STATUS and status not in NICE_STATUS:
        status = str(live["bucket"])
    message = (live or {}).get("status_message") or d.get("last_message")
    progress = (live or {}).get("progress")
    return {
        "task_id": d["task_id"], "title": d["title"], "author": d.get("author") or "", "by": d["username"],
        "source_label": SOURCE_LABELS.get(d.get("source") or "", (d.get("source") or "").title()),
        "format": (d.get("format") or "").upper(), "size": d.get("size") or "",
        "status": status, "stored_status": d.get("last_status"), "nice": NICE_STATUS.get(status, status.title()),
        "message": message, "progress": int(progress) if isinstance(progress, (int, float)) else None,
        "is_active": status in ACTIVE_STATUSES, "failed": status == "error",
        "retry": bool((live or {}).get("retry_available")) or status == "error",
        "when": __import__("datetime").datetime.fromtimestamp(d["requested_at"]).strftime("%b %d, %H:%M"),
    }


def _mins_since(ts: float | None) -> int | None:
    import time as _t
    return int((_t.time() - ts) / 60) if ts else None


def _ago(ts: float | None) -> str:
    if not ts:
        return "never"
    import time as _t
    m = int((_t.time() - ts) / 60)
    if m < 1:
        return "just now"
    if m < 60:
        return f"{m} min ago"
    if m < 60 * 48:
        return f"{m // 60} h ago"
    return f"{m // (60 * 24)} days ago"


def _last_alert() -> str | None:
    raw = store.get_kv("last_alert")
    if not raw or "|" not in raw:
        return None
    ts, title = raw.split("|", 1)
    return f"{title} ({_ago(float(ts))})"


def _placeholder_cover(title: str) -> str:
    """A simple SVG tile with the title, used when Grimmory has no cover image."""
    from html import escape
    words = escape(title[:60])
    lines, line = [], ""
    for w in words.split():
        if len(line) + len(w) + 1 > 16 and line:
            lines.append(line)
            line = w
        else:
            line = (line + " " + w).strip()
    if line:
        lines.append(line)
    lines = lines[:4]
    text = "".join(f'<tspan x="16" dy="{"0" if i == 0 else "1.25em"}">{l}</tspan>' for i, l in enumerate(lines))
    y = 190 - (len(lines) - 1) * 20
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 160 240">'
            f'<rect width="160" height="240" fill="#0F6E8C"/>'
            f'<text x="16" y="{y}" fill="#FFFFFF" font-family="Manrope, system-ui, sans-serif" font-size="15" font-weight="700">{text}</text>'
            f'</svg>')


def _size_label(size_kb: Any) -> str:
    if not isinstance(size_kb, (int, float)) or size_kb <= 0:
        return ""
    return f"{size_kb / 1024:.1f} MB" if size_kb >= 1024 else f"{int(size_kb)} KB"


def _cursor_from(href: str) -> str | None:
    from urllib.parse import parse_qs, urlparse
    return (parse_qs(urlparse(href).query).get("cursor") or [None])[0]


@app.on_event("startup")
async def _startup() -> None:
    if shelfmark.enabled:
        health.start()


@app.on_event("shutdown")
async def _shutdown() -> None:
    await health.stop()
    await grimmory.aclose()
    await shelfmark.aclose()

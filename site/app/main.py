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

BASE = Path(__file__).parent
settings = Settings.from_env()
grimmory = Grimmory(settings.grimmory_url)
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
async def search_page(request: Request):
    session = _read_session(request)
    if not session:
        return _login_redirect(request)
    return _render(request, "coming.html", session, section="search", heading="Search",
                   blurb="One box that checks Anna's Archive and usenet together, with a Download button per result.")


@app.get("/downloads", response_class=HTMLResponse)
async def downloads_page(request: Request):
    session = _read_session(request)
    if not session:
        return _login_redirect(request)
    return _render(request, "coming.html", session, section="downloads", heading="Downloads",
                   blurb="Your downloads with progress, retry, and a link to the book once it's in the library.")


@app.get("/settings", response_class=HTMLResponse)
async def settings_page(request: Request):
    session = _read_session(request)
    if not session:
        return _login_redirect(request)
    if not session.user.is_admin:
        return RedirectResponse("/library", status_code=303)
    return _render(request, "coming.html", session, section="settings", heading="Settings",
                   blurb="Source health, the Anna's Archive mirror list, and the people-and-Kindles table.")


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


@app.on_event("shutdown")
async def _shutdown() -> None:
    await grimmory.aclose()

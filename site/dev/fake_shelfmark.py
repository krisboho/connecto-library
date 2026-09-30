"""A stand-in for Shelfmark's API, for local development only.

Mimics the handful of endpoints the site uses, with canned results and a
download that "progresses" over ~12 seconds. Run: uvicorn dev.fake_shelfmark:app --port 18084
"""
from __future__ import annotations

import time

from fastapi import FastAPI, Header, HTTPException, Request

app = FastAPI()
KEY = "fake-key"
BOOKS = [
    {"provider": "openlibrary", "provider_id": "OL1", "title": "Project Hail Mary", "authors": ["Andy Weir"],
     "publish_year": 2021, "publisher": "Ballantine", "cover_url": None, "library": {"ebook": None}},
    {"provider": "openlibrary", "provider_id": "OL2", "title": "The Martian", "authors": ["Andy Weir"],
     "publish_year": 2014, "publisher": "Crown", "cover_url": None, "library": {"ebook": "owned"}},
    {"provider": "openlibrary", "provider_id": "OL3", "title": "Artemis", "authors": ["Andy Weir"],
     "publish_year": 2017, "cover_url": None, "series_name": "Standalone", "library": {"ebook": None}},
]
tasks: dict[str, dict] = {}


def _auth(x_api_key: str | None) -> None:
    if x_api_key != KEY:
        raise HTTPException(401, {"error": "Unauthorized"})


@app.get("/api/health")
def health():
    return {"ok": True}


@app.get("/api/metadata/search")
def search(query: str, x_api_key: str | None = Header(default=None)):
    _auth(x_api_key)
    q = query.lower()
    hits = [b for b in BOOKS if q in b["title"].lower() or any(q in a.lower() for a in b["authors"])]
    return {"books": hits, "provider": "openlibrary", "query": query, "page": 1, "total_found": len(hits), "has_more": False}


@app.get("/api/releases")
def releases(provider: str, book_id: str, title: str = "", author: str = "", x_api_key: str | None = Header(default=None)):
    _auth(x_api_key)
    book = next((b for b in BOOKS if b["provider_id"] == book_id), None) or {"title": title, "authors": [author], "provider": provider, "provider_id": book_id}
    base = book["title"]
    rels = [
        {"source": "direct_download", "source_id": f"md5-{book_id}-a", "title": f"{base} - {book['authors'][0]}.epub", "format": "epub", "size": "1.9 MB", "language": "en", "extra": {"tier": "fast"}},
        {"source": "prowlarr", "source_id": f"guid-{book_id}-b", "title": f"{base.replace(' ', '.')}.2021.Retail.EPUB-NODE", "format": "epub", "size": "4.2 MB", "language": "en", "indexer": "NZBGeek", "protocol": "usenet"},
        {"source": "direct_download", "source_id": f"md5-{book_id}-c", "title": f"{base}.pdf", "format": "pdf", "size": "9.1 MB", "language": "en", "extra": {"tier": "slow"}},
    ]
    return {"releases": rels, "book": book, "sources_searched": ["direct_download", "prowlarr"], "errors": ["irc: not configured"]}


@app.post("/api/releases/download")
async def download(request: Request, x_api_key: str | None = Header(default=None)):
    _auth(x_api_key)
    data = await request.json()
    tid = data["source_id"]
    tasks[tid] = {"id": tid, "title": data.get("title"), "author": None, "format": data.get("format"), "size": data.get("size"),
                  "source": data["source"], "added_time": time.time(), "fail": tid.endswith("-c")}
    return {"status": "queued", "priority": 0}


def _bucket(t: dict) -> tuple[str, dict]:
    age = time.time() - t["added_time"]
    if t.get("cancelled"):
        return "cancelled", {**t, "status": "cancelled", "progress": 0}
    if age < 2:
        return "queued", {**t, "status": "queued", "progress": 0}
    if age < 5:
        return "resolving", {**t, "status": "resolving", "progress": 0, "status_message": "Looking up the file"}
    if age < 12:
        return "downloading", {**t, "status": "downloading", "progress": int((age - 5) / 7 * 100)}
    if t["fail"]:
        return "error", {**t, "status": "error", "progress": 0, "status_message": "Mirror timed out twice", "retry_available": True}
    return "complete", {**t, "status": "complete", "progress": 100}


@app.get("/api/status")
def status(x_api_key: str | None = Header(default=None)):
    _auth(x_api_key)
    out: dict[str, dict] = {}
    for tid, t in tasks.items():
        bucket, view = _bucket(t)
        out.setdefault(bucket, {})[tid] = view
    return out


@app.delete("/api/download/{tid}/cancel")
def cancel(tid: str, x_api_key: str | None = Header(default=None)):
    _auth(x_api_key)
    if tid not in tasks:
        raise HTTPException(404, {"error": "not found"})
    tasks[tid]["cancelled"] = True
    return {"status": "cancelled"}


@app.post("/api/download/{tid}/retry")
def retry(tid: str, x_api_key: str | None = Header(default=None)):
    _auth(x_api_key)
    if tid not in tasks:
        raise HTTPException(404, {"error": "not found"})
    tasks[tid].update({"added_time": time.time(), "fail": False, "cancelled": False})
    return {"status": "queued"}

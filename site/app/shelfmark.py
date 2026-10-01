"""Client for Shelfmark's JSON API (v1.4.0+, API-key auth).

  GET  /api/metadata/search?query=        -> {books: [...], has_more, ...}
  GET  /api/releases?provider=&book_id=   -> {releases: [...], book, errors?}
  POST /api/releases/download  (one release object) -> {status: "queued"}
  GET  /api/status                        -> {queued: {id: task}, downloading: {...}, complete: {...}, error: {...}, ...}
  DELETE /api/download/{id}/cancel
  POST /api/download/{id}/retry
  GET  /api/covers/{id}?url=              -> image (cached cover proxy)

The API key is root-equivalent on Shelfmark; it never leaves the server.
"""
from __future__ import annotations

from typing import Any

import httpx


class ShelfmarkError(Exception):
    pass


class Shelfmark:
    def __init__(self, base_url: str, api_key: str, timeout: float = 90.0) -> None:
        self.base_url = base_url.rstrip("/")
        self.enabled = bool(base_url and api_key)
        self._client = httpx.AsyncClient(base_url=self.base_url, timeout=timeout,
                                         headers={"X-Api-Key": api_key} if api_key else {})

    async def aclose(self) -> None:
        await self._client.aclose()

    async def search(self, query: str, *, limit: int = 30) -> dict[str, Any]:
        return await self._json("GET", "/api/metadata/search", params={"query": query, "limit": limit})

    async def releases(self, provider: str, book_id: str, *, title: str = "", author: str = "") -> dict[str, Any]:
        params = {"provider": provider, "book_id": book_id, "content_type": "ebook"}
        if title:
            params["title"] = title
        if author:
            params["author"] = author
        return await self._json("GET", "/api/releases", params=params)

    async def download(self, release: dict[str, Any]) -> dict[str, Any]:
        return await self._json("POST", "/api/releases/download", json=release)

    async def status(self) -> dict[str, dict[str, Any]]:
        return await self._json("GET", "/api/status")

    async def cancel(self, task_id: str) -> None:
        await self._json("DELETE", f"/api/download/{task_id}/cancel")

    async def retry(self, task_id: str) -> None:
        await self._json("POST", f"/api/download/{task_id}/retry")

    async def get_settings_tab(self, tab: str) -> dict[str, Any]:
        return await self._json("GET", f"/api/settings/{tab}")

    async def put_settings_tab(self, tab: str, values: dict[str, Any]) -> dict[str, Any]:
        return await self._json("PUT", f"/api/settings/{tab}", json=values)

    async def cover(self, path_and_query: str) -> httpx.Response:
        return await self._client.get(path_and_query, timeout=30.0)

    async def health(self) -> bool:
        try:
            r = await self._client.get("/api/health", timeout=5.0)
            return r.status_code == 200
        except httpx.HTTPError:
            return False

    async def _json(self, method: str, path: str, **kw: Any) -> Any:
        if not self.enabled:
            raise ShelfmarkError("Search isn't set up yet: the site has no Shelfmark address or API key.")
        try:
            r = await self._client.request(method, path, **kw)
        except httpx.HTTPError as e:
            raise ShelfmarkError(f"Could not reach the search service ({e.__class__.__name__}).") from e
        if r.status_code == 401:
            raise ShelfmarkError("The search service rejected the site's API key.")
        try:
            body = r.json()
        except ValueError:
            body = None
        if r.status_code >= 400:
            msg = body.get("message") or body.get("error") if isinstance(body, dict) else None
            raise ShelfmarkError(msg or f"Search service error {r.status_code}.")
        return body

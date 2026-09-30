"""A small client for the parts of Grimmory's API the site uses.

Grimmory (community fork of BookLore) v3.5.0 endpoints:
  POST /api/v1/auth/login                 -> accessToken, refreshToken
  POST /api/v1/auth/refresh               -> new tokens
  GET  /api/v1/users/me                   -> user + permissions
  GET  /api/v1/books/page                 -> browse (query, sort, cursor)
  GET  /api/v1/shelves                    -> the user's shelves
  GET  /api/v1/shelves/{id}/books         -> books on a shelf
  POST /api/v1/shelves                    -> create a shelf
  POST /api/v1/books/shelves              -> assign / unassign shelves
  GET  /api/v1/media/book/{id}/thumbnail  -> cover image
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import httpx


class AuthError(Exception):
    """Login failed or the session can no longer be refreshed."""


class GrimmoryError(Exception):
    """Grimmory answered with an error."""


@dataclass
class Tokens:
    access: str
    refresh: str


@dataclass
class User:
    id: int
    username: str
    name: str
    is_admin: bool
    can_download: bool
    can_delete: bool


class Grimmory:
    def __init__(self, base_url: str, timeout: float = 20.0) -> None:
        self.base_url = base_url.rstrip("/")
        self._client = httpx.AsyncClient(base_url=self.base_url, timeout=timeout)

    async def aclose(self) -> None:
        await self._client.aclose()

    # -- auth ---------------------------------------------------------------

    async def login(self, username: str, password: str) -> Tokens:
        r = await self._client.post("/api/v1/auth/login", json={"username": username, "password": password})
        if r.status_code != 200:
            raise AuthError(_message(r, "Wrong username or password"))
        body = r.json()
        return Tokens(access=body["accessToken"], refresh=body["refreshToken"])

    async def refresh(self, refresh_token: str) -> Tokens:
        r = await self._client.post("/api/v1/auth/refresh", json={"refreshToken": refresh_token})
        if r.status_code != 200:
            raise AuthError("Session expired, please log in again")
        body = r.json()
        return Tokens(access=body["accessToken"], refresh=body.get("refreshToken") or refresh_token)

    async def me(self, access: str) -> User:
        body = await self._get("/api/v1/users/me", access)
        perms = body.get("permissions") or {}
        return User(
            id=int(body["id"]),
            username=body.get("username") or "",
            name=body.get("name") or body.get("username") or "",
            is_admin=bool(perms.get("admin") or perms.get("isAdmin")),
            can_download=bool(perms.get("admin") or perms.get("isAdmin") or perms.get("canDownload")),
            can_delete=bool(perms.get("admin") or perms.get("isAdmin") or perms.get("canDeleteBook")),
        )

    # -- books --------------------------------------------------------------

    async def books_page(self, access: str, *, query: str | None = None, cursor: str | None = None,
                         size: int = 48, sort: str = "-addedOn") -> dict[str, Any]:
        params: dict[str, Any] = {"size": size, "sort": sort}
        if query:
            params["query"] = query
        if cursor:
            params["cursor"] = cursor
        return await self._get("/api/v1/books/page", access, params=params)

    async def shelf_books(self, access: str, shelf_id: int) -> list[dict[str, Any]]:
        return await self._get(f"/api/v1/shelves/{int(shelf_id)}/books", access)

    async def thumbnail(self, access: str, book_id: int) -> httpx.Response:
        return await self._client.get(f"/api/v1/media/book/{int(book_id)}/thumbnail",
                                      headers=_auth(access))

    # -- shelves ------------------------------------------------------------

    async def shelves(self, access: str) -> list[dict[str, Any]]:
        return await self._get("/api/v1/shelves", access)

    async def create_shelf(self, access: str, name: str) -> dict[str, Any]:
        r = await self._client.post("/api/v1/shelves", headers=_auth(access),
                                    json={"name": name, "icon": "tablet-smartphone", "iconType": "LUCIDE", "publicShelf": False})
        if r.status_code not in (200, 201):
            raise GrimmoryError(_message(r, "Could not create the shelf"))
        return r.json()

    async def set_shelf(self, access: str, book_id: int, shelf_id: int, *, on: bool) -> None:
        payload = {
            "bookIds": [int(book_id)],
            "shelvesToAssign": [int(shelf_id)] if on else [],
            "shelvesToUnassign": [] if on else [int(shelf_id)],
        }
        r = await self._client.post("/api/v1/books/shelves", headers=_auth(access), json=payload)
        if r.status_code not in (200, 204):
            raise GrimmoryError(_message(r, "Could not update the shelf"))

    # -- helpers ------------------------------------------------------------

    async def _get(self, path: str, access: str, params: dict[str, Any] | None = None) -> Any:
        r = await self._client.get(path, headers=_auth(access), params=params)
        if r.status_code == 401:
            raise AuthError("unauthorized")
        if r.status_code != 200:
            raise GrimmoryError(_message(r, f"Grimmory returned {r.status_code} for {path}"))
        return r.json()


def _auth(access: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {access}"}


def _message(r: httpx.Response, fallback: str) -> str:
    try:
        body = r.json()
        if isinstance(body, dict):
            return str(body.get("message") or body.get("error") or fallback)
    except ValueError:
        pass
    return fallback

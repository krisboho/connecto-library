"""Background health checks: Anna's Archive mirrors, Shelfmark, Grimmory.

Runs every HEALTH_INTERVAL_MIN minutes inside the site process. Results go
to SQLite so the Settings page can show them, and a webhook fires once when
every mirror has been failing for ALERT_AFTER_MIN minutes (and once more
when they recover).
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import Any

import httpx

from .config import Settings
from .shelfmark import Shelfmark, ShelfmarkError
from .store import Store

log = logging.getLogger("connecto.health")

MIRROR_TAB = "mirrors"
MIRROR_LIST_KEY = "AA_MIRROR_URLS"
MIRROR_PRIMARY_KEY = "AA_BASE_URL"


def parse_tab(tab: dict[str, Any]) -> dict[str, Any]:
    """Pull {key: value} out of Shelfmark's serialized settings tab, whatever its exact shape."""
    values: dict[str, Any] = {}
    if isinstance(tab.get("values"), dict):
        values.update(tab["values"])
    for field in tab.get("fields") or []:
        if isinstance(field, dict) and field.get("key") is not None and "value" in field:
            values[field["key"]] = field["value"]
    for section in tab.get("sections") or []:
        for field in (section or {}).get("fields") or []:
            if isinstance(field, dict) and field.get("key") is not None and "value" in field:
                values[field["key"]] = field["value"]
    return values


def normalize_urls(raw: Any) -> list[str]:
    items: list[str] = []
    if isinstance(raw, str):
        parts = [p.strip() for p in raw.replace(",", "\n").splitlines()]
    elif isinstance(raw, list):
        parts = [str(p).strip() for p in raw]
    else:
        parts = []
    for p in parts:
        if not p:
            continue
        if not p.startswith(("http://", "https://")):
            p = "https://" + p
        p = p.rstrip("/")
        if p not in items:
            items.append(p)
    return items


class Health:
    def __init__(self, settings: Settings, store: Store, shelfmark: Shelfmark) -> None:
        self.settings = settings
        self.store = store
        self.shelfmark = shelfmark
        self.services: dict[str, dict[str, Any]] = {}
        self._task: asyncio.Task | None = None
        self._lock = asyncio.Lock()

    # -- lifecycle ------------------------------------------------------------

    def start(self) -> None:
        if self._task is None:
            self._task = asyncio.create_task(self._loop())

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            self._task = None

    async def _loop(self) -> None:
        await asyncio.sleep(5)
        while True:
            try:
                await self.run_once()
            except Exception:  # noqa: BLE001 - never let the loop die
                log.exception("health check failed")
            await asyncio.sleep(max(60, self.settings.health_interval_min * 60))

    # -- mirrors ----------------------------------------------------------------

    async def read_mirrors(self) -> tuple[list[str], str]:
        """Returns (mirror list, primary) from Shelfmark. primary is 'auto' or a URL."""
        tab = await self.shelfmark.get_settings_tab(MIRROR_TAB)
        values = parse_tab(tab)
        mirrors = normalize_urls(values.get(MIRROR_LIST_KEY))
        primary = str(values.get(MIRROR_PRIMARY_KEY) or "auto").strip().rstrip("/") or "auto"
        if primary != "auto" and primary not in mirrors:
            mirrors.insert(0, primary)
        return mirrors, primary

    async def write_mirrors(self, mirrors: list[str], primary: str) -> None:
        payload = {MIRROR_LIST_KEY: mirrors, MIRROR_PRIMARY_KEY: primary if primary in mirrors else "auto"}
        await self.shelfmark.put_settings_tab(MIRROR_TAB, payload)
        self.store.forget_mirrors_except(mirrors)

    async def check_mirror(self, url: str) -> tuple[bool, int | None, str | None]:
        started = time.monotonic()
        try:
            async with httpx.AsyncClient(timeout=12.0, follow_redirects=True,
                                         headers={"User-Agent": "Mozilla/5.0 (connecto-library health check)"}) as c:
                r = await c.get(url)
            ms = int((time.monotonic() - started) * 1000)
            # A Cloudflare challenge (403/503 with a body) still means the domain is alive.
            if r.status_code < 500 or (r.status_code == 503 and len(r.content) > 0):
                return True, ms, None
            return False, ms, f"HTTP {r.status_code}"
        except httpx.HTTPError as e:
            return False, None, e.__class__.__name__

    async def run_once(self) -> dict[str, Any]:
        async with self._lock:
            return await self._run()

    async def _run(self) -> dict[str, Any]:
        now = time.time()
        # Services
        self.services["shelfmark"] = {"ok": await self.shelfmark.health(), "at": now}
        # Mirrors
        mirrors: list[str] = []
        try:
            mirrors, _ = await self.read_mirrors()
        except ShelfmarkError as e:
            self.services["shelfmark"] = {"ok": False, "at": now, "error": str(e)}
        results = await asyncio.gather(*(self.check_mirror(u) for u in mirrors))
        for url, (ok, ms, err) in zip(mirrors, results):
            self.store.record_mirror(url, ok, ms, err)
        self.store.set_kv("last_health_run", str(now))
        if mirrors:
            await self.check_membership(mirrors)
        await self._maybe_alert(mirrors)
        await self._maybe_alert_membership()
        return {"mirrors": dict(zip(mirrors, results))}

    # -- Anna's Archive membership ------------------------------------------------

    async def check_membership(self, mirrors: list[str]) -> dict[str, Any]:
        """Ask a mirror's fast-download API about a non-existent file.

        A valid membership answers 404 "Record not found"; an invalid key 401
        "Invalid secret key"; a lapsed membership 403 "Not a member". The fake
        id means no download is ever spent.
        """
        result: dict[str, Any] = {"state": "unknown", "at": time.time()}
        try:
            key = await self.shelfmark.donator_key()
        except ShelfmarkError as e:
            result.update(state="unknown", detail=str(e))
            return result
        if not key:
            result.update(state="none", detail="No membership key in Shelfmark")
            return result
        healthy = [u for u in mirrors if (self.store.mirror_health().get(u) or {}).get("ok")] or mirrors
        for url in healthy[:2]:
            try:
                async with httpx.AsyncClient(timeout=20.0, follow_redirects=True,
                                             headers={"User-Agent": "Mozilla/5.0 (connecto-library)"}) as c:
                    r = await c.get(f"{url}/dyn/api/fast_download.json",
                                    params={"md5": "0" * 32, "key": key})
                try:
                    err = str((r.json() or {}).get("error") or "")
                except ValueError:
                    err = ""
                if r.status_code == 404 or "not found" in err.lower():
                    result.update(state="active", detail="Fast downloads available", mirror=url)
                elif r.status_code == 403 or "not a member" in err.lower():
                    result.update(state="expired", detail="Anna's Archive says: not a member (membership lapsed)", mirror=url)
                elif r.status_code == 401 or "secret key" in err.lower():
                    result.update(state="invalid", detail="Anna's Archive says: invalid secret key", mirror=url)
                else:
                    result.update(state="unknown", detail=f"Unexpected answer HTTP {r.status_code} {err[:60]}", mirror=url)
                    continue
                break
            except httpx.HTTPError as e:
                result.update(state="unknown", detail=f"Could not reach {url} ({e.__class__.__name__})")
        self.store.set_kv("membership", json.dumps(result))
        return result

    def membership(self) -> dict[str, Any] | None:
        raw = self.store.get_kv("membership")
        try:
            return json.loads(raw) if raw else None
        except ValueError:
            return None

    # -- alerts -----------------------------------------------------------------

    def all_down(self) -> tuple[bool, float | None]:
        health = self.store.mirror_health()
        if not health:
            return False, None
        if any(h["ok"] for h in health.values()):
            return False, None
        since = max((h["failing_since"] or h["checked_at"]) for h in health.values())
        return True, since

    async def _maybe_alert(self, mirrors: list[str]) -> None:
        down, since = self.all_down()
        alerted = self.store.get_kv("mirrors_alerted") == "1"
        if down and since and (time.time() - since) >= self.settings.alert_after_min * 60 and not alerted:
            mins = int((time.time() - since) / 60)
            await self.notify("Connecto Library: Anna's Archive mirrors are all down",
                              f"All {len(mirrors)} mirror(s) have failed for {mins} minutes. Update the mirror list in Settings.", "high")
            self.store.set_kv("mirrors_alerted", "1")
        elif not down and alerted:
            await self.notify("Connecto Library: mirrors are back", "At least one Anna's Archive mirror is reachable again.", "default")
            self.store.set_kv("mirrors_alerted", None)

    async def _maybe_alert_membership(self) -> None:
        m = self.membership() or {}
        bad = m.get("state") in ("expired", "invalid")
        alerted = self.store.get_kv("membership_alerted") == "1"
        if bad and not alerted:
            await self.notify("Connecto Library: Anna's Archive membership problem",
                              f"{m.get('detail')}. Fast downloads are off until the key is renewed in Shelfmark.", "high")
            self.store.set_kv("membership_alerted", "1")
        elif m.get("state") == "active" and alerted:
            await self.notify("Connecto Library: Anna's Archive membership is active again", "Fast downloads are back.", "default")
            self.store.set_kv("membership_alerted", None)

    async def notify(self, title: str, message: str, priority: str = "default") -> bool:
        url = self.settings.alert_webhook_url
        self.store.set_kv("last_alert", f"{int(time.time())}|{title}")
        if not url:
            log.warning("ALERT (no webhook configured): %s - %s", title, message)
            return False
        try:
            async with httpx.AsyncClient(timeout=15.0) as c:
                if "ntfy" in url:
                    r = await c.post(url, content=message, headers={"Title": title, "Priority": priority})
                else:
                    r = await c.post(url, json={"title": title, "message": message, "priority": priority})
            return r.status_code < 300
        except httpx.HTTPError:
            log.exception("alert webhook failed")
            return False

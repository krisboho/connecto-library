"""SQLite store: which family member asked for which download.

Shelfmark runs every download under the site's single API key, so this is
the only record of who requested what. Kept deliberately tiny.
"""
from __future__ import annotations

import sqlite3
import time
from pathlib import Path
from typing import Any

SCHEMA = """
CREATE TABLE IF NOT EXISTS downloads (
  task_id      TEXT PRIMARY KEY,
  user_id      INTEGER NOT NULL,
  username     TEXT NOT NULL,
  title        TEXT NOT NULL,
  author       TEXT,
  source       TEXT,
  format       TEXT,
  size         TEXT,
  requested_at REAL NOT NULL,
  last_status  TEXT,
  last_message TEXT,
  updated_at   REAL
);
CREATE INDEX IF NOT EXISTS downloads_user ON downloads(user_id, requested_at DESC);
"""


class Store:
    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(str(path), check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._db.executescript(SCHEMA)

    def add_download(self, task_id: str, user_id: int, username: str, title: str, author: str | None,
                     source: str | None, fmt: str | None, size: str | None) -> None:
        self._db.execute(
            "INSERT OR REPLACE INTO downloads(task_id,user_id,username,title,author,source,format,size,requested_at,last_status,updated_at)"
            " VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            (task_id, user_id, username, title, author, source, fmt, size, time.time(), "queued", time.time()))
        self._db.commit()

    def list_downloads(self, user_id: int | None, limit: int = 100) -> list[dict[str, Any]]:
        if user_id is None:
            rows = self._db.execute("SELECT * FROM downloads ORDER BY requested_at DESC LIMIT ?", (limit,))
        else:
            rows = self._db.execute("SELECT * FROM downloads WHERE user_id=? ORDER BY requested_at DESC LIMIT ?", (user_id, limit))
        return [dict(r) for r in rows]

    def get(self, task_id: str) -> dict[str, Any] | None:
        row = self._db.execute("SELECT * FROM downloads WHERE task_id=?", (task_id,)).fetchone()
        return dict(row) if row else None

    def update_status(self, task_id: str, status: str, message: str | None) -> None:
        self._db.execute("UPDATE downloads SET last_status=?, last_message=?, updated_at=? WHERE task_id=?",
                         (status, message, time.time(), task_id))
        self._db.commit()

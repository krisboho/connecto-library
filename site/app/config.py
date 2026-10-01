"""Connecto Library settings, all from environment variables."""
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    grimmory_url: str            # where the site talks to Grimmory (server-side)
    grimmory_public_url: str     # where browsers reach Grimmory (for Read online)
    session_secret: str
    kindle_shelf_name: str
    page_size: int
    secure_cookies: bool
    shelfmark_url: str
    shelfmark_api_key: str
    data_dir: str
    alert_webhook_url: str
    health_interval_min: int
    alert_after_min: int
    grimmory_url_map: str

    @classmethod
    def from_env(cls) -> "Settings":
        grimmory = os.environ.get("GRIMMORY_URL", "http://localhost:6060").rstrip("/")
        secret = os.environ.get("SESSION_SECRET", "")
        if not secret:
            raise RuntimeError("SESSION_SECRET is required (any long random string)")
        return cls(
            grimmory_url=grimmory,
            grimmory_public_url=os.environ.get("GRIMMORY_PUBLIC_URL", grimmory).rstrip("/"),
            session_secret=secret,
            kindle_shelf_name=os.environ.get("KINDLE_SHELF_NAME", "Kindle"),
            page_size=int(os.environ.get("PAGE_SIZE", "48")),
            secure_cookies=os.environ.get("SECURE_COOKIES", "false").lower() == "true",
            shelfmark_url=os.environ.get("SHELFMARK_URL", "").rstrip("/"),
            shelfmark_api_key=os.environ.get("SHELFMARK_API_KEY", ""),
            data_dir=os.environ.get("DATA_DIR", "./data"),
            alert_webhook_url=os.environ.get("ALERT_WEBHOOK_URL", ""),
            health_interval_min=int(os.environ.get("HEALTH_INTERVAL_MIN", "15")),
            alert_after_min=int(os.environ.get("ALERT_AFTER_MIN", "30")),
            grimmory_url_map=os.environ.get("GRIMMORY_URL_MAP", ""),
        )

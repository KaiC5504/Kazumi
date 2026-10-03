from __future__ import annotations

import os
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

MIN_KEY_LENGTH = 24


def utc_now() -> datetime:
    return datetime.now(UTC)


def to_iso(dt: datetime) -> str:
    return dt.astimezone(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def from_iso(value: str) -> datetime:
    dt = datetime.fromisoformat(value)
    return dt if dt.tzinfo else dt.replace(tzinfo=UTC)


class ConfigError(RuntimeError):
    pass


@dataclass(frozen=True)
class Settings:
    data_dir: Path
    view_key: str
    admin_key: str
    syncplay_endpoint: str = ""
    syncplay_room: str = ""
    # Only set once the Syncplay server has a certificate; clients that ask
    # for TLS from a plain server can't connect at all.
    syncplay_tls: bool = False
    clock: Callable[[], datetime] = field(default=utc_now, compare=False)
    # None disables the background loop; tests drive housekeeping directly.
    housekeeping_interval: float | None = 3600.0

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Settings:
        env = os.environ if env is None else env
        return cls(
            data_dir=Path(env.get("KAZUMI_LIBRARY_DATA") or "./data"),
            view_key=env.get("KAZUMI_VIEW_KEY", "").strip(),
            admin_key=env.get("KAZUMI_ADMIN_KEY", "").strip(),
            syncplay_endpoint=env.get("KAZUMI_SYNCPLAY_ENDPOINT", "").strip(),
            syncplay_room=env.get("KAZUMI_SYNCPLAY_ROOM", "").strip(),
            syncplay_tls=env.get("KAZUMI_SYNCPLAY_TLS", "").strip() == "1",
        )

    def validate(self) -> None:
        for name, key in (("KAZUMI_VIEW_KEY", self.view_key), ("KAZUMI_ADMIN_KEY", self.admin_key)):
            if len(key) < MIN_KEY_LENGTH:
                raise ConfigError(f"{name} must be set and at least {MIN_KEY_LENGTH} characters long")
        if self.view_key == self.admin_key:
            # Otherwise every invite link would carry upload/delete rights.
            raise ConfigError("KAZUMI_VIEW_KEY and KAZUMI_ADMIN_KEY must differ")

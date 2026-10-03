from __future__ import annotations

import threading
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any

from .config import to_iso

# Apps beat every 3 s and say goodbye when they can; this only catches the ones
# that couldn't (killed, crashed, lost network).
PRESENCE_TTL = timedelta(seconds=20)


@dataclass
class _Presence:
    name: str
    state: str
    episode_id: str | None
    last_seen: datetime


class Room:
    """In-memory lobby: who is around and what was last picked. Lost on restart by design."""

    def __init__(self, clock: Callable[[], datetime]) -> None:
        self._clock = clock
        self._lock = threading.Lock()
        self._devices: dict[str, _Presence] = {}
        # Seeded from the clock so picks keep counting up across restarts; apps
        # already in the lobby ignore any seq at or below the last one they saw.
        self._seq = int(clock().timestamp() * 1000)
        self._selection: dict[str, Any] | None = None

    def heartbeat(self, device_id: str, name: str, state: str, episode_id: str | None) -> dict[str, Any]:
        with self._lock:
            self._devices[device_id] = _Presence(name, state, episode_id, self._clock())
            return self._snapshot()

    def leave(self, device_id: str) -> dict[str, Any]:
        with self._lock:
            self._devices.pop(device_id, None)
            return self._snapshot()

    def select(self, device_id: str, name: str, episode_id: str) -> dict[str, Any]:
        with self._lock:
            now = self._clock()
            current = self._devices.get(device_id)
            if current is None:
                self._devices[device_id] = _Presence(name, "lobby", None, now)
            else:
                current.name = name
                current.last_seen = now
            self._seq += 1
            self._selection = {
                "seq": self._seq,
                "episodeId": episode_id,
                "by": name,
                "byDeviceId": device_id,
                "at": to_iso(now),
            }
            return self._snapshot()

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return self._snapshot()

    def _snapshot(self) -> dict[str, Any]:
        now = self._clock()
        for device_id in [d for d, p in self._devices.items() if now - p.last_seen > PRESENCE_TTL]:
            del self._devices[device_id]
        members = [
            {
                "deviceId": device_id,
                "name": p.name,
                "state": p.state,
                "episodeId": p.episode_id,
                "secondsAgo": max(0, int((now - p.last_seen).total_seconds())),
            }
            for device_id, p in sorted(self._devices.items(), key=lambda item: (item[1].name, item[0]))
        ]
        return {"members": members, "selection": dict(self._selection) if self._selection else None}

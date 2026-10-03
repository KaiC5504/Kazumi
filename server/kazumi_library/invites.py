from __future__ import annotations

import secrets
import threading
from collections import defaultdict, deque
from collections.abc import Callable
from datetime import datetime, timedelta
from pathlib import Path

from .config import from_iso, to_iso
from .library import read_json, write_json_atomic

# No 0/O, 1/I/L: the code is read aloud or typed from a chat message.
CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
CODE_LENGTH = 8
INVITE_TTL = timedelta(days=7)


def normalize_code(raw: str) -> str:
    return "".join(ch for ch in raw.upper() if ch.isalnum())


def format_code(code: str) -> str:
    return f"{code[:4]}-{code[4:]}"


class Invites:
    """Short codes that trade for the view key, so nobody has to open a link."""

    def __init__(self, path: Path, clock: Callable[[], datetime]) -> None:
        self._path = path
        self._clock = clock
        self._lock = threading.Lock()

    def create(self) -> dict[str, str]:
        with self._lock:
            now = self._clock()
            codes = self._live(now)
            code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))
            expires = now + INVITE_TTL
            codes[code] = to_iso(expires)
            write_json_atomic(self._path, {"codes": codes})
            return {"code": format_code(code), "expiresAt": to_iso(expires)}

    def is_valid(self, raw: str) -> bool:
        code = normalize_code(raw)
        if len(code) != CODE_LENGTH:
            return False
        with self._lock:
            codes = self._live(self._clock())
        # compare_digest on every live code keeps timing independent of which one matched.
        return any(secrets.compare_digest(code, known) for known in codes)

    def _live(self, now: datetime) -> dict[str, str]:
        data = read_json(self._path) if self._path.exists() else None
        codes = (data or {}).get("codes", {})
        live = {}
        for code, expires in codes.items():
            try:
                if from_iso(expires) > now:
                    live[code] = expires
            except (TypeError, ValueError):
                continue
        return live


class RateLimiter:
    """Sliding-window limit per client plus an overall cap, so codes can't be brute-forced."""

    def __init__(
        self,
        clock: Callable[[], datetime],
        per_client: int = 5,
        overall: int = 30,
        window: timedelta = timedelta(minutes=1),
    ) -> None:
        self._clock = clock
        self._per_client = per_client
        self._overall = overall
        self._window = window
        self._hits: dict[str, deque[datetime]] = defaultdict(deque)
        self._all: deque[datetime] = deque()
        self._lock = threading.Lock()

    def allow(self, client: str) -> bool:
        with self._lock:
            now = self._clock()
            cutoff = now - self._window
            hits = self._hits[client]
            for q in (hits, self._all):
                while q and q[0] <= cutoff:
                    q.popleft()
            if len(hits) >= self._per_client or len(self._all) >= self._overall:
                return False
            hits.append(now)
            self._all.append(now)
            return True

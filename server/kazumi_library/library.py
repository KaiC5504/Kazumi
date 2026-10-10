from __future__ import annotations

import json
import logging
import os
import re
import shutil
import threading
from collections.abc import Callable
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any
from uuid import uuid4

from .config import from_iso, to_iso

log = logging.getLogger(__name__)

EPISODE_ID_PATTERN = r"^[A-Za-z0-9_-]{1,200}$"
_EPISODE_ID_RE = re.compile(EPISODE_ID_PATTERN)
UPLOAD_FILES = ("video.mp4", "danmaku.json")
MANIFEST = "kazumi_episode.json"
META = "meta.json"

ACTIVE_MEMBER_WINDOW = timedelta(days=30)
WATCHED_RETENTION = timedelta(days=30)
UPLOAD_RETENTION = timedelta(days=7)
LAST_SEEN_WRITE_INTERVAL = timedelta(minutes=1)
_REPLACED_PREFIX = ".replaced-"


def is_valid_episode_id(value: str) -> bool:
    return _EPISODE_ID_RE.fullmatch(value) is not None


def write_json_atomic(path: Path, value: Any) -> None:
    tmp = path.with_name(f".{path.name}.{uuid4().hex}.tmp")
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(value, f, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def read_json(path: Path) -> Any:
    """Return the parsed file, or None when it is missing."""
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return None


def file_size(path: Path) -> int:
    try:
        return path.stat().st_size
    except FileNotFoundError:
        return 0


class EpisodeNotFound(Exception):
    pass


class SizeMismatch(Exception):
    def __init__(self, size: int) -> None:
        super().__init__(f"partial upload is {size} bytes")
        self.size = size


class Library:
    """Episodes, partial uploads and the member list, all as plain files under one directory."""

    def __init__(self, root: Path, clock: Callable[[], datetime], watchers: frozenset[str] = frozenset()) -> None:
        self.root = root
        self.watchers = watchers
        self.episodes_dir = root / "episodes"
        self.uploads_dir = root / "uploads"
        self.state_path = root / "state.json"
        self._clock = clock
        self._lock = threading.RLock()
        self._last_seen_written: dict[str, datetime] = {}

    def ensure_dirs(self) -> None:
        self.episodes_dir.mkdir(parents=True, exist_ok=True)
        self.uploads_dir.mkdir(parents=True, exist_ok=True)

    def episode_file(self, episode_id: str, name: str) -> Path:
        return self.episodes_dir / episode_id / name

    def upload_file(self, episode_id: str, name: str) -> Path:
        return self.uploads_dir / episode_id / name

    def parts_dir(self, episode_id: str, name: str) -> Path:
        return self.uploads_dir / episode_id / f"{name}.parts"

    def upload_parts(self, episode_id: str, name: str) -> dict[int, int]:
        """Sizes of the finished parts; a part being received is still a .tmp file."""
        d = self.parts_dir(episode_id, name)
        if not d.is_dir():
            return {}
        return {int(p.name): p.stat().st_size for p in d.iterdir() if p.name.isdecimal()}

    def assemble_parts(self, episode_id: str, name: str, expected_size: int | None) -> None:
        """Concatenates uploaded parts into the upload file, if this upload used parts."""
        d = self.parts_dir(episode_id, name)
        if not d.is_dir():
            return
        parts = sorted(self.upload_parts(episode_id, name).items())
        total = sum(size for _, size in parts)
        contiguous = [index for index, _ in parts] == list(range(len(parts)))
        if not contiguous or (expected_size is not None and total != expected_size):
            raise SizeMismatch(total)
        target = self.upload_file(episode_id, name)
        tmp = target.with_name(f".{name}.{uuid4().hex}.tmp")
        try:
            with open(tmp, "wb") as out:
                for index, _ in parts:
                    with open(d / str(index), "rb") as f:
                        shutil.copyfileobj(f, out, 1024 * 1024)
            os.replace(tmp, target)
        finally:
            tmp.unlink(missing_ok=True)
        shutil.rmtree(d)

    def list_episodes(self) -> list[dict[str, Any]]:
        entries = []
        with self._lock:
            for d in self.episodes_dir.iterdir():
                if not d.is_dir() or not is_valid_episode_id(d.name):
                    continue
                try:
                    entry = self._load_entry(d)
                except (ValueError, OSError):
                    log.exception("skipping unreadable episode %s", d.name)
                    continue
                if entry is not None:
                    entries.append(entry)
        entries.sort(key=_sort_key)
        return entries

    def commit(self, episode_id: str, manifest: dict[str, Any]) -> dict[str, Any]:
        upload_dir = self.uploads_dir / episode_id
        video = upload_dir / "video.mp4"
        for name in UPLOAD_FILES:
            self.assemble_parts(episode_id, name, manifest["sizeBytes"] if name == "video.mp4" else None)
        with self._lock:
            size = file_size(video) if video.is_file() else 0
            if not video.is_file() or size != manifest["sizeBytes"]:
                raise SizeMismatch(size)
            stored = {**manifest, "hasDanmaku": (upload_dir / "danmaku.json").is_file()}
            meta = {"uploadedAt": to_iso(self._clock()), "watchedBy": [], "firstWatchedAt": None}
            write_json_atomic(upload_dir / MANIFEST, stored)
            write_json_atomic(upload_dir / META, meta)

            # rename() can't replace a non-empty directory, so move the old one aside first.
            target = self.episodes_dir / episode_id
            replaced = None
            if target.exists():
                replaced = self.episodes_dir / f"{_REPLACED_PREFIX}{uuid4().hex}"
                os.rename(target, replaced)
            os.rename(upload_dir, target)
            if replaced is not None:
                shutil.rmtree(replaced, ignore_errors=True)
            return _entry(episode_id, stored, meta)

    def delete_episode(self, episode_id: str) -> bool:
        target = self.episodes_dir / episode_id
        with self._lock:
            if not target.is_dir():
                return False
            shutil.rmtree(target)
            return True

    def mark_watched(self, episode_id: str, name: str) -> bool:
        """Record that `name` watched the episode; returns True if that removed it."""
        d = self.episodes_dir / episode_id
        with self._lock:
            if not (d / MANIFEST).is_file():
                raise EpisodeNotFound(episode_id)
            if self.watchers and name not in self.watchers:
                return False
            now = self._clock()
            meta = _normalise_meta(read_json(d / META))
            if name not in meta["watchedBy"]:
                meta["watchedBy"].append(name)
            if meta["firstWatchedAt"] is None:
                meta["firstWatchedAt"] = to_iso(now)
            write_json_atomic(d / META, meta)

            # Whoever reports a watch is clearly active, and this keeps the member set
            # from being empty (which would make "everyone has watched" vacuously true).
            self.touch_member(name, force=True)
            active = self.active_members(now)
            if self.watchers:
                active &= self.watchers
            if active and active.issubset(meta["watchedBy"]):
                shutil.rmtree(d)
                return True
            return False

    def touch_member(self, name: str, force: bool = False) -> None:
        now = self._clock()
        with self._lock:
            last = self._last_seen_written.get(name)
            if not force and last is not None and now - last < LAST_SEEN_WRITE_INTERVAL:
                return
            state = self._read_state()
            state["members"][name] = to_iso(now)
            write_json_atomic(self.state_path, state)
            self._last_seen_written[name] = now

    def active_members(self, now: datetime) -> set[str]:
        members = self._read_state()["members"]
        active = set()
        for name, seen in members.items():
            try:
                if now - from_iso(seen) <= ACTIVE_MEMBER_WINDOW:
                    active.add(name)
            except (TypeError, ValueError):
                continue
        return active

    def housekeep(self) -> dict[str, int]:
        now = self._clock()
        removed = {"episodes": 0, "uploads": 0}
        with self._lock:
            for d in list(self.episodes_dir.iterdir()):
                if d.name.startswith(_REPLACED_PREFIX):
                    shutil.rmtree(d, ignore_errors=True)
                    continue
                if not d.is_dir() or not is_valid_episode_id(d.name):
                    continue
                try:
                    first = _normalise_meta(read_json(d / META))["firstWatchedAt"]
                    expired = first is not None and now - from_iso(first) > WATCHED_RETENTION
                except (ValueError, OSError):
                    log.exception("unreadable meta for %s", d.name)
                    continue
                if expired:
                    shutil.rmtree(d, ignore_errors=True)
                    removed["episodes"] += 1

            cutoff = (now - UPLOAD_RETENTION).timestamp()
            for d in list(self.uploads_dir.iterdir()):
                if not d.is_dir():
                    continue
                newest = max(p.stat().st_mtime for p in (d, *d.iterdir()))
                if newest < cutoff:
                    shutil.rmtree(d, ignore_errors=True)
                    removed["uploads"] += 1
        if any(removed.values()):
            log.warning("housekeeping removed %s", removed)
        return removed

    def _load_entry(self, d: Path) -> dict[str, Any] | None:
        manifest = read_json(d / MANIFEST)
        if not isinstance(manifest, dict):
            return None
        return _entry(d.name, manifest, _normalise_meta(read_json(d / META)))

    def _read_state(self) -> dict[str, Any]:
        try:
            state = read_json(self.state_path)
        except ValueError:
            log.exception("state.json is corrupt; starting a fresh member list")
            state = None
        if not isinstance(state, dict) or not isinstance(state.get("members"), dict):
            state = {"members": {}}
        return state


def _normalise_meta(meta: Any) -> dict[str, Any]:
    meta = meta if isinstance(meta, dict) else {}
    watched = meta.get("watchedBy")
    return {
        "uploadedAt": meta.get("uploadedAt"),
        "watchedBy": list(watched) if isinstance(watched, list) else [],
        "firstWatchedAt": meta.get("firstWatchedAt"),
    }


def _entry(episode_id: str, manifest: dict[str, Any], meta: dict[str, Any]) -> dict[str, Any]:
    return {**manifest, "id": episode_id, "uploadedAt": meta["uploadedAt"], "watchedBy": meta["watchedBy"]}


def _sort_key(entry: dict[str, Any]) -> tuple[str, int]:
    number = entry.get("episodeNumber")
    return (str(entry.get("bangumiName") or ""), number if isinstance(number, int) else 0)

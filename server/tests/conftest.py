import os
import tempfile
from datetime import UTC, datetime, timedelta

# kazumi_library.app builds a module-level app from the environment on import.
os.environ["KAZUMI_VIEW_KEY"] = "env-view-key-0123456789abcdef"
os.environ["KAZUMI_ADMIN_KEY"] = "env-admin-key-0123456789abcdef"
os.environ["KAZUMI_LIBRARY_DATA"] = tempfile.mkdtemp(prefix="kazumi-library-test-")

import pytest
from fastapi.testclient import TestClient

from kazumi_library.app import create_app
from kazumi_library.config import Settings

VIEW_KEY = "view-key-vvvvvvvvvvvvvvvvvvvvvvvv"
ADMIN_KEY = "admin-key-aaaaaaaaaaaaaaaaaaaaaaaa"
VIEW = {"X-Kazumi-Token": VIEW_KEY}
ADMIN = {"X-Kazumi-Token": ADMIN_KEY}


class FakeClock:
    def __init__(self) -> None:
        self.now = datetime.now(UTC)

    def __call__(self) -> datetime:
        return self.now

    def advance(self, **kwargs: float) -> None:
        self.now += timedelta(**kwargs)


@pytest.fixture
def clock() -> FakeClock:
    return FakeClock()


@pytest.fixture
def settings(tmp_path, clock) -> Settings:
    return Settings(
        data_dir=tmp_path / "data",
        view_key=VIEW_KEY,
        admin_key=ADMIN_KEY,
        syncplay_endpoint="kazumi.example.com:8999",
        syncplay_room="sofa",
        clock=clock,
        housekeeping_interval=None,
    )


@pytest.fixture
def client(settings):
    with TestClient(create_app(settings)) as c:
        yield c


def manifest(size: int, **extra) -> dict:
    return {
        "sizeBytes": size,
        "bangumiId": 101,
        "episodeNumber": 1,
        "pluginName": "AGE",
        "bangumiName": "Frieren",
        "episodeTitle": "第1集",
        **extra,
    }


def publish(client, episode_id: str, video: bytes, danmaku: bytes | None = None, **extra) -> dict:
    r = client.put(f"/api/upload/{episode_id}/video.mp4?offset=0", content=video, headers=ADMIN)
    assert r.status_code == 200, r.text
    if danmaku is not None:
        r = client.put(f"/api/upload/{episode_id}/danmaku.json?offset=0", content=danmaku, headers=ADMIN)
        assert r.status_code == 200, r.text
    r = client.post(f"/api/upload/{episode_id}/commit", json=manifest(len(video), **extra), headers=ADMIN)
    assert r.status_code == 200, r.text
    return r.json()


def heartbeat(client, device: str, name: str, state: str = "lobby", episode_id=None):
    r = client.post(
        "/api/room/heartbeat",
        json={"deviceId": device, "name": name, "state": state, "episodeId": episode_id},
        headers=VIEW,
    )
    assert r.status_code == 200, r.text
    return r.json()

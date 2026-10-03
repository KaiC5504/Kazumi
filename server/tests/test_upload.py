import asyncio
import json

import pytest

from conftest import ADMIN, VIEW, manifest, publish

VIDEO = bytes(range(256)) * 40


def size_of(client, episode_id, name="video.mp4"):
    return client.get(f"/api/upload/{episode_id}/{name}", headers=ADMIN).json()["size"]


def test_resumable_upload(client, settings):
    assert size_of(client, "ep1") == 0

    r = client.put("/api/upload/ep1/video.mp4?offset=0", content=VIDEO[:4000], headers=ADMIN)
    assert r.json() == {"size": 4000}

    r = client.put("/api/upload/ep1/video.mp4?offset=0", content=VIDEO[:10], headers=ADMIN)
    assert r.status_code == 409
    assert r.json() == {"size": 4000}
    r = client.put("/api/upload/ep1/video.mp4?offset=5000", content=VIDEO[:10], headers=ADMIN)
    assert r.status_code == 409
    assert size_of(client, "ep1") == 4000

    r = client.put("/api/upload/ep1/video.mp4?offset=4000", content=VIDEO[4000:], headers=ADMIN)
    assert r.json() == {"size": len(VIDEO)}
    assert (settings.data_dir / "uploads/ep1/video.mp4").read_bytes() == VIDEO


def test_offset_is_required(client):
    assert client.put("/api/upload/ep1/video.mp4", content=b"x", headers=ADMIN).status_code == 422
    assert client.put("/api/upload/ep1/video.mp4?offset=-1", content=b"x", headers=ADMIN).status_code == 422


def test_disconnect_mid_body_keeps_received_bytes(client):
    app = client.app

    async def drive():
        messages = [
            {"type": "http.request", "body": b"first-", "more_body": True},
            {"type": "http.request", "body": b"second", "more_body": True},
            {"type": "http.disconnect"},
        ]

        async def receive():
            if messages:
                return messages.pop(0)
            await asyncio.Event().wait()

        sent = []

        async def send(message):
            sent.append(message)

        scope = {
            "type": "http",
            "asgi": {"version": "3.0"},
            "http_version": "1.1",
            "method": "PUT",
            "scheme": "http",
            "path": "/api/upload/ep1/video.mp4",
            "raw_path": b"/api/upload/ep1/video.mp4",
            "root_path": "",
            "query_string": b"offset=0",
            "headers": [(b"host", b"test"), (b"x-kazumi-token", ADMIN["X-Kazumi-Token"].encode())],
            "client": ("127.0.0.1", 5000),
            "server": ("test", 80),
        }
        await app(scope, receive, send)
        return sent

    asyncio.run(drive())
    assert size_of(client, "ep1") == len(b"first-second")
    r = client.put("/api/upload/ep1/video.mp4?offset=12", content=b"-third", headers=ADMIN)
    assert r.json() == {"size": 18}


def test_commit_size_mismatch(client):
    client.put("/api/upload/ep1/video.mp4?offset=0", content=VIDEO[:100], headers=ADMIN)
    r = client.post("/api/upload/ep1/commit", json=manifest(len(VIDEO)), headers=ADMIN)
    assert r.status_code == 409
    assert r.json() == {"size": 100}
    assert client.get("/api/episodes", headers=VIEW).json() == {"episodes": []}


def test_commit_without_any_upload(client):
    r = client.post("/api/upload/ep1/commit", json=manifest(10), headers=ADMIN)
    assert r.status_code == 409
    assert r.json() == {"size": 0}


@pytest.mark.parametrize(
    "body",
    [
        [1, 2],
        "nope",
        {k: v for k, v in manifest(10).items() if k != "pluginName"},
        manifest(10, bangumiId="101"),
        manifest(10, episodeNumber=True),
        manifest(10, episodeNumber=1.0),
        manifest(10, pluginName=7),
        manifest(0),
    ],
)
def test_commit_validation(client, body):
    client.put("/api/upload/ep1/video.mp4?offset=0", content=b"0123456789", headers=ADMIN)
    r = client.post("/api/upload/ep1/commit", json=body, headers=ADMIN)
    assert r.status_code == 422


def test_commit_rejects_non_json(client):
    r = client.post("/api/upload/ep1/commit", content=b"{not json", headers=ADMIN)
    assert r.status_code == 422


def test_commit_and_listing(client, settings, clock):
    entry = publish(client, "ep2", VIDEO, danmaku=b'{"comments": []}', episodeNumber=2, extraField={"k": [1]})
    assert entry["id"] == "ep2"
    assert entry["hasDanmaku"] is True
    assert entry["watchedBy"] == []
    assert entry["extraField"] == {"k": [1]}
    assert entry["uploadedAt"].endswith("Z")

    publish(client, "ep1", VIDEO[:50], episodeNumber=1)
    publish(client, "other", VIDEO[:20], bangumiName="Bocchi", episodeNumber=12)

    assert not (settings.data_dir / "uploads/ep2").exists()
    stored = json.loads((settings.data_dir / "episodes/ep1/kazumi_episode.json").read_text("utf-8"))
    assert stored["hasDanmaku"] is False
    assert stored["episodeTitle"] == "第1集"
    meta = json.loads((settings.data_dir / "episodes/ep1/meta.json").read_text("utf-8"))
    assert meta == {"uploadedAt": meta["uploadedAt"], "watchedBy": [], "firstWatchedAt": None}

    episodes = client.get("/api/episodes", headers=VIEW).json()["episodes"]
    assert [e["id"] for e in episodes] == ["other", "ep1", "ep2"]
    assert episodes[2] == entry


def test_uncommitted_uploads_are_not_listed(client):
    client.put("/api/upload/ep1/video.mp4?offset=0", content=VIDEO, headers=ADMIN)
    assert client.get("/api/episodes", headers=VIEW).json() == {"episodes": []}
    assert client.get("/episodes/ep1/video.mp4", headers=VIEW).status_code == 404


def test_recommit_replaces_episode(client, settings):
    publish(client, "ep1", VIDEO[:30])
    client.post("/api/episodes/ep1/watched", json={"name": "alice"}, headers=VIEW)
    client.post("/api/room/heartbeat", json={"deviceId": "d", "name": "bob", "state": "lobby"}, headers=VIEW)

    entry = publish(client, "ep1", VIDEO[:60], danmaku=b"[]")
    assert entry["watchedBy"] == []
    assert entry["hasDanmaku"] is True
    assert client.get("/episodes/ep1/video.mp4", headers=VIEW).content == VIDEO[:60]
    assert [p.name for p in (settings.data_dir / "episodes").iterdir()] == ["ep1"]


def test_delete_episode(client):
    publish(client, "ep1", VIDEO[:30])
    r = client.delete("/api/episodes/ep1", headers=ADMIN)
    assert r.json() == {"deleted": True}
    assert client.get("/api/episodes", headers=VIEW).json() == {"episodes": []}

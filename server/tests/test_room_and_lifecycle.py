import json
import os
import time
from dataclasses import replace
from datetime import timedelta

from fastapi.testclient import TestClient

from conftest import ADMIN, VIEW, heartbeat, publish
from kazumi_library.app import create_app

VIDEO = b"x" * 100


def read_state(settings):
    return json.loads((settings.data_dir / "state.json").read_text("utf-8"))


def test_heartbeat_and_expiry(client, clock):
    room = heartbeat(client, "phone", "alice", "lobby")
    assert room == {
        "members": [{"deviceId": "phone", "name": "alice", "state": "lobby", "episodeId": None, "secondsAgo": 0}],
        "selection": None,
    }

    clock.advance(seconds=10)
    room = heartbeat(client, "ipad", "bob", "watching", "ep1")
    assert [(m["deviceId"], m["secondsAgo"]) for m in room["members"]] == [("phone", 10), ("ipad", 0)]
    assert room["members"][1]["episodeId"] == "ep1"

    clock.advance(seconds=11)
    room = client.get("/api/room", headers=VIEW).json()
    assert [m["deviceId"] for m in room["members"]] == ["ipad"]

    clock.advance(seconds=10)
    assert client.get("/api/room", headers=VIEW).json()["members"] == []


def test_leave_drops_the_device_at_once(client):
    heartbeat(client, "phone", "alice")
    heartbeat(client, "ipad", "bob")
    r = client.post("/api/room/leave", json={"deviceId": "phone"}, headers=VIEW)
    assert r.status_code == 200
    assert [m["deviceId"] for m in r.json()["members"]] == ["ipad"]
    assert client.post("/api/room/leave", json={"deviceId": "phone"}, headers=VIEW).status_code == 200
    assert client.post("/api/room/leave", json={"deviceId": "ipad"}).status_code == 401


def test_idle_heartbeat_from_older_apps_means_leaving(client):
    heartbeat(client, "phone", "alice")
    room = heartbeat(client, "phone", "alice", "idle")
    assert room["members"] == []


def test_select_bumps_seq(client, clock):
    heartbeat(client, "phone", "alice")
    r = client.post("/api/room/select", json={"deviceId": "ipad", "name": "bob", "episodeId": "ep7"}, headers=VIEW)
    assert r.status_code == 200
    room = r.json()
    sel = room["selection"]
    first = sel["seq"]
    assert sel["episodeId"] == "ep7"
    assert sel["by"] == "bob"
    assert sel["byDeviceId"] == "ipad"
    assert sel["at"].endswith("Z")
    assert {m["deviceId"] for m in room["members"]} == {"phone", "ipad"}

    clock.advance(seconds=3)
    r = client.post("/api/room/select", json={"deviceId": "phone", "name": "alice", "episodeId": "ep8"}, headers=VIEW)
    sel = r.json()["selection"]
    assert (sel["seq"], sel["episodeId"], sel["byDeviceId"]) == (first + 1, "ep8", "phone")
    assert client.get("/api/room", headers=VIEW).json()["selection"] == sel


def test_picks_keep_counting_up_across_restarts(settings, clock):
    pick = {"deviceId": "ipad", "name": "bob", "episodeId": "ep7"}
    with TestClient(create_app(settings)) as c:
        for _ in range(3):
            before = c.post("/api/room/select", json=pick, headers=VIEW).json()["selection"]["seq"]
    clock.advance(seconds=5)
    # Apps already in the lobby ignore picks numbered at or below the last one
    # they saw, so a restart must not start counting from zero again.
    with TestClient(create_app(settings)) as c:
        after = c.post("/api/room/select", json=pick, headers=VIEW).json()["selection"]["seq"]
    assert after > before


def test_room_body_validation(client):
    bad = [
        {"deviceId": "d", "name": "a", "state": "dancing"},
        {"deviceId": "d", "name": "   ", "state": "lobby"},
        {"deviceId": "", "name": "a", "state": "lobby"},
        {"deviceId": "d", "name": "a", "state": "lobby", "episodeId": "../etc"},
    ]
    for body in bad:
        assert client.post("/api/room/heartbeat", json=body, headers=VIEW).status_code == 422
    r = client.post("/api/room/select", json={"deviceId": "d", "name": "a", "episodeId": "a.b"}, headers=VIEW)
    assert r.status_code == 422


def test_last_seen_writes_are_throttled(client, settings, clock):
    heartbeat(client, "phone", "alice")
    first = read_state(settings)["members"]["alice"]
    clock.advance(seconds=30)
    heartbeat(client, "phone", "alice")
    assert read_state(settings)["members"]["alice"] == first
    clock.advance(seconds=31)
    heartbeat(client, "phone", "alice")
    assert read_state(settings)["members"]["alice"] != first


def test_episode_deleted_once_everyone_watched(client, settings):
    heartbeat(client, "phone", "alice")
    heartbeat(client, "ipad", "bob")
    publish(client, "ep1", VIDEO)

    r = client.post("/api/episodes/ep1/watched", json={"name": "alice"}, headers=VIEW)
    assert r.json() == {"deleted": False}
    meta = json.loads((settings.data_dir / "episodes/ep1/meta.json").read_text("utf-8"))
    assert meta["watchedBy"] == ["alice"]
    assert meta["firstWatchedAt"] is not None
    assert client.get("/api/episodes", headers=VIEW).json()["episodes"][0]["watchedBy"] == ["alice"]

    r = client.post("/api/episodes/ep1/watched", json={"name": "alice"}, headers=VIEW)
    assert r.json() == {"deleted": False}

    r = client.post("/api/episodes/ep1/watched", json={"name": "bob"}, headers=VIEW)
    assert r.json() == {"deleted": True}
    assert not (settings.data_dir / "episodes/ep1").exists()
    assert client.get("/api/episodes", headers=VIEW).json() == {"episodes": []}


def test_first_watched_at_is_kept(client, settings, clock):
    heartbeat(client, "phone", "alice")
    heartbeat(client, "ipad", "bob")
    heartbeat(client, "pc", "carol")
    publish(client, "ep1", VIDEO)
    client.post("/api/episodes/ep1/watched", json={"name": "alice"}, headers=VIEW)
    first = json.loads((settings.data_dir / "episodes/ep1/meta.json").read_text("utf-8"))["firstWatchedAt"]
    clock.advance(hours=2)
    assert client.post("/api/episodes/ep1/watched", json={"name": "bob"}, headers=VIEW).json() == {"deleted": False}
    meta = json.loads((settings.data_dir / "episodes/ep1/meta.json").read_text("utf-8"))
    assert meta["firstWatchedAt"] == first
    assert meta["watchedBy"] == ["alice", "bob"]


def test_stale_members_do_not_block_deletion(client, clock):
    heartbeat(client, "old-phone", "carol")
    clock.advance(days=31)
    heartbeat(client, "phone", "alice")
    publish(client, "ep1", VIDEO)
    r = client.post("/api/episodes/ep1/watched", json={"name": "alice"}, headers=VIEW)
    assert r.json() == {"deleted": True}


def test_watched_unknown_episode(client):
    assert client.post("/api/episodes/nope/watched", json={"name": "a"}, headers=VIEW).status_code == 404


def _age_upload(settings, episode_id, when):
    d = settings.data_dir / "uploads" / episode_id
    for p in (*d.iterdir(), d):
        os.utime(p, (when.timestamp(), when.timestamp()))


def test_housekeeping_expires_stale_uploads(client, settings, clock):
    for episode_id in ("stale", "fresh"):
        client.put(f"/api/upload/{episode_id}/video.mp4?offset=0", content=b"abc", headers=ADMIN)
    _age_upload(settings, "stale", clock() - timedelta(days=7, minutes=1))
    _age_upload(settings, "fresh", clock() - timedelta(days=6))

    assert client.app.state.library.housekeep() == {"episodes": 0, "uploads": 1}
    assert not (settings.data_dir / "uploads/stale").exists()
    assert (settings.data_dir / "uploads/fresh/video.mp4").read_bytes() == b"abc"


def test_housekeeping_expires_watched_episodes(client, clock):
    library = client.app.state.library
    heartbeat(client, "phone", "alice")
    heartbeat(client, "ipad", "bob")
    publish(client, "watched", VIDEO)
    publish(client, "unwatched", VIDEO)
    client.post("/api/episodes/watched/watched", json={"name": "alice"}, headers=VIEW)

    clock.advance(days=29)
    assert library.housekeep() == {"episodes": 0, "uploads": 0}

    clock.advance(days=2)
    assert library.housekeep() == {"episodes": 1, "uploads": 0}
    ids = [e["id"] for e in client.get("/api/episodes", headers=VIEW).json()["episodes"]]
    assert ids == ["unwatched"]


def test_housekeeping_runs_in_background(settings, clock):
    fast = replace(settings, housekeeping_interval=0.05)
    (fast.data_dir / "uploads/stale").mkdir(parents=True)
    (fast.data_dir / "uploads/stale/video.mp4").write_bytes(b"abc")
    clock.advance(days=8)
    with TestClient(create_app(fast)):
        deadline = time.monotonic() + 5
        while (fast.data_dir / "uploads/stale").exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert not (fast.data_dir / "uploads/stale").exists()

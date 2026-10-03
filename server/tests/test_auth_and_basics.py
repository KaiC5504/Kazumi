import re

import pytest
from fastapi.testclient import TestClient

from conftest import ADMIN, ADMIN_KEY, VIEW, VIEW_KEY, publish
from kazumi_library.app import create_app
from kazumi_library.config import ConfigError, Settings


def test_healthz_needs_no_auth(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.text == "ok"


def test_missing_token_is_401_with_empty_body(client):
    r = client.get("/api/config")
    assert r.status_code == 401
    assert r.content == b""


def test_view_key_via_header_and_query(client):
    assert client.get("/api/config", headers=VIEW).json() == {"syncplay": "kazumi.example.com:8999", "room": "sofa"}
    assert client.get(f"/api/config?token={VIEW_KEY}").status_code == 200


def test_wrong_key_rejected(client):
    assert client.get("/api/config", headers={"X-Kazumi-Token": "x" * 40}).status_code == 401
    assert client.get("/api/config?token=" + "y" * 40).status_code == 401


def test_either_header_or_query_may_match(client):
    r = client.get(f"/api/config?token={VIEW_KEY}", headers={"X-Kazumi-Token": "wrong" * 8})
    assert r.status_code == 200


def test_non_ascii_token_is_just_rejected(client):
    assert client.get("/api/config?token=" + "密钥" * 20).status_code == 401


def test_admin_key_works_on_view_endpoints(client):
    assert client.get("/api/episodes", headers=ADMIN).status_code == 200


def test_view_key_cannot_use_admin_endpoints(client):
    assert client.get("/api/upload/ep1/video.mp4", headers=VIEW).status_code == 401
    assert client.put("/api/upload/ep1/video.mp4?offset=0", content=b"x", headers=VIEW).status_code == 401
    assert client.post("/api/upload/ep1/commit", json={}, headers=VIEW).status_code == 401
    assert client.delete("/api/episodes/ep1", headers=VIEW).status_code == 401
    assert client.get(f"/api/upload/ep1/video.mp4?token={ADMIN_KEY}").json() == {"size": 0}


def test_media_accepts_query_token(client):
    publish(client, "ep1", b"0123456789")
    assert client.get("/episodes/ep1/video.mp4").status_code == 401
    assert client.get(f"/episodes/ep1/video.mp4?token={VIEW_KEY}").content == b"0123456789"


@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("GET", "/episodes/bad.id/video.mp4"),
        ("HEAD", "/episodes/bad.id/video.mp4"),
        ("GET", "/episodes/" + "a" * 201 + "/video.mp4"),
        ("GET", "/episodes/ep%20one/video.mp4"),
        ("GET", "/episodes/ep1/meta.json"),
        ("GET", "/api/upload/bad.id/video.mp4"),
        ("GET", "/api/upload/ep1/kazumi_episode.json"),
        ("PUT", "/api/upload/bad.id/video.mp4?offset=0"),
        ("POST", "/api/upload/bad.id/commit"),
        ("POST", "/api/episodes/bad.id/watched"),
        ("DELETE", "/api/episodes/bad.id"),
    ],
)
def test_invalid_ids_and_names_are_404(client, method, path):
    r = client.request(method, path, headers=ADMIN, json={"name": "alice"})
    assert r.status_code == 404


def test_missing_episode_is_404(client):
    assert client.get("/episodes/nope/video.mp4", headers=VIEW).status_code == 404
    assert client.delete("/api/episodes/nope", headers=ADMIN).status_code == 404


def test_join_page_served_without_auth(client):
    r = client.get("/join")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/html")
    html = r.text
    assert "kazumi-library://join?server=" in html
    assert "MicroMessenger" in html
    assert "打开 Kazumi 加入一起看" in html
    assert "邀请链接不完整，请让对方重新发送" in html
    assert "https://apps.apple.com/app/testflight/id899247664" in html
    assert "PingFang SC" in html
    assert "prefers-reduced-motion" in html
    # Nothing may be fetched from elsewhere: the page has to load inside mainland China.
    assert not re.search(r"<link|<script[^>]+src=|<img|@import|url\(", html)
    assert "default-src 'none'" in r.headers["content-security-policy"]


def test_docs_are_not_exposed(client):
    assert client.get("/docs").status_code == 404
    assert client.get("/openapi.json").status_code == 404


@pytest.mark.parametrize(
    ("view", "admin"),
    [("", ADMIN_KEY), (VIEW_KEY, ""), ("short", ADMIN_KEY), (VIEW_KEY, "x" * 23), (VIEW_KEY, VIEW_KEY)],
)
def test_refuses_to_start_with_weak_keys(tmp_path, view, admin):
    with pytest.raises(ConfigError):
        create_app(Settings(data_dir=tmp_path, view_key=view, admin_key=admin))


def test_settings_from_env(tmp_path):
    s = Settings.from_env(
        {
            "KAZUMI_LIBRARY_DATA": str(tmp_path),
            "KAZUMI_VIEW_KEY": f"  {VIEW_KEY}\n",
            "KAZUMI_ADMIN_KEY": ADMIN_KEY,
            "KAZUMI_SYNCPLAY_ENDPOINT": "kazumi.kaic5504.com:8999",
            "KAZUMI_SYNCPLAY_ROOM": "sofa",
        }
    )
    assert s.view_key == VIEW_KEY
    assert str(s.data_dir) == str(tmp_path)
    s.validate()
    with TestClient(create_app(s)) as c:
        assert c.get("/api/config", headers=VIEW).json()["syncplay"] == "kazumi.kaic5504.com:8999"


def test_from_env_defaults_data_dir():
    assert str(Settings.from_env({}).data_dir) == "data"

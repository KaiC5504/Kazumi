from conftest import ADMIN, VIEW, VIEW_KEY


def test_invite_code_trades_for_the_view_key(client):
    created = client.post("/api/invites", headers=ADMIN).json()
    code = created["code"]
    assert len(code) == 9 and code[4] == "-"

    # Typed loosely: lowercase, no dash, stray spaces.
    typed = f" {code.replace('-', '').lower()} "
    assert client.post("/api/redeem", json={"code": typed}).json() == {"key": VIEW_KEY}


def test_wrong_and_expired_codes_are_rejected(client, clock):
    code = client.post("/api/invites", headers=ADMIN).json()["code"]
    assert client.post("/api/redeem", json={"code": "AAAA-AAAA"}).status_code == 404
    clock.advance(days=8)
    assert client.post("/api/redeem", json={"code": code}).status_code == 404


def test_only_admin_creates_invites(client):
    assert client.post("/api/invites").status_code == 401
    assert client.post("/api/invites", headers=VIEW).status_code == 401


def test_redeem_is_rate_limited_then_recovers(client, clock):
    statuses = [client.post("/api/redeem", json={"code": "WRONGCODE"}).status_code for _ in range(7)]
    assert statuses[:5] == [404] * 5
    assert statuses[5:] == [429, 429]
    clock.advance(minutes=2)
    assert client.post("/api/redeem", json={"code": "WRONGCODE"}).status_code == 404


def test_codes_survive_a_restart(settings, clock):
    from fastapi.testclient import TestClient

    from kazumi_library.app import create_app

    with TestClient(create_app(settings)) as first:
        code = first.post("/api/invites", headers=ADMIN).json()["code"]
    with TestClient(create_app(settings)) as second:
        assert second.post("/api/redeem", json={"code": code}).status_code == 200

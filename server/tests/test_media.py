import pytest

from conftest import VIEW, publish

VIDEO = bytes(range(256)) * 40
SIZE = len(VIDEO)


@pytest.fixture
def episode(client):
    publish(client, "ep1", VIDEO, danmaku=b'{"comments":[1,2,3]}')
    return "/episodes/ep1"


def get(client, path, range_=None, method="GET"):
    headers = dict(VIEW)
    if range_:
        headers["Range"] = range_
    return client.request(method, path, headers=headers)


def test_full_response(client, episode):
    r = get(client, f"{episode}/video.mp4")
    assert r.status_code == 200
    assert r.content == VIDEO
    assert r.headers["content-length"] == str(SIZE)
    assert r.headers["accept-ranges"] == "bytes"
    assert r.headers["content-type"] == "video/mp4"


@pytest.mark.parametrize(
    ("range_", "start", "end"),
    [
        ("bytes=10-19", 10, 19),
        ("bytes=0-0", 0, 0),
        (f"bytes=10000-", 10000, SIZE - 1),
        ("bytes=-100", SIZE - 100, SIZE - 1),
        (f"bytes=-{SIZE * 2}", 0, SIZE - 1),
        (f"bytes=100-{SIZE * 2}", 100, SIZE - 1),
    ],
)
def test_single_ranges(client, episode, range_, start, end):
    r = get(client, f"{episode}/video.mp4", range_)
    assert r.status_code == 206
    assert r.headers["content-range"] == f"bytes {start}-{end}/{SIZE}"
    assert r.headers["content-length"] == str(end - start + 1)
    assert r.headers["accept-ranges"] == "bytes"
    assert r.headers["content-type"] == "video/mp4"
    assert r.content == VIDEO[start : end + 1]


@pytest.mark.parametrize("range_", [f"bytes={SIZE}-", f"bytes={SIZE + 5}-{SIZE + 10}", "bytes=-0"])
def test_unsatisfiable_range(client, episode, range_):
    r = get(client, f"{episode}/video.mp4", range_)
    assert r.status_code == 416
    assert r.headers["content-range"] == f"bytes */{SIZE}"


def test_head(client, episode):
    r = get(client, f"{episode}/video.mp4", method="HEAD")
    assert r.status_code == 200
    assert r.headers["content-length"] == str(SIZE)
    assert r.headers["accept-ranges"] == "bytes"
    assert r.content == b""

    r = get(client, f"{episode}/video.mp4", "bytes=100-199", method="HEAD")
    assert r.status_code == 206
    assert r.headers["content-range"] == f"bytes 100-199/{SIZE}"
    assert r.headers["content-length"] == "100"
    assert r.content == b""


def test_danmaku(client, episode):
    r = get(client, f"{episode}/danmaku.json")
    assert r.status_code == 200
    assert r.headers["content-type"] == "application/json"
    assert r.json() == {"comments": [1, 2, 3]}
    r = get(client, f"{episode}/danmaku.json", "bytes=0-1")
    assert r.status_code == 206
    assert r.content == b'{"'


def test_missing_danmaku_is_404(client):
    publish(client, "ep2", VIDEO[:10])
    assert get(client, "/episodes/ep2/danmaku.json").status_code == 404


def test_multi_megabyte_file_streams_intact(client):
    big = bytes(range(251)) * (3 * 1024 * 1024 // 251 + 7)
    publish(client, "big", big)
    r = get(client, "/episodes/big/video.mp4")
    assert r.content == big
    r = get(client, "/episodes/big/video.mp4", f"bytes=1048570-{2 * 1048576 + 5}")
    assert r.status_code == 206
    assert r.content == big[1048570 : 2 * 1048576 + 6]

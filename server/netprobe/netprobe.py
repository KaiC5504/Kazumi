"""Speed and route diagnostics for a viewer far from the servers.

The page in index.html measures from the phone's side. While a test from an
address is running, this records the server's side of the same connections:
TCP stats from `ss` (retransmissions are packet loss, plus RTT and congestion
window) and an `mtr` trace back to the address with per-hop loss and AS
numbers. Results land in NETPROBE_DATA as one JSON file per test.

Standard library only. Runs behind Caddy, which terminates TLS and sets
X-Forwarded-For.
"""

import json
import os
import re
import secrets
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

NAME = os.environ.get("NETPROBE_NAME", "hk")
KEY = os.environ.get("NETPROBE_KEY", "")
ORIGIN = os.environ.get("NETPROBE_ORIGIN", "*")
PORT = int(os.environ.get("NETPROBE_PORT", "8780"))
DATA = Path(os.environ.get("NETPROBE_DATA", "/var/lib/netprobe"))
PAGE = Path(os.environ.get("NETPROBE_PAGE", Path(__file__).with_name("index.html")))

MAX_DOWN = 200 << 20
MAX_UP = 64 << 20
SAMPLE_EVERY = 0.5
SAMPLE_FOR = 240
# Random so nothing on the way can compress it.
BLOCK = os.urandom(1 << 20)
TEST_ID = re.compile(r"^[A-Za-z0-9_-]{8,40}$")

_tests: dict[str, dict] = {}
_lock = threading.Lock()


def _write(test_id: str) -> None:
    with _lock:
        test = _tests.get(test_id)
        if test is None:
            return
        body = json.dumps(test, ensure_ascii=False, indent=1)
    DATA.mkdir(parents=True, exist_ok=True)
    tmp = DATA / f".{test_id}.{NAME}.tmp"
    tmp.write_text(body, encoding="utf-8")
    tmp.replace(DATA / f"{test_id}.{NAME}.json")


def _sample_tcp(test_id: str, ip: str) -> None:
    """Snapshots of every TCP connection to the tester, until the test ends."""
    deadline = time.monotonic() + SAMPLE_FOR
    started = time.time()
    while time.monotonic() < deadline:
        with _lock:
            test = _tests[test_id]
            if test.get("finishedAt"):
                break
        try:
            out = subprocess.run(
                ["ss", "-tinH", "dst", ip],
                capture_output=True, text=True, timeout=5,
            ).stdout
        except (OSError, subprocess.SubprocessError):
            out = ""
        lines = [line.strip() for line in out.splitlines() if line.strip()]
        if lines:
            with _lock:
                test["tcp"].append({"t": round(time.time() - started, 2), "ss": lines})
        time.sleep(SAMPLE_EVERY)
    _write(test_id)


def _trace(test_id: str, ip: str) -> None:
    try:
        out = subprocess.run(
            ["mtr", "-n", "-r", "-w", "-z", "-c", "60", ip],
            capture_output=True, text=True, timeout=120,
        )
        report = out.stdout or out.stderr
    except (OSError, subprocess.SubprocessError) as e:
        report = f"mtr failed: {e}"
    with _lock:
        _tests[test_id]["mtr"] = report
    _write(test_id)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "netprobe"

    def log_message(self, format, *args):  # noqa: A002 - stdlib signature
        pass

    def _client_ip(self) -> str:
        forwarded = self.headers.get("X-Forwarded-For")
        if forwarded and self.client_address[0] in ("127.0.0.1", "::1"):
            return forwarded.split(",")[0].strip()
        return self.client_address[0]

    def _headers(self, status: int, length: int, kind: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", ORIGIN)
        self.send_header("Timing-Allow-Origin", "*")
        self.end_headers()

    def _json(self, status: int, value) -> None:
        body = json.dumps(value).encode()
        self._headers(status, len(body), "application/json")
        self.wfile.write(body)

    def _authorized(self, query: dict) -> bool:
        if KEY and secrets.compare_digest(query.get("k", [""])[0], KEY):
            return True
        self._json(403, {"error": "key"})
        return False

    def _read_body(self, limit: int) -> bytes:
        length = int(self.headers.get("Content-Length") or 0)
        if length > limit:
            raise ValueError("too large")
        return self.rfile.read(length)

    def do_GET(self):  # noqa: N802 - stdlib naming
        url = urlparse(self.path)
        query = parse_qs(url.query)
        path = url.path.rstrip("/")
        if path in ("/speed", "/speed/index.html"):
            body = PAGE.read_bytes()
            self._headers(200, len(body), "text/html; charset=utf-8")
            self.wfile.write(body)
            return
        if not self._authorized(query):
            return
        if path == "/speed/ping":
            self._json(200, {"server": NAME, "t": time.time()})
            return
        if path == "/speed/down":
            size = min(int(query.get("bytes", ["0"])[0] or 0), MAX_DOWN)
            self._headers(200, size, "application/octet-stream")
            sent = 0
            try:
                while sent < size:
                    chunk = BLOCK[: min(len(BLOCK), size - sent)]
                    self.wfile.write(chunk)
                    sent += len(chunk)
            except (BrokenPipeError, ConnectionResetError):
                # The page aborts downloads once it has timed enough.
                self.close_connection = True
            return
        self._json(404, {"error": "path"})

    def do_POST(self):  # noqa: N802 - stdlib naming
        url = urlparse(self.path)
        query = parse_qs(url.query)
        path = url.path.rstrip("/")
        if not self._authorized(query):
            return
        if path == "/speed/up":
            started = time.monotonic()
            length = int(self.headers.get("Content-Length") or 0)
            remaining = min(length, MAX_UP)
            while remaining > 0:
                chunk = self.rfile.read(min(remaining, 1 << 16))
                if not chunk:
                    break
                remaining -= len(chunk)
            self._json(200, {"bytes": length - remaining,
                             "seconds": time.monotonic() - started})
            return
        test_id = query.get("id", [""])[0]
        if not TEST_ID.match(test_id):
            self._json(400, {"error": "id"})
            return
        if path == "/speed/start":
            ip = self._client_ip()
            with _lock:
                if test_id in _tests:
                    self._json(200, {"ip": ip, "server": NAME})
                    return
                _tests[test_id] = {
                    "id": test_id,
                    "server": NAME,
                    "ip": ip,
                    "userAgent": self.headers.get("User-Agent", ""),
                    "startedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                    "tcp": [],
                    "mtr": None,
                    "client": None,
                }
            threading.Thread(target=_sample_tcp, args=(test_id, ip), daemon=True).start()
            threading.Thread(target=_trace, args=(test_id, ip), daemon=True).start()
            self._json(200, {"ip": ip, "server": NAME})
            return
        if path == "/speed/finish":
            try:
                client = json.loads(self._read_body(1 << 20) or b"null")
            except ValueError:
                self._json(400, {"error": "body"})
                return
            with _lock:
                test = _tests.get(test_id)
                if test is None:
                    self._json(404, {"error": "test"})
                    return
                test["client"] = client
                test["finishedAt"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
            _write(test_id)
            self._json(200, {"saved": True})
            return
        self._json(404, {"error": "path"})


def main() -> None:
    if not KEY:
        raise SystemExit("NETPROBE_KEY is not set")
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()

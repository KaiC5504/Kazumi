"""Runs every automated test that covers the partner's side of the app.

Her path: TestFlight install, invite code, 一起看 with SyncPlay, the update
prompt and the TestFlight update. Any change that could reach her TestFlight
build has to pass this before a Codemagic build.

Starts a throwaway library server on localhost (random keys, temp data dir) so
the live library tests run too, then runs the server's own tests.

    python scripts/partner_check.py

Exit 0: all passed.
"""

from __future__ import annotations

import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SERVER = ROOT / "server"
WIN = sys.platform == "win32"

DART_TESTS = [
    "test/partner_flow_test.dart",
    "test/library_test.dart",
    "test/library_mirrors_test.dart",
    "test/host_router_test.dart",
    "test/route_check_store_test.dart",
    "test/mirror_selector_test.dart",
    "test/testflight_update_test.dart",
    "test/official_rules_sync_test.dart",
    "test/syncplay_endpoint_test.dart",
    "test/syncplay_drift_test.dart",
    "test/syncplay_episode_test.dart",
    "test/syncplay_reconnect_test.dart",
    "test/syncplay_reload_test.dart",
    "test/syncplay_room_test.dart",
    "test/syncplay_room_flag_test.dart",
    "test/syncplay_watchdog_test.dart",
    "test/watch_together_lab_test.dart",
    "test/player_room_speed_test.dart",
    "test/playback_end_guard_test.dart",
    "test/playback_end_wiring_test.dart",
    "test/download_relocation_test.dart",
    "test/offline_launch_test.dart",
]


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_healthy(url: str, server: subprocess.Popen, timeout: float = 60) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if server.poll() is not None:
            raise RuntimeError("library server exited during startup")
        try:
            with urllib.request.urlopen(f"{url}/healthz", timeout=2) as r:
                if r.status == 200:
                    return
        except OSError:
            time.sleep(0.5)
    raise RuntimeError("library server did not come up")


def run(args: list[str], cwd: Path, env: dict[str, str] | None = None) -> bool:
    print(f"\n$ {' '.join(args)}", flush=True)
    return subprocess.run(args, cwd=cwd, env=env, shell=WIN).returncode == 0


def main() -> int:
    data = Path(tempfile.mkdtemp(prefix="kazumi_partner_check_"))
    port = free_port()
    url = f"http://127.0.0.1:{port}"
    view_key, admin_key = secrets.token_urlsafe(24), secrets.token_urlsafe(24)
    server_env = {
        **os.environ,
        "KAZUMI_LIBRARY_DATA": str(data),
        "KAZUMI_VIEW_KEY": view_key,
        "KAZUMI_ADMIN_KEY": admin_key,
        "KAZUMI_SYNCPLAY_ENDPOINT": "hk.kaic5504.com:8999",
        "KAZUMI_SYNCPLAY_TLS": "1",
        "KAZUMI_SYNCPLAY_ROOM": "partner-check",
    }
    server = subprocess.Popen(
        ["uv", "run", "--project", str(SERVER), "uvicorn", "kazumi_library.app:app",
         "--host", "127.0.0.1", "--port", str(port), "--no-access-log"],
        cwd=SERVER, env=server_env, shell=WIN,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        wait_healthy(url, server)
        test_env = {
            **os.environ,
            "KAZUMI_LIBRARY_TEST_URL": url,
            "KAZUMI_LIBRARY_TEST_VIEW_KEY": view_key,
            "KAZUMI_LIBRARY_TEST_ADMIN_KEY": admin_key,
        }
        dart_ok = run(["fvm", "flutter", "test", *DART_TESTS], ROOT, test_env)
    finally:
        if WIN:
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(server.pid)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            server.terminate()
        server.wait()
        shutil.rmtree(data, ignore_errors=True)

    server_ok = run(["uv", "run", "pytest", "-q"], SERVER)

    print("\npartner check:", "PASS" if dart_ok and server_ok else "FAIL")
    print(f"  app tests:    {'pass' if dart_ok else 'FAIL'}")
    print(f"  server tests: {'pass' if server_ok else 'FAIL'}")
    return 0 if dart_ok and server_ok else 1


if __name__ == "__main__":
    sys.exit(main())

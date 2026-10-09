"""Runs every automated test that covers the partner's side of the app.

Her path: TestFlight install, invite code, 一起看 with SyncPlay, the update
prompt and the TestFlight update. Any change that could reach her TestFlight
build has to pass this before a Codemagic build.

Before any test it checks three guards:
- codemagic.yaml (her build) never sets KAZUMI_PUBLIC and still passes
  --build-number, without which her app never prompts for updates.
- Files on her path (FROZEN) haven't been changed by this branch's own commits
  or by uncommitted edits. Upstream merges don't count. A change there needs a
  behavioural test in partner_flow_test.dart first.
- partner_flow_test.dart matches PARTNER_TEST_SHA256, so it can't be edited to
  fit a change. Updating the hash is a deliberate, reviewed step.

Starts a throwaway library server on localhost (random keys, temp data dir) so
the live library tests run too, then runs the server's own tests. Once
KAZUMI_PUBLIC exists in lib/, the partner tests must also FAIL when built with
it, which proves they are really testing the non-public path.

    python scripts/partner_check.py

Exit 0: all passed.
"""

from __future__ import annotations

import hashlib
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


PARTNER_TEST = "test/partner_flow_test.dart"
PARTNER_TEST_SHA256 = "18eb43b8d85d2e47bcecbe70148f737574083029ce98244fa8d8b3044075f645"

# Her path. Directories end with "/".
FROZEN = [
    "codemagic.yaml",
    "ios/",
    "pubspec.yaml",
    "pubspec.lock",
    "lib/main.dart",
    "lib/app_widget.dart",
    "lib/core_module.dart",
    "lib/navigation.dart",
    "lib/pages/init_page.dart",
    "lib/pages/onboarding/",
    "lib/pages/index_module.dart",
    "lib/pages/index_page.dart",
    "lib/pages/my/my_page.dart",
    "lib/pages/my/my_controller.dart",
    "lib/pages/my/my_module.dart",
    "lib/pages/library/",
    "lib/services/library/",
    "lib/pages/player/",
    "lib/services/player/",
    "lib/pages/video/",
    "lib/services/storage/",
    "lib/services/download/",
    "lib/pages/download/download_controller.dart",
    "lib/repositories/",
    "lib/services/plugin/",
    "lib/plugins/",
    "lib/request/core/",
    "lib/request/apis/plugin_catalog_api.dart",
    "lib/services/update/startup_update_check.dart",
    "lib/bean/dialog/",
]


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True,
                          check=True, encoding="utf-8").stdout


def frozen(path: str) -> bool:
    return any(path == f or (f.endswith("/") and path.startswith(f)) for f in FROZEN)


def guard_codemagic() -> list[str]:
    text = (ROOT / "codemagic.yaml").read_text(encoding="utf-8")
    problems = []
    if "KAZUMI_PUBLIC" in text:
        problems.append("codemagic.yaml mentions KAZUMI_PUBLIC; her build must never set it")
    if "--build-number" not in text:
        problems.append("codemagic.yaml lost --build-number; her app would never prompt to update")
    return problems


def guard_frozen() -> list[str]:
    # First parent only: this branch's own commits, not upstream's merged in.
    committed = git("log", "--first-parent", "--no-merges", "--format=", "--name-only",
                    "main..HEAD").split()
    uncommitted = git("diff", "--name-only", "HEAD").split()
    untracked = git("ls-files", "--others", "--exclude-standard").split()
    touched = sorted({p for p in committed + uncommitted + untracked if frozen(p)})
    return [f"{p} is on her path and changed (see FROZEN)" for p in touched]


def guard_partner_test() -> list[str]:
    text = (ROOT / PARTNER_TEST).read_bytes().replace(b"\r\n", b"\n")
    digest = hashlib.sha256(text).hexdigest()
    if digest != PARTNER_TEST_SHA256:
        return [f"{PARTNER_TEST} changed (sha256 {digest}); update PARTNER_TEST_SHA256 only "
                "after reviewing why"]
    return []


def public_flag_exists() -> bool:
    return any("KAZUMI_PUBLIC" in p.read_text(encoding="utf-8", errors="ignore")
               for p in (ROOT / "lib").rglob("*.dart"))


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
    problems = guard_codemagic() + guard_frozen() + guard_partner_test()
    if problems:
        print("partner check: FAIL (guards)")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("guards: codemagic.yaml, frozen files and the partner test are untouched")

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

    flag_ok = True
    if public_flag_exists():
        # Built as the public build, her tests must break; if they don't,
        # they aren't exercising the path the flag switches.
        flag_ok = not run(["fvm", "flutter", "test", PARTNER_TEST,
                           "--dart-define=KAZUMI_PUBLIC=true"], ROOT)

    ok = dart_ok and server_ok and flag_ok
    print("\npartner check:", "PASS" if ok else "FAIL")
    print(f"  app tests:    {'pass' if dart_ok else 'FAIL'}")
    print(f"  server tests: {'pass' if server_ok else 'FAIL'}")
    if public_flag_exists():
        print(f"  public build breaks her tests: {'yes' if flag_ok else 'NO (FAIL)'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

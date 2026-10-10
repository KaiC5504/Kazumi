"""Runs every automated check that covers the partner's side of the app.

Her path: TestFlight install, invite code, 一起看 with SyncPlay, the update
prompt and the TestFlight update. `codemagic.py start` refuses to build a
commit this script hasn't passed.

    python scripts/partner_check.py

Guards, before any test:
- codemagic.yaml (her build) never sets KAZUMI_PUBLIC, reads no dart-define
  file, and still passes --build-number="$BUILD_NUMBER" (without it her app
  never prompts for updates).
- Every compile-time flag read in lib/ is one listed in KNOWN_FLAGS, so a new
  or renamed flag can't slip past the checks below.
- The fork's own lines in FROZEN files are what they were at the
  `partner-baseline` tag. Upstream's changes don't count; edits made while
  resolving a merge do. FROZEN includes this script, its tests and
  codemagic.py.
- A changed file that a FROZEN file imports must be in TESTED_EDITS, i.e. have
  behaviour tests in partner_flow_test.dart.

Then `flutter analyze`, the app tests on her path against a throwaway local
library server, and the server's own tests. Once KAZUMI_PUBLIC is read in
lib/, partner_flow_test built with it must fail exactly the tests in
PUBLIC_MUST_FAIL, which proves those tests run the path the flag switches.

On a pass with a clean tree, the commit's tree is recorded for codemagic.py.

A deliberate change to her path fails the frozen guard until it is signed off:
make sure partner_flow_test.dart covers it, then move the baseline to it.
    git tag -f partner-baseline <commit>
The tag stays local: the repo is public, so never push it.
Work that must not touch her path (the public build) never moves it.

Exit 0: all passed.
"""

from __future__ import annotations

import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SERVER = ROOT / "server"
WIN = sys.platform == "win32"
BASELINE = "partner-baseline"
STAMP = "partner-check-pass"

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")

PARTNER_TEST = "test/partner_flow_test.dart"

DART_TESTS = [
    PARTNER_TEST,
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
    "test/syncplay_sim_clock_test.dart",
    "test/player_room_speed_test.dart",
    "test/playback_end_guard_test.dart",
    "test/playback_end_wiring_test.dart",
    "test/download_relocation_test.dart",
    "test/offline_launch_test.dart",
]

# Her path. Directories end with "/".
FROZEN = [
    "codemagic.yaml",
    "ios/",
    "pubspec.yaml",
    "pubspec.lock",
    "assets/",
    "lib/main.dart",
    "lib/app_module.dart",
    "lib/app_widget.dart",
    "lib/core_module.dart",
    "lib/navigation.dart",
    "lib/pages/init_page.dart",
    "lib/pages/onboarding/",
    "lib/pages/index_module.dart",
    "lib/pages/index_page.dart",
    "lib/pages/menu/",
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
    "lib/services/upscale/",
    "lib/modules/",
    "lib/pages/download/download_controller.dart",
    "lib/pages/download/download_episode_sheet.dart",
    "lib/pages/settings/settings_module.dart",
    "lib/pages/settings/danmaku/danmaku_settings_sheet.dart",
    "lib/repositories/",
    "lib/services/plugin/",
    "lib/plugins/",
    "lib/request/core/",
    "lib/request/apis/plugin_catalog_api.dart",
    "lib/services/update/startup_update_check.dart",
    "lib/bean/dialog/",
    "test/support/",
    *DART_TESTS,
    "scripts/partner_check.py",
    "scripts/codemagic.py",
    "scripts/precheck.py",
]

# Files on her path the public build is expected to edit, each covered by
# behaviour tests in partner_flow_test.dart.
TESTED_EDITS = {
    "lib/pages/my/my_space_view.dart",
    "lib/services/update/testflight_update.dart",
    "lib/request/config/api_endpoints.dart",
}

KNOWN_FLAGS = {
    "DANDANAPI_APPID",
    "DANDANAPI_KEY",
    "KAZUMI_APPID",
    "KAZUMI_KEY",
    "KAZUMI_LIBRARY_SERVER",
    "KAZUMI_PUBLIC",
}

PUBLIC_MUST_FAIL = {
    "built-in addresses in her build the update prompt reads latest.json on HK "
    "and opens TestFlight",
    "built-in addresses in her build rules come through the HK mirror, which is "
    "on by default",
    "我的 page shows 一起看 and opens it (400 px)",
    "我的 page shows 一起看 and opens it (1200 px)",
    "我的 page with watch history still shows 一起看 and opens it (400 px)",
    "我的 page with watch history still shows 一起看 and opens it (1200 px)",
}

FLAG_RE = re.compile(r"fromEnvironment\(\s*['\"]([A-Za-z0-9_]+)['\"]")


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True,
                          check=True, encoding="utf-8").stdout


def frozen(path: str) -> bool:
    return any(path == f or (f.endswith("/") and path.startswith(f)) for f in FROZEN)


def fork_lines(commit: str | None) -> dict[str, Counter]:
    """The lines the fork adds or removes against upstream, per file.

    [commit] None means the working tree, untracked files included.
    """
    head = commit or "HEAD"
    base = git("merge-base", head, "upstream/main").strip()
    args = ["diff", "--no-renames", "--no-color", "-U0", base]
    if commit:
        args.append(commit)
    out = git(*args, "--", "lib", "ios", "assets", "test", "scripts",
              "codemagic.yaml", "pubspec.yaml", "pubspec.lock")
    lines: dict[str, Counter] = {}
    current = None
    for line in out.splitlines():
        if line.startswith("diff --git "):
            current = line.split(" b/", 1)[1]
            lines[current] = Counter()
        elif current and line[:1] in "+-" and not line.startswith(("+++", "---")):
            lines[current][line] += 1
    if commit is None:
        for path in git("ls-files", "--others", "--exclude-standard", "--", "lib", "ios",
                        "assets", "test", "scripts").split("\n"):
            if path:
                text = (ROOT / path).read_text(encoding="utf-8", errors="replace")
                lines[path] = Counter("+" + l for l in text.splitlines())
    return lines


def imported_by_frozen() -> set[str]:
    found = set()
    for path in (ROOT / "lib").rglob("*.dart"):
        rel = path.relative_to(ROOT).as_posix()
        if not frozen(rel):
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        for target in re.findall(r"import\s+'package:kazumi/([^']+)'", text):
            found.add(f"lib/{target}")
    return found


def guard_codemagic() -> list[str]:
    text = (ROOT / "codemagic.yaml").read_text(encoding="utf-8")
    live = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
    problems = []
    if "KAZUMI_PUBLIC" in text:
        problems.append("codemagic.yaml mentions KAZUMI_PUBLIC; her build must never set it")
    if "dart-define-from-file" in text:
        problems.append("codemagic.yaml reads a dart-define file; flags must be visible here")
    if '--build-number="$BUILD_NUMBER"' not in live:
        problems.append('codemagic.yaml lost --build-number="$BUILD_NUMBER"; '
                        "her app would never prompt to update")
    return problems


def guard_flags() -> list[str]:
    used = set()
    for path in (ROOT / "lib").rglob("*.dart"):
        used |= set(FLAG_RE.findall(path.read_text(encoding="utf-8", errors="ignore")))
    return [f"lib/ reads build flag {name}, which partner_check doesn't know; add it to "
            "KNOWN_FLAGS and cover it in partner_flow_test.dart" for name in sorted(used - KNOWN_FLAGS)]


def guard_frozen() -> list[str]:
    try:
        git("rev-parse", "--verify", "upstream/main")
        git("rev-parse", "--verify", BASELINE)
    except subprocess.CalledProcessError:
        return [f"needs refs upstream/main and the {BASELINE} tag "
                "(git fetch upstream; git fetch origin --tags)"]
    before = fork_lines(BASELINE)
    now = fork_lines(None)
    changed = sorted(p for p in set(before) | set(now)
                     if before.get(p, Counter()) != now.get(p, Counter()))
    problems = [f"{p} is on her path (FROZEN) and changed since {BASELINE}"
                for p in changed if frozen(p)]
    imported = imported_by_frozen()
    problems += [f"{p} changed and is imported by her path; it needs partner tests "
                 "and a place in TESTED_EDITS" for p in changed
                 if p in imported and not frozen(p) and p not in TESTED_EDITS]
    return problems


def public_flag_read() -> bool:
    return any("KAZUMI_PUBLIC" in FLAG_RE.findall(p.read_text(encoding="utf-8", errors="ignore"))
               for p in (ROOT / "lib").rglob("*.dart"))


def failing_tests(args: list[str]) -> tuple[set[str], bool]:
    """Names of failed tests, and whether anything failed outside a test (e.g. compile)."""
    out = subprocess.run(["fvm", "flutter", "test", "--reporter", "json", *args], cwd=ROOT,
                         capture_output=True, text=True, encoding="utf-8", shell=WIN).stdout
    names: dict[int, str] = {}
    failed: set[str] = set()
    broken = False
    for line in out.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        if event.get("type") == "testStart":
            names[event["test"]["id"]] = event["test"]["name"]
        elif event.get("type") == "testDone" and event.get("result") != "success":
            name = names.get(event["testID"], "")
            if name.startswith("loading ") or not name:
                broken = True
            else:
                failed.add(name)
        elif event.get("type") == "error" and names.get(event.get("testID"), "").startswith("loading "):
            broken = True
    return failed, broken


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


def app_tests() -> bool:
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
        return run(["fvm", "flutter", "test", *DART_TESTS], ROOT, test_env)
    finally:
        if WIN:
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(server.pid)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            server.terminate()
        server.wait()
        shutil.rmtree(data, ignore_errors=True)


def record_pass() -> str:
    if git("status", "--porcelain").strip():
        return "not recorded: uncommitted changes (commit, then run again)"
    tree = git("rev-parse", "HEAD^{tree}").strip()
    stamp = Path(git("rev-parse", "--git-common-dir").strip())
    if not stamp.is_absolute():
        stamp = ROOT / stamp
    with open(stamp / STAMP, "a", encoding="utf-8") as f:
        f.write(f"{tree} {git('rev-parse', 'HEAD').strip()}\n")
    return f"recorded tree {tree[:12]} for codemagic.py start"


def main() -> int:
    problems = guard_codemagic() + guard_flags() + guard_frozen()
    if problems:
        print("partner check: FAIL (guards)")
        for p in problems:
            print(f"  - {p}")
        return 1
    print(f"guards: codemagic.yaml, build flags and her path match {BASELINE}")

    results = {
        "analyze": run(["fvm", "flutter", "analyze", "--no-fatal-infos", "--fatal-warnings"],
                       ROOT),
        "app tests": app_tests(),
        "server tests": run(["uv", "run", "pytest", "-q"], SERVER),
    }
    if public_flag_read():
        print("\n$ fvm flutter test", PARTNER_TEST, "--dart-define=KAZUMI_PUBLIC=true")
        failed, broken = failing_tests([PARTNER_TEST, "--dart-define=KAZUMI_PUBLIC=true"])
        missing = PUBLIC_MUST_FAIL - failed
        results["public build breaks her tests"] = not broken and not missing
        if broken:
            print("  the public build didn't compile or load")
        for name in sorted(missing):
            print(f"  still passes with KAZUMI_PUBLIC=true: {name}")

    ok = all(results.values())
    print("\npartner check:", "PASS" if ok else "FAIL")
    for name, passed in results.items():
        print(f"  {name}: {'pass' if passed else 'FAIL'}")
    if ok:
        print(f"  {record_pass()}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

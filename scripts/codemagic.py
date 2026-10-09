#!/usr/bin/env python3
"""Start and watch Codemagic builds from the command line.

The token is read from the environment or from a file in your home directory, never from
this repository. Nothing here writes a token anywhere.

    export CODEMAGIC_API_TOKEN=...        # or
    printf '%s' '<token>' > ~/.codemagic-token

    python scripts/codemagic.py status         # latest build
    python scripts/codemagic.py watch          # poll until it finishes, then report
    python scripts/codemagic.py start [branch] # trigger one by hand; the pushed commit must
        # have passed scripts/partner_check.py (--skip-partner-check overrides)
    python scripts/codemagic.py publish-latest [--required] [--notes TEXT]
        # after a build passes: tell installed apps about it (HK latest.json)
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
import urllib.error
import urllib.request
from pathlib import Path

# The Windows console defaults to cp1252 and dies on a Chinese commit message.
sys.stdout.reconfigure(encoding="utf-8")

API = "https://api.codemagic.io"
APP_NAME_HINT = "Kazumi"  # the app name shown in Codemagic
WORKFLOW_ID = "testflight"

# Codemagic reports these as terminal. Anything else means the build is still moving.
DONE = {"finished", "failed", "canceled", "skipped", "timeout"}


def token() -> str:
    value = os.environ.get("CODEMAGIC_API_TOKEN")
    if not value:
        path = Path.home() / ".codemagic-token"
        if path.exists():
            value = path.read_text(encoding="utf-8").strip()
    if not value:
        raise SystemExit(
            "No token. Codemagic UI -> Account settings -> API token -> Show.\n"
            "It is a personal token; there is no team-level one, and it is not on the\n"
            "Integrations page that lists GitHub and the Developer Portal.\n"
            "Then either:\n"
            "  setx CODEMAGIC_API_TOKEN <token>      (new shells pick it up)\n"
            f"  or write it to {Path.home() / '.codemagic-token'}\n"
            "Do not put it in the repo."
        )
    return value


def call(path: str, payload: dict | None = None) -> dict:
    request = urllib.request.Request(
        f"{API}{path}",
        data=json.dumps(payload).encode() if payload else None,
        headers={"x-auth-token": token(), "Content-Type": "application/json"},
        method="POST" if payload else "GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")[:400]
        raise SystemExit(f"{error.code} from {path}: {body}") from None


def step_log(url: str) -> str:
    """Fetch one build step's log.

    Undocumented — the endpoint only shows up as `logUrl` on a build action. It returns
    text with colour applied as HTML spans, so it needs unwrapping before it is readable.
    """
    request = urllib.request.Request(url, headers={"x-auth-token": token()})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read().decode(errors="replace")
    except urllib.error.HTTPError as error:
        return f"(could not fetch log: HTTP {error.code})"
    return html.unescape(re.sub(r"</?span[^>]*>", "", body))


def app_id() -> str:
    apps = call("/apps").get("applications", [])
    if not apps:
        raise SystemExit("The token is valid but sees no applications.")
    for app in apps:
        if APP_NAME_HINT.lower() in (app.get("appName") or "").lower():
            return app["_id"]
    names = ", ".join(a.get("appName", "?") for a in apps)
    raise SystemExit(f"No app matching {APP_NAME_HINT!r}. Found: {names}")


def latest() -> dict | None:
    builds = call(f"/builds?appId={app_id()}").get("builds", [])
    return builds[0] if builds else None


def report(build: dict) -> None:
    status = build.get("status", "?")
    commit = (build.get("commit") or {}).get("commitMessage", "").splitlines()
    print(f"build   {build.get('index', '?')}  {status}")
    print(f"branch  {build.get('branch', '?')}")
    if commit:
        print(f"commit  {commit[0]}")
    print(f"url     https://codemagic.io/app/{build.get('appId')}/build/{build.get('_id')}")

    actions = build.get("buildActions") or []
    if not actions:
        return
    print("\nsteps")
    for action in actions:
        name = action.get("name", "?")
        # A step that has not started yet sends a null status, which prints as "None".
        state = action.get("status") or "pending"
        marker = "x" if state == "failed" else ("-" if state in {"skipped", "pending"} else "+")
        print(f"  {marker} {name}: {state}")

    if build.get("message"):
        print(f"\n{build['message'].strip()}")

    for action in actions:
        if action.get("status") != "failed" or not action.get("logUrl"):
            continue
        lines = [line for line in step_log(action["logUrl"]).splitlines() if line.strip()]
        print(f"\n--- {action.get('name')}: last {min(len(lines), 60)} lines ---")
        print("\n".join(lines[-60:]))


def cmd_status() -> int:
    build = latest()
    if not build:
        print("No builds yet.")
        return 0
    report(build)
    return 1 if build.get("status") in {"failed", "timeout"} else 0


def cmd_watch() -> int:
    build = latest()
    if not build:
        print("No builds yet.")
        return 0
    build_id, seen = build["_id"], None
    while True:
        build = call(f"/builds/{build_id}").get("build", build)
        status = build.get("status")
        if status != seen:
            print(f"  {status}")
            seen = status
        if status in DONE:
            print()
            report(build)
            return 1 if status in {"failed", "timeout"} else 0
        time.sleep(20)


def partner_check_passed(branch: str) -> bool:
    """Whether scripts/partner_check.py passed on the tree Codemagic will build."""
    def git(*args: str) -> str:
        return subprocess.run(["git", *args], capture_output=True, text=True,
                              encoding="utf-8", check=True).stdout.strip()

    git("fetch", "-q", "origin", branch)
    tree = git("rev-parse", f"origin/{branch}^{{tree}}")
    stamp = Path(git("rev-parse", "--git-common-dir")) / "partner-check-pass"
    try:
        passed = {line.split()[0] for line in stamp.read_text(encoding="utf-8").splitlines()
                  if line.strip()}
    except FileNotFoundError:
        passed = set()
    return tree in passed


def cmd_start(branch: str, skip_partner_check: bool = False) -> int:
    if skip_partner_check:
        print("WARNING: skipping the partner check; her build may change untested")
    elif not partner_check_passed(branch):
        print(f"origin/{branch} hasn't passed scripts/partner_check.py. Check out that exact "
              "commit, run it, and start again.")
        return 1
    result = call("/builds", {"appId": app_id(), "workflowId": WORKFLOW_ID, "branch": branch})
    print(f"started {result.get('buildId')} on {branch}")
    return 0


# The app reads this on every launch (lib/services/update/testflight_update.dart).
LATEST_HOST = "KaiCHK"
LATEST_PATH = "/srv/app/latest.json"


def ssh(command: str, stdin: str | None = None) -> str:
    result = subprocess.run(
        ["ssh", LATEST_HOST, command],
        input=stdin, capture_output=True, text=True, encoding="utf-8", timeout=60,
    )
    if result.returncode != 0:
        raise SystemExit(f"ssh {LATEST_HOST} failed: {result.stderr.strip()}")
    return result.stdout


def cmd_publish_latest(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="codemagic.py publish-latest")
    parser.add_argument("--required", action="store_true",
                        help="builds older than this one must update")
    parser.add_argument("--notes", default="", help="shown in the update dialog")
    args = parser.parse_args(argv)

    build = latest()
    if not build or build.get("status") != "finished":
        raise SystemExit("The latest Codemagic build hasn't passed; nothing to publish.")
    ipa = next((a for a in build.get("artefacts") or [] if a.get("type") == "ipa"), None)
    if not ipa or not str(ipa.get("versionCode", "")).isdigit():
        raise SystemExit("The build has no IPA with a build number.")
    number, version = int(ipa["versionCode"]), ipa.get("versionName") or ipa.get("version")

    previous = {}
    raw = ssh(f"sudo cat {LATEST_PATH} 2>/dev/null || true")
    if raw.strip():
        previous = json.loads(raw)
    if previous.get("build", 0) > number:
        raise SystemExit(f"HK already announces build {previous['build']}, newer than {number}.")

    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    latest_json = {
        "build": number,
        "version": version,
        "minBuild": number if args.required else previous.get("minBuild", 0),
        "requiredSince": now if args.required else previous.get("requiredSince"),
        "notes": args.notes,
        "publishedAt": now,
    }
    body = json.dumps(latest_json, ensure_ascii=False, indent=1) + "\n"
    ssh(f"sudo mkdir -p {Path(LATEST_PATH).parent.as_posix()} && "
        f"sudo tee {LATEST_PATH}.tmp >/dev/null && sudo chmod 644 {LATEST_PATH}.tmp && "
        f"sudo mv {LATEST_PATH}.tmp {LATEST_PATH}", stdin=body)
    print(f"published {version} ({number})"
          + (" as required" if args.required else "")
          + f" -> https://hk.kaic5504.com/app/latest.json")
    print(body)
    return 0


def main() -> int:
    command = sys.argv[1] if len(sys.argv) > 1 else "status"
    if command == "status":
        return cmd_status()
    if command == "watch":
        return cmd_watch()
    if command == "start":
        rest = [a for a in sys.argv[2:] if a != "--skip-partner-check"]
        return cmd_start(rest[0] if rest else "main",
                         skip_partner_check="--skip-partner-check" in sys.argv)
    if command == "publish-latest":
        return cmd_publish_latest(sys.argv[2:])
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

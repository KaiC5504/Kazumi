#!/usr/bin/env python3
"""Start, watch and publish the signed TestFlight build (.github/workflows/testflight.yaml).

    python scripts/testflight.py status                     # latest run
    python scripts/testflight.py start [--dry-run] [--again]  # build origin/main's head
    python scripts/testflight.py watch [RUN_ID]             # poll until done, then report
    python scripts/testflight.py publish-latest [--required] [--notes TEXT]
        # after a run passes: tell installed apps about it (HK latest.json)

start refuses unless origin/main passed scripts/partner_check.py, carries all of
upstream/main and the `testflight` environment is locked to main with its secrets in
place; the workflow then refuses to build any other commit. --dry-run signs and checks
the IPA without uploading; --again rebuilds a commit that already shipped.

A run passes once Apple has finished processing the upload, a few minutes before
testers can install it.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import partner_check  # noqa: E402

REPO = "KaiC5504/Kazumi"
WORKFLOW = "testflight.yaml"
ENVIRONMENT = "testflight"
SECRETS = {
    "APP_STORE_CONNECT_ISSUER_ID",
    "APP_STORE_CONNECT_KEY_IDENTIFIER",
    "APP_STORE_CONNECT_PRIVATE_KEY",
    "CERT_KEY_B64",
    "TESTFLIGHT_DANDANAPI_APPID",
    "TESTFLIGHT_DANDANAPI_KEY",
}
ARTIFACT = "testflight-build"
MANIFEST = "testflight-build.json"
# The workflow's run-name starts with one of these.
UPLOAD = "TestFlight upload"
DRY_RUN = "TestFlight dry run"
FIELDS = "databaseId,displayTitle,status,conclusion,headSha,headBranch,event,url"
# A background watch outlives short network trouble; this many failed polls in a row
# ends it.
WATCH_RETRIES = 5
# The app reads this on every launch (lib/services/update/testflight_update.dart).
LATEST_HOST = "KaiCHK"
LATEST_PATH = "/srv/app/latest.json"


def run(*args: str) -> str:
    result = subprocess.run(list(args), capture_output=True, text=True, encoding="utf-8",
                            errors="replace")
    if result.returncode != 0:
        raise SystemExit(f"{' '.join(args[:3])} failed: {result.stderr.strip()}")
    return result.stdout


def git(*args: str) -> str:
    return run("git", *args).strip()


def runs(limit: int = 20) -> list[dict]:
    return json.loads(run("gh", "run", "list", "-R", REPO, "--workflow", WORKFLOW,
                          "--limit", str(limit), "--json", FIELDS))


def view(run_id: int | str, fields: str = FIELDS) -> dict:
    return json.loads(run("gh", "run", "view", str(run_id), "-R", REPO, "--json", fields))


def uploads() -> list[dict]:
    """Upload runs dispatched on main, newest first. A fork PR can run its own copy of
    the workflow, with any title and artifact, from a branch it also calls main."""
    return [r for r in runs() if r["displayTitle"].startswith(UPLOAD)
            and r["headBranch"] == "main" and r.get("event") == "workflow_dispatch"]


def last_shipped() -> dict | None:
    """The newest upload run that passed, i.e. a build Apple accepted."""
    return next((r for r in uploads() if r["conclusion"] == "success"), None)


def report(run_: dict) -> None:
    state = run_["conclusion"] or run_["status"]
    print(f"run     {run_['databaseId']}  {state}")
    print(f"title   {run_['displayTitle']}")
    print(f"url     {run_['url']}")
    for job in view(run_["databaseId"], "jobs")["jobs"]:
        print(f"\n{job['name']}: {job['conclusion'] or job['status']}")
        for step in job["steps"]:
            step_state = step["conclusion"] or step["status"]
            marker = ("x" if step_state in {"failure", "cancelled", "timed_out"}
                      else "-" if step_state in {"skipped", "pending", "queued"} else "+")
            print(f"  {marker} {step['name']}: {step_state}")
    if failed(run_):
        log = subprocess.run(["gh", "run", "view", str(run_["databaseId"]), "-R", REPO,
                              "--log-failed"], capture_output=True, text=True,
                             encoding="utf-8", errors="replace").stdout
        lines = [line for line in log.splitlines() if line.strip()]
        if lines:
            print(f"\n--- failed steps: last {min(len(lines), 60)} lines ---")
            print("\n".join(lines[-60:]))
        print(f"\nIf only Apple processing failed or timed out: gh run rerun "
              f"{run_['databaseId']} -R {REPO} --failed")


def failed(run_: dict) -> bool:
    return run_["status"] == "completed" and run_["conclusion"] != "success"


def cmd_status() -> int:
    latest = runs(1)
    if not latest:
        print("No TestFlight runs yet.")
        return 0
    report(latest[0])
    return 1 if failed(latest[0]) else 0


def partner_check_passed() -> bool:
    """Whether scripts/partner_check.py passed on the tree of origin/main."""
    tree = git("rev-parse", "origin/main^{tree}")
    stamp = Path(git("rev-parse", "--git-common-dir")) / partner_check.STAMP
    try:
        passed = {line.split()[0] for line in stamp.read_text(encoding="utf-8").splitlines()
                  if line.strip()}
    except FileNotFoundError:
        passed = set()
    return tree in passed


def environment_problems() -> list[str]:
    """The secrets are only as safe as this environment's lock to main."""
    env = json.loads(run("gh", "api", f"repos/{REPO}/environments/{ENVIRONMENT}"))
    policy = env.get("deployment_branch_policy") or {}
    problems = []
    if not policy.get("custom_branch_policies") or policy.get("protected_branches"):
        problems.append(f"environment {ENVIRONMENT} isn't limited to chosen branches")
    else:
        branches = json.loads(run("gh", "api",
                                  f"repos/{REPO}/environments/{ENVIRONMENT}/deployment-branch-policies"))
        names = sorted(p["name"] for p in branches.get("branch_policies", []))
        if names != ["main"]:
            problems.append(f"environment {ENVIRONMENT} allows {names}, not just main")
    names = {s["name"] for s in json.loads(run("gh", "secret", "list", "--env", ENVIRONMENT,
                                                "-R", REPO, "--json", "name"))}
    problems += [f"environment {ENVIRONMENT} has no secret {name}" for name in sorted(SECRETS - names)]
    return problems


def dispatched_run(output: str, known: set[int], sha: str) -> dict | None:
    """The run `gh workflow run` just made: from the URL it prints (gh 2.87+), else the
    newest unknown run for this commit."""
    match = re.search(r"/actions/runs/(\d+)", output)
    for _ in range(40):
        try:
            if match:
                # The title is the workflow's bare name until GitHub evaluates run-name.
                found = view(match.group(1))
                if sha in found["displayTitle"]:
                    return found
            else:
                new = [r for r in runs(10)
                       if r["databaseId"] not in known and sha in r["displayTitle"]]
                if new:
                    return new[0]
        except SystemExit:
            pass
        time.sleep(3)
    return None


def cmd_start(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="testflight.py start")
    parser.add_argument("--dry-run", action="store_true", help="sign and check, upload nothing")
    parser.add_argument("--again", action="store_true", help="rebuild a commit that already shipped")
    args = parser.parse_args(argv)

    git("fetch", "-q", "upstream", "main")
    git("fetch", "-q", "origin", "main")
    behind = int(git("rev-list", "--count", "origin/main..upstream/main"))
    if behind:
        print(f"origin/main is {behind} commit(s) behind upstream/main. Merge upstream, "
              "rerun the checks, push, and start again.")
        return 1
    if not partner_check_passed():
        print("origin/main hasn't passed scripts/partner_check.py. Check out that exact "
              "commit, run it, and start again.")
        return 1
    problems = environment_problems()
    if problems:
        print("Not starting:\n" + "\n".join(f"  - {p}" for p in problems))
        return 1
    sha = git("rev-parse", "origin/main")
    shipped = last_shipped()
    if not args.dry_run and not args.again and shipped and shipped["headSha"] == sha:
        print(f"{sha[:8]} already shipped in run {shipped['databaseId']}. "
              "Use --again to build it under a new number.")
        return 1
    before = runs(10)
    busy = [r for r in before if r["status"] != "completed"]
    if busy:
        print(f"run {busy[0]['databaseId']} is still {busy[0]['status']}: {busy[0]['url']}")
        return 1
    head = git("rev-parse", "HEAD")
    if head != sha:
        print(f"note: building origin/main {sha[:8]}; this checkout is at {head[:8]}")

    output = run("gh", "workflow", "run", WORKFLOW, "-R", REPO, "--ref", "main",
                 "-f", f"sha={sha}", "-f", f"upload={'false' if args.dry_run else 'true'}")
    new = dispatched_run(output, {r["databaseId"] for r in before}, sha)
    if not new:
        print("Dispatched, but the run hasn't appeared yet; see `testflight.py status`.")
        return 0
    want = DRY_RUN if args.dry_run else UPLOAD
    if not new["displayTitle"].startswith(want):
        run("gh", "run", "cancel", str(new["databaseId"]), "-R", REPO)
        print(f"run {new['databaseId']} came up as {new['displayTitle']!r}, not {want!r}; "
              "cancelled it.")
        return 1
    print(f"started run {new['databaseId']} on {sha[:8]}"
          + (" (dry run, no upload)" if args.dry_run else ""))
    print(new["url"])
    return 0


def cmd_watch(run_id: str | None) -> int:
    if run_id is None:
        latest = runs(1)
        if not latest:
            print("No TestFlight runs yet.")
            return 0
        run_id = str(latest[0]["databaseId"])
    seen, misses = None, 0
    while True:
        try:
            current = view(run_id)
            misses = 0
        except SystemExit as error:
            misses += 1
            if misses >= WATCH_RETRIES:
                print(f"Lost contact with GitHub ({error}). The run may still be going; "
                      "check `testflight.py status`.")
                return 3
            time.sleep(30)
            continue
        state = current["conclusion"] or current["status"]
        if state != seen:
            print(f"  {state}", flush=True)
            seen = state
        if current["status"] == "completed":
            print()
            report(current)
            return 0 if current["conclusion"] == "success" else 1
        time.sleep(30)


def ssh(command: str, stdin: str | None = None) -> str:
    result = subprocess.run(
        ["ssh", LATEST_HOST, command],
        input=stdin, capture_output=True, text=True, encoding="utf-8", timeout=60,
    )
    if result.returncode != 0:
        raise SystemExit(f"ssh {LATEST_HOST} failed: {result.stderr.strip()}")
    return result.stdout


def publish(build: int, version: str | None, notes: str, required: bool) -> int:
    """Writes latest.json on HK."""
    if not isinstance(version, str) or not version:
        # The app ignores a latest.json without a version, so the prompt would never show.
        raise SystemExit(f"No version for build {build}; not publishing.")
    previous = {}
    raw = ssh(f"sudo cat {LATEST_PATH} 2>/dev/null || true")
    if raw.strip():
        previous = json.loads(raw)
    if previous.get("build", 0) > build:
        raise SystemExit(f"HK already announces build {previous['build']}, newer than {build}.")

    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    latest_json = {
        "build": build,
        "version": version,
        "minBuild": build if required else previous.get("minBuild", 0),
        "requiredSince": now if required else previous.get("requiredSince"),
        "notes": notes,
        "publishedAt": now,
    }
    body = json.dumps(latest_json, ensure_ascii=False, indent=1) + "\n"
    ssh(f"sudo mkdir -p {Path(LATEST_PATH).parent.as_posix()} && "
        f"sudo tee {LATEST_PATH}.tmp >/dev/null && sudo chmod 644 {LATEST_PATH}.tmp && "
        f"sudo mv {LATEST_PATH}.tmp {LATEST_PATH}", stdin=body)
    print(f"published {version} ({build})" + (" as required" if required else "")
          + " -> https://hk.kaic5504.com/app/latest.json")
    print(body)
    return 0


def cmd_publish_latest(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="testflight.py publish-latest")
    parser.add_argument("--required", action="store_true",
                        help="builds older than this one must update")
    parser.add_argument("--notes", default="", help="shown in the update dialog")
    args = parser.parse_args(argv)

    newest = next(iter(uploads()), None)
    if not newest or newest["conclusion"] != "success":
        raise SystemExit("The newest TestFlight upload hasn't passed, or Apple is still "
                         "processing it; nothing to publish. Fix or rerun it first.")
    with tempfile.TemporaryDirectory() as folder:
        run("gh", "run", "download", str(newest["databaseId"]), "-R", REPO,
            "-n", ARTIFACT, "-D", folder)
        manifest = json.loads((Path(folder) / MANIFEST).read_text(encoding="utf-8"))
    if manifest.get("sha") != newest["headSha"] or not str(manifest.get("build")).isdigit():
        raise SystemExit(f"Run {newest['databaseId']}'s manifest doesn't match the run.")
    return publish(int(manifest["build"]), manifest.get("version"), args.notes, args.required)


def main() -> int:
    command = sys.argv[1] if len(sys.argv) > 1 else "status"
    rest = sys.argv[2:]
    if command == "status":
        return cmd_status()
    if command == "start":
        return cmd_start(rest)
    if command == "watch":
        return cmd_watch(rest[0] if rest else None)
    if command == "publish-latest":
        return cmd_publish_latest(rest)
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

"""Local check before a Codemagic build, so a build is never spent on a broken commit.

    python scripts/precheck.py              # compare with the last build that passed
    python scripts/precheck.py --base REF   # compare with any git ref instead

Runs `flutter analyze`, the tests that import a changed file, and a scan of the bundled
assets for files App Store Connect rejects as unsigned code.

Exit 0: go straight to Codemagic.
Exit 2: the native side changed (dependencies, ios/, signing), so run the iOS compile
        check first: gh workflow run ios-check.yaml -R KaiC5504/Kazumi --ref <branch>
Exit 1: a check failed.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")

# Anything here can break `flutter build ios` while Dart analysis stays clean.
NATIVE_PATTERNS = [
    r"^pubspec\.(yaml|lock)$",
    r"^ios/",
    r"^codemagic\.yaml$",
    r"^\.gitmodules$",
]

# App Store Connect rejected a plain .py with no shebang or exec bit (build 18), so
# script types are refused by extension, not by content.
SCRIPT_SUFFIXES = {".py", ".pyc", ".sh", ".bash", ".zsh", ".command", ".pl", ".rb"}

MACH_O_MAGIC = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
}


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
        check=True,
    ).stdout


def last_passed_build() -> str | None:
    try:
        import codemagic
        builds = codemagic.call(f"/builds?appId={codemagic.app_id()}").get("builds", [])
    except BaseException as e:  # codemagic.py exits via SystemExit without a token
        print(f"  (Codemagic unreachable: {e})")
        return None
    for build in builds:
        if build.get("status") == "finished":
            commit = (build.get("commit") or {}).get("hash")
            if commit:
                print(f"  base: build {build.get('index')} ({commit[:8]})")
                return commit
    return None


def changed_files(base: str) -> list[str]:
    tracked = git("diff", "--name-only", base).splitlines()
    untracked = git("ls-files", "--others", "--exclude-standard").splitlines()
    return sorted(set(tracked + untracked))


def only_version_or_assets_changed(base: str) -> bool:
    """Upstream bumps `version:` on every release, and a missing asset is an analyze
    warning, so neither needs the iOS compile."""
    lines = [
        line for line in git("diff", "-U0", base, "--", "pubspec.yaml").splitlines()
        if line[:1] in "+-" and not line.startswith(("+++", "---"))
    ]
    return all(re.match(r"^[+-](version:|    - \S+$)", line) for line in lines)


def bundled_assets() -> list[Path]:
    entries, in_assets = [], False
    for line in (ROOT / "pubspec.yaml").read_text(encoding="utf-8").splitlines():
        if re.match(r"^  assets:\s*$", line):
            in_assets = True
            continue
        if in_assets:
            item = re.match(r"^    - (.+?)\s*$", line)
            if not item:
                break
            entries.append(item.group(1))
    files: list[Path] = []
    for entry in entries:
        path = ROOT / entry
        if entry.endswith("/"):
            # Flutter bundles only the directory's direct children.
            files += [p for p in path.iterdir() if p.is_file()] if path.is_dir() else []
        elif path.is_file():
            files.append(path)
    return files


def check_assets() -> list[str]:
    problems = []
    for path in bundled_assets():
        with path.open("rb") as f:
            head = f.read(4)
        rel = path.relative_to(ROOT).as_posix()
        if path.suffix.lower() in SCRIPT_SUFFIXES:
            problems.append(f"{rel}: script files are rejected by App Store Connect as unsigned code")
        elif head.startswith(b"#!"):
            problems.append(f"{rel}: starts with #!, App Store Connect rejects it as unsigned code")
        elif head in MACH_O_MAGIC:
            problems.append(f"{rel}: Mach-O binary, App Store Connect rejects it unsigned")
    return problems


def tests_for(changed: list[str]) -> list[str]:
    modules = set()
    for name in changed:
        if name.startswith("lib/") and name.endswith(".dart"):
            # A .g.dart is a part file; its library is the matching .dart.
            name = re.sub(r"\.g\.dart$", ".dart", name)
            modules.add("package:kazumi/" + name[len("lib/"):])
    selected = []
    for test in sorted((ROOT / "test").rglob("*_test.dart")):
        rel = test.relative_to(ROOT).as_posix()
        if rel in changed or any(m in test.read_text(encoding="utf-8") for m in modules):
            selected.append(rel)
    return selected


def flutter(*args: str) -> bool:
    print(f"\n$ fvm flutter {' '.join(args)}", flush=True)
    return subprocess.run(["fvm", "flutter", *args], cwd=ROOT, shell=sys.platform == "win32").returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", help="git ref to diff against")
    args = parser.parse_args()

    print("precheck")
    base = args.base or last_passed_build() or "origin/main"
    changed = changed_files(base)
    print(f"  {len(changed)} file(s) changed since {base[:12]}")

    failed = []
    asset_problems = check_assets()
    for problem in asset_problems:
        print(f"  ASSET  {problem}")
    if asset_problems:
        failed.append("assets")

    if subprocess.run([sys.executable, str(ROOT / "scripts" / "pack_cloud_worker.py"), "--check"]).returncode:
        failed.append("packed cloud worker")

    if not flutter("analyze", "--no-fatal-infos", "--fatal-warnings"):
        failed.append("analyze")

    tests = tests_for(changed)
    if tests:
        print(f"\n  {len(tests)} test file(s) cover the changes")
        if not flutter("test", *tests):
            failed.append("tests")
    else:
        print("\n  no tests import the changed files")

    if any(f.startswith(("server/cloud/", "test/cloud_worker/")) for f in changed):
        print("\n$ python -m unittest (cloud worker)", flush=True)
        worker_tests = subprocess.run(
            [sys.executable, "-m", "unittest", "discover", "-s", "test/cloud_worker", "-p", "test_*.py"],
            cwd=ROOT,
        )
        if worker_tests.returncode:
            failed.append("cloud worker tests")

    native = sorted({f for f in changed if any(re.search(p, f) for p in NATIVE_PATTERNS)})
    if "pubspec.yaml" in native and only_version_or_assets_changed(base):
        native.remove("pubspec.yaml")

    print("\nresult")
    if failed:
        print(f"  FAILED: {', '.join(failed)}")
        return 1
    if native:
        print("  native side changed, run the iOS compile check before Codemagic:")
        for f in native:
            print(f"    {f}")
        return 2
    print("  OK, go straight to Codemagic")
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""Checks that the public build switches only what it should.

    python scripts/public_check.py            # everything (local)
    python scripts/public_check.py --static   # text checks only, no Flutter (CI)

Static:
- lib/ reads KAZUMI_PUBLIC exactly once, as the const in lib/build_flavor.dart
  (a non-const read doesn't reliably see the define: it's false under
  `flutter test` and in AOT), and nothing else names the flag or uses
  appFlavor.
- codemagic.yaml, ios-check.yaml and pr.yaml carry no public define.
- Every `flutter build` in public-release.yaml passes
  --dart-define=KAZUMI_PUBLIC=true and --dart-define=KAZUMI_LIBRARY_SERVER=,
  and its DanDanPlay secrets are PUBLIC_ ones.
- With GITHUB_TOKEN or GH_TOKEN set, every other workflow a tag push, tag
  creation or release event starts is disabled_manually.
- The packed cloud worker has no owner host (the binary scan can't read it).
- scan_public_build.py finds exactly the owner's host in a generated APK that
  also holds the fork's GitHub link and the control string.

Local, on top:
- analysis_options.yaml is what it was at partner-baseline.
- No new relative or double-quoted import/export/part in lib/.
- Changed files reachable from her path (the transitive import closure of
  partner_check's FROZEN files): every line the fork removed since
  partner-baseline comes back (whitespace aside) in the same hunk, unless the
  hunk adds a public gate in code (comments don't count). In a gated hunk,
  every string literal of such a line must still be on the personal side of
  the gate. Each such file has a personal-mode test, and those tests pass
  without defines.
- The whole test/ dir with both public defines fails only in the FROZEN
  suites that pin her values, fails at least partner_check's
  PUBLIC_MUST_FAIL (proof the defines arrived), and nothing fails to load.

Exit 0: all passed. Writes no stamp.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from collections import Counter
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import partner_check as pc  # noqa: E402  (FROZEN; imported, never edited)
import scan_public_build as scanner  # noqa: E402

WIN = sys.platform == "win32"
BASELINE = pc.BASELINE
WORKFLOWS = ROOT / ".github" / "workflows"
PUBLIC_WORKFLOW = "public-release.yaml"
FLAVOR_FILE = "lib/build_flavor.dart"
FLAVOR_LINE = "const bool kPublicBuild = bool.fromEnvironment('KAZUMI_PUBLIC');"
PUBLIC_DEFINES = ("--dart-define=KAZUMI_PUBLIC=true", "--dart-define=KAZUMI_LIBRARY_SERVER=")
PERSONAL_WORKFLOWS = ("codemagic.yaml", ".github/workflows/ios-check.yaml",
                      ".github/workflows/pr.yaml")

# A hunk that adds one of these may drop lines: what it replaces now sits
# behind the flag.
GATES = ("kPublicBuild", "showCloudUi")

# Changed files on her path, each with the test that pins its personal mode.
PERSONAL_TESTS = {
    "lib/build_flavor.dart": "test/public_build_test.dart",
    "lib/pages/my/my_space_view.dart": "test/public_build_test.dart",
    "lib/services/update/testflight_update.dart": "test/public_build_test.dart",
    "lib/services/update/public_update.dart": "test/public_build_test.dart",
    "lib/request/config/api_endpoints.dart": "test/public_build_test.dart",
    "lib/pages/download/download_page.dart": "test/public_build_test.dart",
    "lib/pages/download/public_gates.dart": "test/public_build_test.dart",
    "lib/pages/about/about_page.dart": "test/public_build_test.dart",
    "lib/pages/about/fork_about_section.dart": "test/public_build_test.dart",
}

# FROZEN suites that pin her built-in values; the public build is meant to
# fail them. Anything failing elsewhere broke a kept feature.
PUBLIC_FAIL_SUITES = {"test/partner_flow_test.dart", "test/testflight_update_test.dart"}

LITERAL_RE = re.compile(r"'(?:[^'\\\n]|\\.)*'" r'|"(?:[^"\\\n]|\\.)*"')
DIRECTIVE_RE = re.compile(r"^\s*(?:import|export|part)\b([^;]*);", re.M)
URI_RE = re.compile(r"""(['"])([^'"]+)\1""")

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8", errors="replace")


# ---------------------------------------------------------------- static


def check_flag_reads() -> list[str]:
    problems = []
    reads = []
    for path in sorted((ROOT / "lib").rglob("*.dart")):
        rel = path.relative_to(ROOT).as_posix()
        text = path.read_text(encoding="utf-8", errors="ignore")
        for n, line in enumerate(text.splitlines(), 1):
            if "KAZUMI_PUBLIC" in line:
                reads.append((rel, n, line.strip()))
            if re.search(r"\bappFlavor\b", line):
                problems.append(f"{rel}:{n} uses appFlavor; KAZUMI_PUBLIC is the only switch")
    if [(r, l) for r, _, l in reads] != [(FLAVOR_FILE, FLAVOR_LINE)]:
        problems.append(f"lib/ must name KAZUMI_PUBLIC exactly once, as `{FLAVOR_LINE}` "
                        f"in {FLAVOR_FILE}; found:")
        problems += [f"    {r}:{n}: {l}" for r, n, l in reads] or ["    nothing"]
    return problems


def check_personal_workflows() -> list[str]:
    problems = []
    for rel in PERSONAL_WORKFLOWS:
        path = ROOT / rel
        if path.exists():
            text = path.read_text(encoding="utf-8")
            for name in ("KAZUMI_PUBLIC", "KAZUMI_LIBRARY_SERVER"):
                if name in text:
                    problems.append(f"{rel} mentions {name}; only {PUBLIC_WORKFLOW} may")
    return problems


def run_blocks(text: str) -> list[str]:
    """The shell text of every `run:` step, with folded lines and line
    continuations joined into single commands."""
    lines = text.splitlines()
    blocks = []
    i = 0
    while i < len(lines):
        m = re.match(r"^(\s*)(?:-\s+)?run:\s*(.*)$", lines[i])
        i += 1
        if not m:
            continue
        indent, value = len(m.group(1)), m.group(2).strip()
        if value[:1] not in ("|", ">"):
            blocks.append(value)
            continue
        body = []
        while i < len(lines) and (not lines[i].strip() or
                                  len(lines[i]) - len(lines[i].lstrip()) > indent):
            body.append(lines[i].strip())
            i += 1
        if value.startswith(">"):
            blocks.append(" ".join(l for l in body if l))
        else:
            joined = "\n".join(body)
            blocks.append(re.sub(r"[\\`]\n", " ", joined))
    return blocks


def tokens(command: str) -> list[str]:
    return [t.strip("'\"") for t in re.findall(r"""(?:"[^"]*"|'[^']*'|\S)+""", command)]


def check_public_workflow() -> list[str]:
    path = WORKFLOWS / PUBLIC_WORKFLOW
    if not path.exists():
        return [f".github/workflows/{PUBLIC_WORKFLOW} is missing"]
    text = path.read_text(encoding="utf-8")
    problems = []
    builds = []
    for block in run_blocks(text):
        for command in block.split("\n"):
            if re.search(r"\bflutter\s+build\b", command):
                builds.append(command)
    if not builds:
        problems.append(f"{PUBLIC_WORKFLOW} has no `flutter build`")
    for command in builds:
        have = tokens(command)
        for define in PUBLIC_DEFINES:
            if define not in have:
                problems.append(f"{PUBLIC_WORKFLOW}: `flutter build` without {define}: "
                                f"{command[:120]}")
    for name in re.findall(r"secrets\.([A-Za-z0-9_]*DANDANAPI[A-Za-z0-9_]*)", text):
        if not name.startswith("PUBLIC_"):
            problems.append(f"{PUBLIC_WORKFLOW} uses secrets.{name}; public builds use "
                            "PUBLIC_DANDANAPI_* only")
    return problems


def starts_on_tag_or_release(text: str) -> bool:
    lines = text.splitlines()
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*)(?:on|\"on\"|'on'):\s*(.*)$", line)
        if not m:
            continue
        indent, inline = len(m.group(1)), m.group(2).split("#", 1)[0].strip()
        if inline:
            return bool(re.search(r"\b(?:push|release|create)\b", inline))
        block = []
        for l in lines[i + 1:]:
            if l.strip() and len(l) - len(l.lstrip()) <= indent:
                break
            block.append(l)
        body = [l for l in block if l.strip() and not l.strip().startswith("#")]
        if not body:
            return False
        top = min(len(l) - len(l.lstrip()) for l in body)
        events = {re.sub(r"^-\s*", "", l.strip()).split(":", 1)[0].strip()
                  for l in body if len(l) - len(l.lstrip()) == top}
        if events & {"release", "create"}:
            return True
        for j, l in enumerate(block):
            p = re.match(r"^(\s*)(?:-\s*)?push:\s*(.*)$", l)
            if not p or len(p.group(1)) != top:
                continue
            if p.group(2).split("#", 1)[0].strip():
                return True
            sub = []
            for s in block[j + 1:]:
                if s.strip() and len(s) - len(s.lstrip()) <= top:
                    break
                sub.append(s.strip())
            keys = {s.split(":", 1)[0] for s in sub if s and not s.startswith(("-", "#"))}
            # A push without filters also fires on tags; one with only branch
            # filters doesn't.
            return bool(keys & {"tags", "tags-ignore"}) or not (keys & {"branches", "branches-ignore"})
        return "push" in events
    return False


def check_tag_workflows() -> list[str]:
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    files = sorted(p.name for p in WORKFLOWS.glob("*.y*ml")
                   if p.name != PUBLIC_WORKFLOW
                   and starts_on_tag_or_release(p.read_text(encoding="utf-8")))
    if not token:
        print(f"  tag/release-triggered workflows ({', '.join(files) or 'none'}): state not checked "
              "(no GITHUB_TOKEN/GH_TOKEN)")
        return []
    repo = os.environ.get("GITHUB_REPOSITORY", "KaiC5504/Kazumi")
    problems = []
    for name in files:
        req = urllib.request.Request(
            f"https://api.github.com/repos/{repo}/actions/workflows/{name}",
            headers={"Authorization": f"Bearer {token}",
                     "Accept": "application/vnd.github+json"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                state = json.load(r).get("state")
        except OSError as e:
            problems.append(f"couldn't read the state of {name}: {e}")
            continue
        print(f"  {name}: {state}")
        if state != "disabled_manually":
            problems.append(f"{name} runs on tag pushes or releases and is {state}; "
                            f"gh workflow disable {name} -R {repo}")
    return problems


def check_scanner() -> list[str]:
    """A scanner that silently stopped matching would pass every build."""
    owner = b"https://hk.kaic5504.com/x"
    fork = b"https://github.com/KaiC5504/Kazumi"
    control = scanner.CONTROL.encode()
    problems = []
    with tempfile.TemporaryDirectory() as tmp:
        # A clean fixture only passes if its AOT binary was found, so the .ipa
        # pair also proves App.framework/App is recognised.
        apk_aot = "lib/arm64-v8a/libapp.so"
        ipa_aot = "Payload/Runner.app/Frameworks/App.framework/App"
        for name, aot, body, want_hits in (("dirty.apk", apk_aot, owner, 1),
                                           ("clean.apk", apk_aot, b"", 0),
                                           ("dirty.ipa", ipa_aot, owner, 1),
                                           ("clean.ipa", ipa_aot, b"", 0)):
            archive = Path(tmp) / name
            with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
                z.writestr(aot, b"\0".join([body, fork, control]))
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = scanner.main([str(archive)])
            hits = len(re.findall(r"^HIT ", out.getvalue(), re.M))
            if hits != want_hits or (code == 0) != (want_hits == 0):
                problems.append(f"scanner self-test ({name} fixture): exit {code}, {hits} "
                                f"hits; expected {want_hits}")
    if not problems:
        print("  scanner self-test: 1 hit in each dirty fixture, none in the clean ones (apk, ipa)")
    return problems


def check_packed_worker() -> list[str]:
    """The cloud worker ships gzipped and base64'd, which the binary scan
    can't read."""
    import pack_cloud_worker as worker
    data = worker.unpack(worker.TARGET.read_text(encoding="utf-8"))
    if data is None:
        return [f"couldn't unpack {worker.TARGET.relative_to(ROOT).as_posix()}"]
    if scanner.NEEDLE.encode() in data.lower():
        return [f"the packed cloud worker contains {scanner.NEEDLE}"]
    return []


def static_checks() -> list[str]:
    return (check_flag_reads() + check_personal_workflows() + check_public_workflow()
            + check_tag_workflows() + check_scanner() + check_packed_worker())


# ---------------------------------------------------------------- local


def git(*args: str, check: bool = True) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True,
                          check=check, encoding="utf-8").stdout


def changed_lib_files() -> list[str]:
    tracked = git("diff", "--name-only", "--no-renames", BASELINE, "--", "lib").split()
    untracked = git("ls-files", "--others", "--exclude-standard", "--", "lib").split()
    return sorted(set(tracked) | set(untracked))


def directives(text: str) -> list[str]:
    return [m.group(0).strip() for m in DIRECTIVE_RE.finditer(text)]


def resolve(source: str, uri: str) -> str | None:
    if uri.startswith("package:kazumi/"):
        return "lib/" + uri[len("package:kazumi/"):]
    if ":" in uri:
        return None
    parts = []
    for part in (PurePosixPath(source).parent / uri).parts:
        if part == "..":
            parts.pop()
        elif part != ".":
            parts.append(part)
    return "/".join(parts)


def her_closure() -> set[str]:
    todo = [p.relative_to(ROOT).as_posix() for p in (ROOT / "lib").rglob("*.dart")]
    todo = [p for p in todo if pc.frozen(p)]
    seen = set(todo)
    while todo:
        rel = todo.pop()
        if not (ROOT / rel).exists():
            continue
        for d in directives(read(rel)):
            for _, uri in URI_RE.findall(d):
                target = resolve(rel, uri)
                if target and target.endswith(".dart") and target not in seen:
                    seen.add(target)
                    todo.append(target)
    return seen


def loose_directives(text: str) -> Counter:
    out = Counter()
    for d in directives(text):
        uris = URI_RE.findall(d)
        if any(q == '"' or not re.match(r"^(package|dart):", u) for q, u in uris):
            out[re.sub(r"\s+", " ", d)] += 1
    return out


def check_new_relative_imports(files: list[str]) -> list[str]:
    problems = []
    for rel in files:
        if not rel.endswith(".dart") or not (ROOT / rel).exists():
            continue
        before = git("show", f"{BASELINE}:{rel}", check=False)
        added = loose_directives(read(rel)) - loose_directives(before)
        problems += [f"{rel}: new relative or double-quoted directive `{d}`" for d in added]
    return problems


def norm(line: str) -> str:
    return re.sub(r"\s+", "", line)


def hunks(rel: str) -> list[tuple[list[str], list[str]]]:
    out = git("diff", "--no-color", "-U0", BASELINE, "--", rel)
    result: list[tuple[list[str], list[str]]] = []
    for line in out.splitlines():
        if line.startswith("@@"):
            result.append(([], []))
        elif result and line[:1] in "+-" and not line.startswith(("+++", "---")):
            result[-1][line[0] == "+"].append(line[1:])
    return result


def literals(line: str) -> list[str]:
    return [] if line.strip().startswith("//") else LITERAL_RE.findall(line)


def code_only(lines: list[str]) -> tuple[str, str]:
    """[lines] joined with every comment blanked, plus a copy with string
    contents masked too, both at the same offsets."""
    text = "\n".join(lines)
    masked = LITERAL_RE.sub(lambda m: m[0][0] + "x" * (len(m[0]) - 2) + m[0][-1], text)
    for m in re.finditer(r"/\*.*?(?:\*/|$)|//[^\n]*", masked, re.S):
        blank = re.sub(r"[^\n]", " ", m[0])
        text = text[:m.start()] + blank + text[m.end():]
        masked = masked[:m.start()] + blank + masked[m.end():]
    return text, masked


def expression_end(masked: str, start: int) -> int:
    depth = 0
    for i in range(start, len(masked)):
        c = masked[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return i
            depth -= 1
        elif c in ",;" and depth == 0:
            return i
    return len(masked)


def branch_end(masked: str, start: int) -> int:
    """End of the `if` branch starting at [start]: a `{}` block, or up to a
    top-level `,`, `;`, `else` or closing bracket."""
    i = start
    while i < len(masked) and masked[i].isspace():
        i += 1
    depth = 0
    for j in range(i, len(masked)):
        c = masked[j]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return j
            depth -= 1
            if depth == 0 and c == "}" and masked[i] == "{":
                return j + 1
        elif depth == 0 and (c in ",;" or re.match(r"else\b", masked[j:])
                             and (j == 0 or not masked[j - 1].isalnum())):
            return j
    return len(masked)


def personal_side(added: list[str]) -> str:
    """The hunk's added code with the public branch of every
    `kPublicBuild ? a : b` and `if (kPublicBuild) a else b` cut out. A gated
    call (showCloudUi) has no branch to cut, so all of it counts."""
    text, masked = code_only(added)
    keep = [True] * len(text)
    for m in re.finditer(r"\bif\s*\(\s*(!?)\s*kPublicBuild\s*\)", masked):
        then_end = branch_end(masked, m.end())
        if not m[1]:
            cut = range(m.end(), then_end)
        else:
            other = re.match(r"\s*else\b", masked[then_end:])
            start = then_end + other.end() if other else then_end
            cut = range(start, branch_end(masked, start) if other else start)
        for i in cut:
            keep[i] = False
    for m in re.finditer(r"(!?)\bkPublicBuild\s*\?", masked):
        depth, colon = 0, None
        for i in range(m.end(), len(masked)):
            c = masked[i]
            if c in "([{":
                depth += 1
            elif c in ")]}":
                depth -= 1
                if depth < 0:
                    break
            elif c == ":" and depth == 0:
                colon = i
                break
        if colon is None:
            continue
        cut = (range(colon + 1, expression_end(masked, colon + 1)) if m[1]
               else range(m.end(), colon))
        for i in cut:
            keep[i] = False
    return "".join(c for c, k in zip(text, keep) if k)


def check_removed_lines(rel: str, before: Counter, now: Counter) -> list[str]:
    """Lines the fork took out of [rel] since the baseline must reappear in
    their hunk, or sit in a hunk that adds a gate in code. Behind a gate, their
    string literals must still be on the personal side, so a gate can't change
    a value her build uses. Upstream's own changes (merges) move neither
    fork-line set, so they don't count."""
    gone_added = {norm(l[1:]) for l, n in (before - now).items() if l.startswith("+")}
    new_deleted = {norm(l[1:]) for l, n in (now - before).items() if l.startswith("-")}
    ours = gone_added | new_deleted
    problems = []
    for removed, added in hunks(rel):
        back = {norm(l) for l in added}
        mine = [l for l in removed if norm(l) and norm(l) in ours]
        gone = [l for l in mine if norm(l) not in back]
        gated = any(g in code_only(added)[1] for g in GATES)
        if not gated:
            problems += [f"{rel}: removes `{l.strip()}` outside a public gate" for l in gone]
            continue
        personal = personal_side(added)
        # Back unchanged but moved into the public branch is still gone for her.
        for line in mine:
            if (norm(line) in back and not line.strip().startswith("//")
                    and norm(line) not in norm(personal)):
                problems.append(f"{rel}: `{line.strip()}` is now only in the public branch")
        for line in gone:
            for lit in literals(line):
                if lit not in personal:
                    problems.append(f"{rel}: {lit} from `{line.strip()}` is no longer on "
                                    "the personal side of its gate")
    return problems


def check_her_path(files: list[str]) -> tuple[list[str], set[str]]:
    closure = her_closure()
    before = pc.fork_lines(BASELINE)
    now = pc.fork_lines(None)
    problems = []
    tests = set()
    print("  changed files on her path:")
    for rel in files:
        if rel not in closure or pc.frozen(rel):
            continue
        zone = "tested edit" if rel in pc.TESTED_EDITS else "path-shadow"
        test = PERSONAL_TESTS.get(rel)
        print(f"    {rel} ({zone}) -> {test or 'NO PERSONAL TEST'}")
        if not test:
            problems.append(f"{rel} is on her path but has no personal test in PERSONAL_TESTS")
        else:
            tests.add(test)
        problems += check_removed_lines(rel, before.get(rel, Counter()), now.get(rel, Counter()))
    return problems, tests


def flutter() -> list[str]:
    return ["fvm", "flutter"] if shutil.which("fvm") else ["flutter"]


def test_events(args: list[str]) -> tuple[dict[str, set[str]], bool, int]:
    """Failed test names by suite, whether anything failed to load, and the
    test count."""
    cmd = [*flutter(), "test", "--reporter", "json", *args]
    print(f"\n$ {' '.join(cmd)}", flush=True)
    out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
                         shell=WIN).stdout
    suites: dict[int, str] = {}
    tests: dict[int, tuple[str, str]] = {}
    failed: dict[str, set[str]] = {}
    broken = False
    count = 0
    for line in out.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        kind = event.get("type")
        if kind == "suite":
            path = Path(event["suite"]["path"])
            suites[event["suite"]["id"]] = (path.relative_to(ROOT).as_posix()
                                            if path.is_absolute() else path.as_posix())
        elif kind == "testStart":
            t = event["test"]
            tests[t["id"]] = (suites.get(t.get("suiteID"), "?"), t["name"])
        elif kind == "testDone" and not event.get("hidden"):
            suite, name = tests.get(event["testID"], ("?", ""))
            if name and not name.startswith("loading "):
                count += 1
            if event.get("result") != "success":
                if name.startswith("loading ") or not name:
                    broken = True
                    print(f"  failed to load: {suite}")
                else:
                    failed.setdefault(suite, set()).add(name)
    return failed, broken, count


def public_sweep() -> bool:
    failed, broken, count = test_events(["test", *PUBLIC_DEFINES])
    ok = not broken and count > 0
    # Without these failures the defines didn't reach the tests at all.
    missing = pc.PUBLIC_MUST_FAIL - failed.get("test/partner_flow_test.dart", set())
    for name in sorted(missing):
        print(f"  DID NOT FAIL test/partner_flow_test.dart: {name}")
    ok &= not missing
    for suite in sorted(failed):
        allowed = suite in PUBLIC_FAIL_SUITES
        ok &= allowed
        for name in sorted(failed[suite]):
            print(f"  {'expected' if allowed else 'BROKE   '} {suite}: {name}")
    print(f"  {count} tests, {sum(map(len, failed.values()))} failed")
    return ok


def personal_tests(tests: set[str]) -> bool:
    if not tests:
        return True
    failed, broken, count = test_events(sorted(tests))
    for suite in sorted(failed):
        for name in sorted(failed[suite]):
            print(f"  FAILED {suite}: {name}")
    print(f"  {count} tests, {sum(map(len, failed.values()))} failed")
    return not broken and not failed and count > 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--static", action="store_true", help="text checks only (CI)")
    static_only = parser.parse_args().static

    results: dict[str, bool] = {}
    print("static checks:")
    problems = static_checks()
    for p in problems:
        print(f"  - {p}")
    results["static"] = not problems

    if not static_only:
        print("\nher path:")
        local = []
        if git("diff", "--name-only", BASELINE, "--", "analysis_options.yaml").strip():
            local.append(f"analysis_options.yaml differs from {BASELINE}")
        files = changed_lib_files()
        local += check_new_relative_imports(files)
        path_problems, tests = check_her_path(files)
        local += path_problems
        for p in local:
            print(f"  - {p}")
        results["her path"] = not local
        results["personal tests"] = personal_tests(tests)
        results["public sweep"] = public_sweep()

    ok = all(results.values())
    print()
    for name, passed in results.items():
        print(f"  {name}: {'pass' if passed else 'FAIL'}")
    print("public check:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

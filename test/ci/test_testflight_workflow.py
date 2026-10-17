"""Static checks on .github/workflows/testflight.yaml. The repo is public, so the
workflow's logs and artifacts are too; these keep the signing and dandanplay secrets
out of both, and keep a dry run from ever uploading."""

import base64
import os
import re
import subprocess
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/testflight.yaml"
PINNED = re.compile(r"^[\w.-]+/[\w.-]+@[0-9a-f]{40}$")
LOCKED_INSTALL = "pip install --quiet --require-hashes -r scripts/testflight-requirements.txt"
# Also catches secrets['X'], toJSON(secrets) and `secrets: inherit`.
SECRET_REF = re.compile(r"\bsecrets\b")
UNCONDITIONAL = re.compile(r"always\(\)|failure\(\)|cancelled\(\)")
TRACING = r"set -\w*x|-o xtrace|\bbash -\w*x"


def live(run: str) -> str:
    """The script without comment lines, with continuation lines joined."""
    code = "\n".join(l for l in run.splitlines() if not l.lstrip().startswith("#"))
    return re.sub(r"\\\n\s*", " ", code)


def runner_mask(text: str, masks: list[str]) -> str:
    """What the runner prints: every match of every mask, merged, becomes ***."""
    hidden = [False] * len(text)
    for mask in masks:
        at = text.find(mask)
        while at != -1:
            hidden[at:at + len(mask)] = [True] * len(mask)
            at = text.find(mask, at + 1)
    out, i = [], 0
    while i < len(text):
        if hidden[i]:
            out.append("***")
            while i < len(text) and hidden[i]:
                i += 1
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


class WorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")
        cls.doc = yaml.safe_load(cls.text)
        cls.jobs = cls.doc["jobs"]

    def steps(self, job=None):
        for job_name, spec in self.jobs.items():
            if job in (None, job_name):
                for step in spec.get("steps", []):
                    yield job_name, step

    def step(self, job, name):
        return next(s for _, s in self.steps(job) if s.get("name") == name)

    def test_only_started_by_hand(self):
        # PyYAML reads the bare key `on` as True.
        self.assertEqual({"workflow_dispatch"}, set(self.doc[True]))

    def test_uploading_must_be_asked_for(self):
        upload = self.doc[True]["workflow_dispatch"]["inputs"]["upload"]
        self.assertEqual((True, False), (upload["required"], upload["default"]))

    def test_token_is_read_only(self):
        self.assertEqual({"contents": "read"}, self.doc["permissions"])
        for name, job in self.jobs.items():
            self.assertNotIn("permissions", job, name)

    def test_actions_are_pinned_to_commits(self):
        for job, step in self.steps():
            if "uses" in step:
                self.assertRegex(step["uses"], PINNED, f"{job}: {step['uses']}")

    def test_no_shared_caches(self):
        # Enforced by the cache service for every step, not just flutter-action's.
        self.assertEqual("none", self.doc.get("cache-mode"))
        flutter = next(s for _, s in self.steps("build") if "flutter-action" in s.get("uses", ""))
        self.assertIs(False, flutter["with"]["cache"])
        self.assertRegex(str(flutter["with"]["flutter-version"]), r"^\d+\.\d+\.\d+$")
        self.assertNotIn("actions/cache", self.text)

    def test_cli_tools_come_from_the_hash_lock(self):
        self.assertIn(LOCKED_INSTALL, self.step("build", "Toolchain")["run"])
        self.assertIn(LOCKED_INSTALL, self.step("processed", "Install cli-tools")["run"])
        self.assertNotRegex(self.text, r"pip3? install [^\n]*codemagic-cli-tools")

    def test_cli_tools_never_caches_its_token_on_disk(self):
        self.assertEqual("1", str(self.doc["env"]["APP_STORE_CONNECT_DISABLE_JWT_CACHE"]))

    def test_secrets_only_reach_step_env_in_the_main_only_environment(self):
        self.assertNotRegex(yaml.safe_dump(self.doc.get("env", {})), SECRET_REF)
        for name, job in self.jobs.items():
            outside_steps = {k: v for k, v in job.items() if k != "steps"}
            self.assertNotRegex(yaml.safe_dump(outside_steps), SECRET_REF, name)
            if SECRET_REF.search(yaml.safe_dump(job)):
                self.assertEqual("testflight", job.get("environment"), name)
            for step in job.get("steps", []):
                label = f"{name}: {step.get('name', step.get('uses'))}"
                outside_env = {k: v for k, v in step.items() if k != "env"}
                self.assertNotRegex(yaml.safe_dump(outside_env), SECRET_REF, label)
                for value in step.get("env", {}).values():
                    if SECRET_REF.search(str(value)):
                        self.assertRegex(str(value), r"^\$\{\{ secrets\.[A-Z0-9_]+ \}\}$", label)

    def test_secrets_never_reach_github_env_or_outputs(self):
        secret_vars = {k for _, s in self.steps() for k, v in s.get("env", {}).items()
                       if SECRET_REF.search(str(v))}
        for job, step in self.steps():
            for line in step.get("run", "").splitlines():
                if re.search(r"GITHUB_(ENV|OUTPUT|PATH|STEP_SUMMARY)", line):
                    for var in secret_vars:
                        self.assertNotRegex(line, rf"\b{var}\b", f"{job}: {step.get('name')}")

    def test_builds_only_main(self):
        self.assertEqual("github.ref == 'refs/heads/main'", self.jobs["build"]["if"])
        self.assertEqual(["build"], [self.jobs[j].get("needs") for j in self.jobs
                                     if j != "build"])

    def test_first_step_pins_the_checked_commit(self):
        first = self.jobs["build"]["steps"][0]
        self.assertEqual("${{ inputs.sha }}", first["env"]["WANT"])
        self.assertIn('"$WANT" != "$GITHUB_SHA"', first["run"])

    def test_inputs_never_reach_a_shell_unquoted(self):
        for job, step in self.steps():
            self.assertNotIn("${{", step.get("run", ""), f"{job}: {step.get('name')}")

    def test_checkout_never_keeps_the_token(self):
        checkouts = [s for _, s in self.steps() if "actions/checkout" in s.get("uses", "")]
        self.assertTrue(checkouts)
        for step in checkouts:
            self.assertIs(False, step.get("with", {}).get("persist-credentials"))

    def test_only_the_manifest_is_uploaded(self):
        uploads = [s for _, s in self.steps() if "upload-artifact" in s.get("uses", "")]
        self.assertEqual(1, len(uploads))
        self.assertEqual("${{ runner.temp }}/testflight-build.json", uploads[0]["with"]["path"])
        self.assertIs(True, uploads[0]["with"]["overwrite"])

    def test_no_shell_tracing_or_verbose_flutter(self):
        for job, step in self.steps():
            label = f"{job}: {step.get('name')}"
            # Continuation lines joined, so a flag on the next line still counts.
            run = live(step.get("run", ""))
            self.assertNotRegex(run, TRACING, label)
            self.assertNotRegex(str(step.get("shell", "")), TRACING + r"|-\w*x\b", label)
            # --wrap splits long lines, and a mask only matches within one line.
            self.assertNotRegex(run, r"\bflutter\b[^\n]*(\s-v\b|--verbose|--wrap)", label)
            self.assertNotRegex(run, r"Generated\.xcconfig|flutter_export_environment", label)
            self.assertNotRegex(run, r"(?m)(^|[;&|(]\s*)(env|printenv|set|export -p|declare -x)\s*($|[|>;&)])",
                                label)
        for scope in (self.doc, *self.jobs.values()):
            shell = str(scope.get("defaults", {}).get("run", {}).get("shell", ""))
            self.assertNotRegex(shell, TRACING + r"|-\w*x\b")

    def test_nothing_can_wave_a_failed_check_through(self):
        for name, job in self.jobs.items():
            self.assertNotIn("continue-on-error", job, name)
            self.assertNotRegex(str(job.get("if", "")), UNCONDITIONAL, name)
            for step in job.get("steps", []):
                self.assertNotIn("continue-on-error", step, f"{name}: {step.get('name')}")
        self.assertNotIn("if", self.step("build", "Check the IPA"))

    def test_signing_never_changes_the_account(self):
        # Comments may mention --create; only the commands count.
        signing = live(self.step("build", "Create signing files")["run"])
        self.assertIn("fetch-signing-files", signing)
        self.assertNotIn("--create", signing)

    def test_signing_leaves_nothing_readable_behind(self):
        sign = live(self.step("build", "Create signing files")["run"])
        self.assertIn("umask 077", sign)
        self.assertIn("trap 'rm -f \"$key\"' EXIT", sign)
        self.assertRegex(sign, r"keychain initialize --password @env:\w+")
        self.assertNotIn('-k ""', sign)
        for folder in ("Library/Developer/Xcode/UserData/Certificates", "Library/MobileDevice/Certificates"):
            self.assertIn(f'"$HOME/{folder}/"*.p12', sign)
        self.assertIn('echo "::add-mask::$line"', sign)

    def test_masks_hide_the_defines_wherever_xcode_prints_them(self):
        names = [s.get("name") for _, s in self.steps("build")]
        self.assertLess(names.index("Mask encoded dandanplay values"), names.index("Make the project ours"))
        run = self.step("build", "Mask encoded dandanplay values")["run"]
        program = run.split("<<'EOF'\n", 1)[1].rsplit("\nEOF", 1)[0]
        # Lengths 6-8 cover every padding case of both prefixes.
        for appid, key in (("a1b2c3", "k3y+/9"), ("a1b2c3d", "k3y+/9z"), ("a1b2c3d4", "k3y+/9zz")):
            env = {**os.environ, "DANDANAPI_APPID": appid, "DANDANAPI_KEY": key}
            out = subprocess.run([sys.executable, "-I", "-"], input=program, env=env,
                                 capture_output=True, text=True, check=True).stdout
            lines = out.splitlines()
            self.assertTrue(lines and all(l.startswith("::add-mask::") for l in lines))
            masks = [l.removeprefix("::add-mask::") for l in lines]
            for name, value in (("DANDANAPI_APPID", appid), ("DANDANAPI_KEY", key)):
                encoded = base64.b64encode(f"{name}={value}".encode()).decode()
                # As Flutter writes it, as Xcode's `export DART_DEFINES\=...` prints it,
                # and inside the comma-joined list.
                for printed, expected in ((encoded, "***"),
                                          (encoded.replace("=", "\\="), "***"),
                                          (f"x,{encoded},y", "x,***,y")):
                    self.assertEqual(expected, runner_mask(printed, masks), printed)
                # Elsewhere, at any byte offset, at most the first two bytes show.
                for prefix in ("", "a", "ab"):
                    other = base64.b64encode(f"{prefix}{value}".encode()).decode()
                    shown = runner_mask(other, masks)
                    self.assertLessEqual(len(shown.partition("***")[0]), 4, other)
                    self.assertRegex(shown, r"\*\*\*$", other)

    def test_xcode_is_the_exact_build(self):
        self.assertIn('grep -q "Build version $XCODE_BUILD"', self.step("build", "Toolchain")["run"])

    def test_her_build_flags(self):
        self.assertIn('--build-number="$BUILD_NUMBER"', self.text)
        self.assertNotIn("KAZUMI_PUBLIC", self.text)
        self.assertNotIn("KAZUMI_LIBRARY_SERVER", self.text)
        self.assertNotIn("dart-define-from-file", self.text)

    def test_build_numbers_keep_rising(self):
        # Installed apps compare build numbers only; Codemagic shipped up to 32.
        self.assertGreaterEqual(int(self.doc["env"]["BUILD_NUMBER_FLOOR"]), 32)
        step = self.step("build", "Pick the build number")
        self.assertIn('get-latest-testflight-build-number "$ASC_APP_ID" --all-versions', step["run"])
        self.assertIn("''|*[!0-9]*)", step["run"])
        self.assertIn('echo "BUILD_NUMBER=$next" >> "$GITHUB_ENV"', step["run"])

    def test_processing_waits_for_the_right_build(self):
        wait = self.step("processed", "Wait for Apple to finish processing")
        self.assertEqual("${{ inputs.upload }}", wait["env"]["UPLOAD"])
        self.assertEqual("${{ needs.build.outputs.build_number }}", wait["env"]["BUILT"])
        # An upload whose number went missing must fail, not poll the old floor build.
        self.assertIn('if [ "$UPLOAD" = true ]; then build="$BUILT"', wait["run"])
        self.assertIn("''|*[!0-9]*)", wait["run"])
        # A failed check is retried a few times, then fails the step with its error, never loops for the hour.
        self.assertIn('state="no answer', wait["run"])
        self.assertIn('if [ "$misses" -ge 8 ]', wait["run"])
        # macOS runners have no GNU timeout: every check failed on it until 2026-10-18.
        self.assertNotRegex(wait["run"], r"(^|[\s(])timeout ")

    def test_ipa_is_checked_before_it_is_uploaded(self):
        names = [s.get("name") for _, s in self.steps("build")]
        self.assertLess(names.index("Check the IPA"), names.index("Upload to TestFlight"))
        self.assertEqual("inputs.upload", self.step("build", "Upload to TestFlight")["if"])


class OtherWorkflowsTest(unittest.TestCase):
    def test_only_this_workflow_uses_an_environment(self):
        # Environment secrets reach any job on main that names the environment,
        # whatever its trigger (issues, watch, pull_request_target, push...), and
        # upstream merges add and change workflows.
        for path in sorted(WORKFLOW.parent.glob("*.y*ml")):
            if path.name == WORKFLOW.name:
                continue
            doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
            for name, job in (doc.get("jobs") or {}).items():
                self.assertNotIn("environment", job, f"{path.name}: {name}")


if __name__ == "__main__":
    unittest.main()

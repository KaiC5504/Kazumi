"""partner_check's guards on the TestFlight build, run against copies of the real files."""

import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import partner_check as pc  # noqa: E402

WORKFLOW, CODEMAGIC = pc.BUILD_CONFIGS
WORKFLOWS = ".github/workflows"


class GuardCase(unittest.TestCase):
    def copy_of_repo(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        for name in (*pc.BUILD_CONFIGS, "pubspec.yaml"):
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / name, root / name)
        for workflow in (ROOT / WORKFLOWS).glob("*.y*ml"):
            shutil.copy(workflow, root / WORKFLOWS / workflow.name)
        return root

    def guard(self, guard, edit=None):
        root = self.copy_of_repo()
        if edit:
            edit(root)
        with mock.patch.object(pc, "ROOT", root):
            return guard()

    @staticmethod
    def rewrite(name, pattern, replacement):
        def edit(root):
            path = root / name
            text = path.read_text(encoding="utf-8")
            changed = re.sub(pattern, replacement, text, count=1, flags=re.M)
            assert changed != text, f"{pattern!r} not found in {name}"
            path.write_text(changed, encoding="utf-8")
        return edit

    def assertProblem(self, text, problems):
        self.assertTrue(any(text in p for p in problems), problems)


class BuildConfigGuardTest(GuardCase):
    def problems(self, edit=None):
        return self.guard(pc.guard_builds, edit)

    def test_the_real_configs_agree(self):
        self.assertEqual([], self.problems())

    def test_version_drift(self):
        self.assertProblem("version", self.problems(
            self.rewrite(CODEMAGIC, r"--build-name=\S+", "--build-name=9.9.9")))

    def test_upstream_flutter_bump_needs_both_configs(self):
        self.assertProblem("pubspec.yaml pins", self.problems(
            self.rewrite("pubspec.yaml", r"^  flutter: \S+", "  flutter: 9.9.9")))

    def test_configs_on_different_flutter(self):
        self.assertProblem("Flutter", self.problems(
            self.rewrite(WORKFLOW, r"flutter-version: \S+", "flutter-version: 9.9.9")))

    def test_configs_on_different_xcode(self):
        self.assertProblem("Xcode", self.problems(
            self.rewrite(CODEMAGIC, r"xcode: \S+", "xcode: latest")))

    def test_a_dropped_dart_define(self):
        self.assertProblem("dart-defines", self.problems(
            self.rewrite(WORKFLOW, r"\n.*--dart-define=DANDANAPI_KEY=.*", "")))

    def test_a_changed_purpose_string(self):
        self.assertProblem("Info.plist", self.problems(self.rewrite(
            WORKFLOW, r"(set_key NSCameraUsageDescription string )\"[^\"]*\"", r'\1"changed"')))

    def test_public_flag(self):
        self.assertProblem("KAZUMI_PUBLIC", self.problems(self.rewrite(
            WORKFLOW, r"--release \\$", r"--release --dart-define=KAZUMI_PUBLIC=true \\")))

    def test_lost_build_number(self):
        self.assertProblem("--build-number", self.problems(
            self.rewrite(WORKFLOW, r'--build-number="\$BUILD_NUMBER"', "--build-number=1")))

    def test_missing_workflow(self):
        self.assertProblem("missing", self.problems(lambda root: (root / WORKFLOW).unlink()))

    def test_codemagic_can_be_retired(self):
        self.assertEqual([], self.problems(lambda root: (root / CODEMAGIC).unlink()))


class UploaderGuardTest(GuardCase):
    def problems(self, edit=None):
        return self.guard(pc.guard_uploaders, edit)

    @staticmethod
    def add_workflow(text):
        def edit(root):
            (root / WORKFLOWS / "other.yml").write_text(text, encoding="utf-8")
        return edit

    def test_the_real_workflows_pass(self):
        self.assertEqual([], self.problems())

    def test_another_workflow_using_the_environment(self):
        self.assertProblem("other.yml", self.problems(self.add_workflow(
            "jobs:\n  x:\n    environment: testflight\n    runs-on: ubuntu-latest\n")))

    def test_the_block_form_of_the_environment(self):
        self.assertProblem("other.yml", self.problems(self.add_workflow(
            "jobs:\n  x:\n    environment:\n      name: testflight\n")))

    def test_another_workflow_uploading(self):
        self.assertProblem("other.yml", self.problems(self.add_workflow(
            "jobs:\n  x:\n    steps:\n      - run: app-store-connect publish --path a.ipa\n")))

    def test_another_workflow_reading_the_secrets(self):
        self.assertProblem("other.yml", self.problems(self.add_workflow(
            "env:\n  K: ${{ secrets.CERT_KEY_B64 }}\n")))

    def test_every_spelling_of_the_environment(self):
        # Names are case-insensitive and can come from expressions or anchors.
        for job in ("environment: TestFlight", "environment: ${{ 'testflight' }}",
                    "environment: *env", "environment : testflight", "'environment': testflight",
                    "environment: ${{ format('{0}flight', 'test') }}"):
            with self.subTest(job=job):
                self.assertProblem("other.yml", self.problems(self.add_workflow(
                    f"jobs:\n  x:\n    {job}\n    runs-on: ubuntu-latest\n")))

    def test_every_way_to_read_the_secrets(self):
        for ref in ("${{ secrets['CERT_KEY_B64'] }}", "${{ toJSON(secrets) }}",
                    "${{ secrets.TESTFLIGHT_DANDANAPI_KEY }}"):
            with self.subTest(ref=ref):
                self.assertProblem("other.yml", self.problems(self.add_workflow(
                    f"env:\n  K: {ref}\n")))

    def test_a_comment_is_not_a_reach(self):
        self.assertEqual([], self.problems(self.add_workflow(
            "# Build environment: macOS, no app-store-connect here\njobs: {}\n")))


if __name__ == "__main__":
    unittest.main()

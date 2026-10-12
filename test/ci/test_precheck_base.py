"""precheck's diff base: the last build that shipped, never a silent fallback."""

import io
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import codemagic  # noqa: E402
import precheck  # noqa: E402
import testflight  # noqa: E402

GITHUB_SHA = "a" * 40
CODEMAGIC_SHA = "b" * 40
CODEMAGIC_BUILDS = [
    {"status": "failed", "index": 33, "commit": {"hash": "c" * 40}},
    {"status": "finished", "index": 32, "commit": {"hash": CODEMAGIC_SHA}},
]


def offline(*_):
    raise SystemExit("offline")


class BaseTest(unittest.TestCase):
    def base(self, shipped=None, github=None, codemagic_call=None):
        github = github or (lambda: shipped)
        codemagic_call = codemagic_call or (lambda path: {"builds": CODEMAGIC_BUILDS})
        with mock.patch.object(testflight, "last_shipped", github), \
                mock.patch.object(codemagic, "call", codemagic_call), \
                mock.patch.object(codemagic, "app_id", lambda: "app"), \
                redirect_stdout(io.StringIO()):
            return precheck.last_passed_build()

    def test_last_github_upload_comes_first(self):
        self.assertEqual(GITHUB_SHA, self.base({"databaseId": 1, "headSha": GITHUB_SHA}))

    def test_codemagic_until_github_has_shipped(self):
        self.assertEqual(CODEMAGIC_SHA, self.base(None))

    def test_github_down_falls_back_to_codemagic(self):
        self.assertEqual(CODEMAGIC_SHA, self.base(github=offline))

    def test_nothing_reachable_gives_no_base(self):
        self.assertIsNone(self.base(github=offline, codemagic_call=offline))

    def test_no_base_fails_instead_of_testing_nothing(self):
        # Everything slow is stubbed so the old code fails fast instead of analyzing.
        with mock.patch.object(precheck, "last_passed_build", return_value=None), \
                mock.patch.object(sys, "argv", ["precheck.py"]), \
                mock.patch.object(precheck, "changed_files", return_value=[]) as changed, \
                mock.patch.object(precheck, "check_assets", return_value=[]), \
                mock.patch.object(precheck, "flutter", return_value=True), \
                mock.patch.object(precheck.subprocess, "run",
                                  return_value=mock.Mock(returncode=0)), \
                redirect_stdout(io.StringIO()) as out:
            self.assertEqual(1, precheck.main())
        changed.assert_not_called()
        self.assertIn("--base", out.getvalue())

    def test_pipeline_changes_ask_for_a_dry_run_not_ios_check(self):
        changed = [".github/workflows/testflight.yaml", "codemagic.yaml", "scripts/testflight.py"]
        with mock.patch.object(sys, "argv", ["precheck.py", "--base", "HEAD"]), \
                mock.patch.object(precheck, "changed_files", return_value=changed), \
                mock.patch.object(precheck, "check_assets", return_value=[]), \
                mock.patch.object(precheck, "flutter", return_value=True), \
                mock.patch.object(precheck.subprocess, "run",
                                  return_value=mock.Mock(returncode=0)) as run, \
                redirect_stdout(io.StringIO()) as out:
            self.assertEqual(0, precheck.main())
        self.assertIn("--dry-run", out.getvalue())
        self.assertTrue(any("test/ci" in call.args[0] for call in run.call_args_list))


if __name__ == "__main__":
    unittest.main()

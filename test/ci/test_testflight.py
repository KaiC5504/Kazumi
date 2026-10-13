import io
import json
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import testflight as tf  # noqa: E402

SHA = "a" * 40
OLD = "b" * 40
ENV_LOCKED = {"deployment_branch_policy": {"protected_branches": False,
                                           "custom_branch_policies": True}}


def gh_run(run_id, title, conclusion="success", status="completed", sha=SHA, branch="main",
           event="workflow_dispatch"):
    return {"databaseId": run_id, "displayTitle": title, "status": status,
            "conclusion": conclusion, "headSha": sha, "headBranch": branch, "event": event,
            "url": f"https://github.com/{tf.REPO}/actions/runs/{run_id}"}


class FakeShell:
    """Answers the git and gh calls testflight.py makes."""

    def __init__(self, runs=(), behind=0, manifest=None, after_dispatch=None, print_url=True,
                 environment=ENV_LOCKED, branches=("main",), secrets=tuple(tf.SECRETS),
                 head=SHA, views=None):
        self.runs = list(runs)
        self.behind = behind
        self.manifest = manifest
        self.after_dispatch = after_dispatch
        self.print_url = print_url
        self.environment = environment
        self.branches = branches
        self.secrets = secrets
        self.head = head
        self.views = list(views or [])
        self.calls = []

    def __call__(self, *args):
        self.calls.append(args)
        if args[:2] == ("git", "fetch"):
            return ""
        if args[:2] == ("git", "rev-list"):
            return f"{self.behind}\n"
        if args[:2] == ("git", "rev-parse"):
            return (self.head if args[2] == "HEAD" else SHA) + "\n"
        if args[:2] == ("gh", "api"):
            if args[2].endswith("/deployment-branch-policies"):
                return json.dumps({"branch_policies": [{"name": b} for b in self.branches]})
            return json.dumps(self.environment)
        if args[:3] == ("gh", "secret", "list"):
            return json.dumps([{"name": s} for s in self.secrets])
        if args[:3] == ("gh", "run", "list"):
            return json.dumps(self.runs)
        if args[:3] == ("gh", "workflow", "run"):
            if self.after_dispatch:
                self.runs.insert(0, self.after_dispatch)
                if self.print_url:
                    return f"Created workflow_dispatch event\n{self.after_dispatch['url']}\n"
            return ""
        if args[:3] == ("gh", "run", "view"):
            if self.views:
                result = self.views.pop(0)
                if isinstance(result, BaseException):
                    raise result
                return json.dumps(result)
            run_id = int(args[3])
            return json.dumps(next(r for r in self.runs if r["databaseId"] == run_id))
        if args[:3] == ("gh", "run", "cancel"):
            return ""
        if args[:3] == ("gh", "run", "download"):
            folder = Path(args[args.index("-D") + 1])
            (folder / tf.MANIFEST).write_text(json.dumps(self.manifest), encoding="utf-8")
            return ""
        raise AssertionError(f"unexpected call {args}")


def call(fn, *args):
    out = io.StringIO()
    with redirect_stdout(out):
        code = fn(*args)
    return code, out.getvalue()


class ShippedTest(unittest.TestCase):
    def shipped(self, runs):
        with mock.patch.object(tf, "run", FakeShell(runs)):
            return tf.last_shipped()

    def test_ignores_a_fork_pr_running_its_own_copy(self):
        # A fork's PR branch is usually called main too, and the PR picks the
        # workflow file, run name and artifact.
        got = self.shipped([
            gh_run(9, f"{tf.UPLOAD} {SHA}", event="pull_request"),
            gh_run(3, f"{tf.UPLOAD} {OLD}", sha=OLD),
        ])
        self.assertEqual(3, got["databaseId"])

    def test_skips_dry_runs_and_failures(self):
        got = self.shipped([
            gh_run(5, f"{tf.UPLOAD} {SHA}", conclusion="failure"),
            gh_run(4, f"{tf.DRY_RUN} {SHA}"),
            gh_run(3, f"{tf.UPLOAD} {OLD}", sha=OLD),
        ])
        self.assertEqual(3, got["databaseId"])

    def test_ignores_runs_from_other_branches(self):
        got = self.shipped([gh_run(5, f"{tf.UPLOAD} {SHA}", branch="ci/x"),
                            gh_run(3, f"{tf.UPLOAD} {OLD}", sha=OLD)])
        self.assertEqual(3, got["databaseId"])

    def test_none_before_the_first_upload(self):
        self.assertIsNone(self.shipped([gh_run(1, f"{tf.DRY_RUN} {SHA}")]))


class StartTest(unittest.TestCase):
    def start(self, shell, *argv, passed=True):
        with mock.patch.object(tf, "run", shell), mock.patch.object(tf.time, "sleep"), \
                mock.patch.object(tf.codemagic, "partner_check_passed", return_value=passed):
            return call(tf.cmd_start, list(argv))

    def dispatches(self, shell):
        return [c for c in shell.calls if c[:3] == ("gh", "workflow", "run")]

    def queued(self, title, run_id=9):
        return gh_run(run_id, f"{title} {SHA}", None, "queued")

    def test_dispatches_the_checked_commit(self):
        shell = FakeShell(after_dispatch=self.queued(tf.UPLOAD))
        code, out = self.start(shell)
        self.assertEqual(0, code)
        (dispatch,) = self.dispatches(shell)
        self.assertIn(f"sha={SHA}", dispatch)
        self.assertIn("upload=true", dispatch)
        self.assertEqual("main", dispatch[dispatch.index("--ref") + 1])
        self.assertIn("started run 9", out)

    def test_finds_the_run_without_a_printed_url(self):
        shell = FakeShell(after_dispatch=self.queued(tf.UPLOAD), print_url=False)
        code, out = self.start(shell)
        self.assertEqual(0, code)
        self.assertIn("started run 9", out)

    def test_dry_run_uploads_nothing(self):
        shell = FakeShell(after_dispatch=self.queued(tf.DRY_RUN))
        self.start(shell, "--dry-run")
        self.assertIn("upload=false", self.dispatches(shell)[0])

    def test_waits_for_the_run_name_before_judging_the_mode(self):
        # Right after a dispatch GitHub shows the workflow's bare name as the title.
        run_ = self.queued(tf.DRY_RUN)
        shell = FakeShell(after_dispatch=run_,
                          views=[{**run_, "displayTitle": "TestFlight"}, run_])
        code, out = self.start(shell, "--dry-run")
        self.assertEqual(0, code, out)
        self.assertNotIn(("gh", "run", "cancel", "9", "-R", tf.REPO), shell.calls)
        self.assertIn("started run 9", out)

    def test_cancels_a_run_in_the_wrong_mode(self):
        shell = FakeShell(after_dispatch=self.queued(tf.UPLOAD))
        code, out = self.start(shell, "--dry-run")
        self.assertEqual(1, code)
        self.assertIn(("gh", "run", "cancel", "9", "-R", tf.REPO), shell.calls)
        self.assertIn("cancelled", out)

    def test_refuses_without_the_partner_check(self):
        shell = FakeShell()
        code, out = self.start(shell, passed=False)
        self.assertEqual((1, []), (code, self.dispatches(shell)))
        self.assertIn("partner_check", out)

    def test_refuses_when_behind_upstream(self):
        shell = FakeShell(behind=3)
        code, out = self.start(shell)
        self.assertEqual((1, []), (code, self.dispatches(shell)))
        self.assertIn("behind upstream", out)

    def test_refuses_while_a_run_is_in_flight(self):
        shell = FakeShell([gh_run(8, f"{tf.UPLOAD} {OLD}", None, "in_progress", OLD)])
        code, _ = self.start(shell)
        self.assertEqual((1, []), (code, self.dispatches(shell)))

    def test_refuses_an_environment_open_to_any_branch(self):
        shell = FakeShell(environment={"deployment_branch_policy": None})
        code, out = self.start(shell)
        self.assertEqual((1, []), (code, self.dispatches(shell)))
        self.assertIn("isn't limited", out)

    def test_refuses_an_environment_open_to_other_branches(self):
        shell = FakeShell(branches=("main", "ci/*"))
        code, out = self.start(shell)
        self.assertEqual((1, []), (code, self.dispatches(shell)))
        self.assertIn("not just main", out)

    def test_refuses_a_missing_secret(self):
        shell = FakeShell(secrets=sorted(tf.SECRETS - {"CERT_KEY_B64"}))
        code, out = self.start(shell)
        self.assertEqual((1, []), (code, self.dispatches(shell)))
        self.assertIn("CERT_KEY_B64", out)

    def test_refuses_to_reship_unless_asked(self):
        shell = FakeShell([gh_run(7, f"{tf.UPLOAD} {SHA}")])
        code, out = self.start(shell)
        self.assertEqual((1, []), (code, self.dispatches(shell)))
        self.assertIn("--again", out)
        shell = FakeShell([gh_run(7, f"{tf.UPLOAD} {SHA}")], after_dispatch=self.queued(tf.UPLOAD))
        self.assertEqual(0, self.start(shell, "--again")[0])

    def test_dry_run_of_a_shipped_commit_is_fine(self):
        shell = FakeShell([gh_run(7, f"{tf.UPLOAD} {SHA}")], after_dispatch=self.queued(tf.DRY_RUN))
        self.assertEqual(0, self.start(shell, "--dry-run")[0])

    def test_says_when_the_checkout_isnt_main(self):
        shell = FakeShell(after_dispatch=self.queued(tf.UPLOAD), head=OLD)
        _, out = self.start(shell)
        self.assertIn(f"this checkout is at {OLD[:8]}", out)


class WatchTest(unittest.TestCase):
    def watch(self, views):
        done = gh_run(9, f"{tf.UPLOAD} {SHA}")
        shell = FakeShell([done], views=views)
        with mock.patch.object(tf, "run", shell), mock.patch.object(tf.time, "sleep"), \
                mock.patch.object(tf, "report"):
            return call(tf.cmd_watch, "9")

    def test_survives_a_network_blip(self):
        blip = SystemExit("gh run view failed: connection reset")
        code, _ = self.watch([gh_run(9, "t", None, "in_progress"), blip, blip,
                              gh_run(9, "t", "success")])
        self.assertEqual(0, code)

    def test_gives_up_after_repeated_failures(self):
        blip = SystemExit("gh run view failed: offline")
        code, out = self.watch([blip] * tf.WATCH_RETRIES)
        self.assertEqual(3, code)
        self.assertIn("Lost contact", out)

    def test_cancelled_is_a_failure(self):
        self.assertEqual(1, self.watch([gh_run(9, "t", "cancelled")])[0])


class StatusTest(unittest.TestCase):
    def test_timed_out_counts_as_failed(self):
        shell = FakeShell([gh_run(9, f"{tf.UPLOAD} {SHA}", "timed_out")])
        with mock.patch.object(tf, "run", shell), mock.patch.object(tf, "report"):
            self.assertEqual(1, call(tf.cmd_status)[0])


class PublishTest(unittest.TestCase):
    MANIFEST = {"sha": SHA, "version": "3.1.0", "build": "33"}

    def publish(self, shell, hk=None, argv=("--notes", "构建流程更新")):
        writes = []

        def ssh(command, stdin=None):
            if stdin is not None:
                writes.append(json.loads(stdin))
            return json.dumps(hk) if hk else ""

        with mock.patch.object(tf, "run", shell), mock.patch.object(tf.codemagic, "ssh", ssh):
            code, out = call(tf.cmd_publish_latest, list(argv))
        return code, out, writes

    def test_announces_the_uploaded_build(self):
        shell = FakeShell([gh_run(7, f"{tf.UPLOAD} {SHA}")], manifest=self.MANIFEST)
        code, _, writes = self.publish(shell, hk={"build": 32, "minBuild": 0})
        self.assertEqual(0, code)
        self.assertEqual((33, "3.1.0", "构建流程更新", 0),
                         (writes[0]["build"], writes[0]["version"], writes[0]["notes"],
                          writes[0]["minBuild"]))

    def test_required_raises_min_build(self):
        shell = FakeShell([gh_run(7, f"{tf.UPLOAD} {SHA}")], manifest=self.MANIFEST)
        _, _, writes = self.publish(shell, argv=("--required",))
        self.assertEqual(33, writes[0]["minBuild"])
        self.assertIsNotNone(writes[0]["requiredSince"])

    def test_refuses_while_the_newest_upload_is_unfinished(self):
        shell = FakeShell([gh_run(8, f"{tf.UPLOAD} {SHA}", None, "in_progress"),
                           gh_run(7, f"{tf.UPLOAD} {OLD}", sha=OLD)])
        with self.assertRaises(SystemExit):
            self.publish(shell)

    def test_ignores_dry_runs_and_other_branches(self):
        shell = FakeShell([gh_run(9, f"{tf.UPLOAD} {OLD}", sha=OLD, branch="ci/x"),
                           gh_run(8, f"{tf.DRY_RUN} {SHA}"),
                           gh_run(7, f"{tf.UPLOAD} {SHA}")], manifest=self.MANIFEST)
        code, _, writes = self.publish(shell)
        self.assertEqual((0, 33), (code, writes[0]["build"]))

    def test_refuses_a_manifest_from_another_commit(self):
        shell = FakeShell([gh_run(7, f"{tf.UPLOAD} {SHA}")], manifest={**self.MANIFEST, "sha": OLD})
        with self.assertRaises(SystemExit):
            self.publish(shell)

    def test_refuses_a_build_without_a_version(self):
        shell = FakeShell([gh_run(7, f"{tf.UPLOAD} {SHA}")], manifest={**self.MANIFEST, "version": ""})
        with self.assertRaises(SystemExit):
            self.publish(shell)

    def test_never_announces_an_older_build(self):
        shell = FakeShell([gh_run(7, f"{tf.UPLOAD} {SHA}")], manifest={**self.MANIFEST, "build": "31"})
        with self.assertRaises(SystemExit):
            self.publish(shell, hk={"build": 32})


class CodemagicPublishTest(unittest.TestCase):
    def setUp(self):
        self.writes = []

    def publish(self, ipa):
        def ssh(command, stdin=None):
            if stdin is not None:
                self.writes.append(json.loads(stdin))
            return ""

        build = {"status": "finished", "artefacts": [{"type": "ipa", **ipa}]}
        with mock.patch.object(tf.codemagic, "latest", return_value=build), \
                mock.patch.object(tf.codemagic, "ssh", ssh):
            return call(tf.codemagic.cmd_publish_latest, [])[0]

    def test_announces_the_build(self):
        self.assertEqual(0, self.publish({"versionCode": "33", "versionName": "3.2.0"}))
        self.assertEqual((33, "3.2.0"), (self.writes[0]["build"], self.writes[0]["version"]))

    def test_refuses_an_ipa_without_a_version(self):
        # The app ignores a latest.json whose version is null.
        with self.assertRaises(SystemExit):
            self.publish({"versionCode": "33"})
        self.assertEqual([], self.writes)


if __name__ == "__main__":
    unittest.main()

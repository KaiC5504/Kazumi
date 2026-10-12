import base64
import json
import os
import plistlib
import shutil
import struct
import sys
import tempfile
import unittest
import zipfile
from datetime import datetime
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import ipa_manifest as m  # noqa: E402

BUNDLE = "com.example.app"
APP_ID = "fake-app-id"
APP_SECRET = "FAKE-SECRET-VALUE"
NEEDLES = {"DANDANAPI_APPID": APP_ID, "DANDANAPI_KEY": APP_SECRET}


def fake_ipa(folder: str, *, build="33", get_task_allow=False, devices=False,
             beta_reports=True, snapshot=None, drop=(), plist=None) -> str:
    info = {
        "CFBundleIdentifier": BUNDLE,
        "CFBundleExecutable": "Runner",
        "CFBundleShortVersionString": "3.1.0",
        "CFBundleVersion": build,
        "ITSAppUsesNonExemptEncryption": False,
        "DTXcode": "2660",
        "DTXcodeBuild": "17F113",
        "BuildMachineOSBuild": "25G83",
        **m.PURPOSE_STRINGS,
        **(plist or {}),
    }
    for key in drop:
        info.pop(key)
    entitlements = {
        "application-identifier": f"TEAMID1234.{BUNDLE}",
        "com.apple.developer.team-identifier": "TEAMID1234",
        "get-task-allow": get_task_allow,
        "keychain-access-groups": ["TEAMID1234.*"],
    }
    if beta_reports:
        entitlements["beta-reports-active"] = True
    xml = plistlib.dumps(entitlements)
    binary = (b"\xcf\xfa\xed\xfe" + b"\x00" * 64
              + b"\xfa\xde\x71\x71" + b"junk"  # a stray magic before the real blob
              + b"\xfa\xde\x71\x71" + struct.pack(">I", len(xml) + 8) + xml + b"\x00" * 16)
    profile = {
        "Name": f"{BUNDLE} app_store 1",
        "UUID": "1111-2222",
        "TeamIdentifier": ["TEAMID1234"],
        "ExpirationDate": datetime(2027, 7, 30),
        "DeveloperCertificates": [b"cert-der-bytes"],
        "Entitlements": {**entitlements, "beta-reports-active": True},
    }
    if devices:
        profile["ProvisionedDevices"] = ["00008110-000000000000001E"]
    if snapshot is None:
        snapshot = f"\x00dart-snapshot {APP_ID} {APP_SECRET}\x00".encode()
    path = os.path.join(folder, "kazumi.ipa")
    root = "Payload/Runner.app/"
    with zipfile.ZipFile(path, "w") as z:
        z.writestr(root, "")
        z.writestr(root + "Info.plist", plistlib.dumps(info))
        z.writestr(root + "Runner", binary)
        z.writestr(root + "embedded.mobileprovision",
                   b"0\x82\x10\x00cms-header" + plistlib.dumps(profile) + b"cms-trailer")
        z.writestr(root + "Frameworks/App.framework/App", snapshot)
        z.writestr(root + "Frameworks/App.framework/Info.plist",
                   plistlib.dumps({"CFBundleShortVersionString": "1.0"}))
        z.writestr(root + "Frameworks/Flutter.framework/Info.plist",
                   plistlib.dumps({"CFBundleShortVersionString": "1.0"}))
        z.writestr(root + "Frameworks/App.framework/flutter_assets/AssetManifest.bin", b"a" * 10)
    return path



class Case(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)

    def manifest(self, needles=tuple(NEEDLES), **kwargs):
        with mock.patch.dict(os.environ, NEEDLES):
            return m.describe(fake_ipa(self.dir, **kwargs), list(needles), "abc",
                              {"xcode": "Xcode 26.6 Build version 17F113"})


class DescribeTest(Case):
    def test_reads_version_profile_and_entitlements(self):
        got = self.manifest()
        self.assertEqual(("3.1.0", "33", "abc"), (got["version"], got["build"], got["sha"]))
        self.assertTrue(got["profile"]["app_store"])
        self.assertEqual(f"TEAMID1234.{BUNDLE}", got["entitlements"]["application-identifier"])
        self.assertEqual({"App": "1.0", "Flutter": "1.0"}, got["frameworks"])
        self.assertEqual({"DANDANAPI_APPID": True, "DANDANAPI_KEY": True}, got["compiled_in"])
        self.assertIn("Frameworks/App.framework/flutter_assets/AssetManifest.bin", got["files"])
        self.assertEqual("Xcode 26.6 Build version 17F113", got["toolchain"]["xcode"])

    def test_never_writes_a_needle_value(self):
        text = json.dumps(self.manifest(), ensure_ascii=False)
        self.assertNotIn(APP_SECRET, text)
        self.assertNotIn(APP_ID, text)

    def test_refuses_a_bundle_that_carries_a_define(self):
        # Info.plist can expand $(DART_DEFINES), which holds base64 of KEY=value;
        # the manifest is a public artifact and nothing masks artifacts.
        define = base64.b64encode(f"DANDANAPI_KEY={APP_SECRET}".encode()).decode()
        for value in (define, f"RkxVVFRFUl9WRVJTSU9O,{define}", define.rstrip("="), APP_SECRET):
            with self.assertRaises(ValueError, msg=value):
                self.manifest(plist={"DartDefines": value})

    def test_missing_needle_is_reported_false(self):
        got = self.manifest(snapshot=b"\x00no keys here\x00")
        self.assertEqual({"DANDANAPI_APPID": False, "DANDANAPI_KEY": False}, got["compiled_in"])

    def test_json_round_trip(self):
        json.loads(json.dumps(self.manifest(), ensure_ascii=False))


class CheckTest(Case):
    def problems(self, build="33", **kwargs):
        return m.check(self.manifest(**kwargs), BUNDLE, build)

    def assertProblem(self, text, problems):
        self.assertTrue(any(text in p for p in problems), problems)

    def test_good_build_passes(self):
        self.assertEqual([], self.problems())

    def test_wrong_build_number(self):
        self.assertProblem("CFBundleVersion", self.problems(build="34"))

    def test_missing_purpose_string(self):
        self.assertProblem("NSCameraUsageDescription",
                           self.problems(drop=("NSCameraUsageDescription",)))

    def test_wrong_purpose_string(self):
        self.assertProblem("NSPhotoLibraryAddUsageDescription",
                           self.problems(plist={"NSPhotoLibraryAddUsageDescription": ""}))

    def test_missing_encryption_flag(self):
        self.assertProblem("ITSAppUsesNonExemptEncryption",
                           self.problems(drop=("ITSAppUsesNonExemptEncryption",)))

    def test_missing_version(self):
        self.assertProblem("CFBundleShortVersionString",
                           self.problems(drop=("CFBundleShortVersionString",)))

    def test_development_signature(self):
        self.assertProblem("get-task-allow", self.problems(get_task_allow=True))

    def test_ad_hoc_profile(self):
        self.assertProblem("App Store", self.problems(devices=True))

    def test_beta_reports_from_the_profile_is_enough(self):
        self.assertEqual([], self.problems(beta_reports=False))

    def test_key_not_compiled_in(self):
        self.assertProblem("DANDANAPI_KEY", self.problems(snapshot=b"nothing"))


class DiffTest(Case):
    def test_build_specific_fields_are_quiet(self):
        old = self.manifest(build="32")
        new = self.manifest(build="33", plist={"BuildMachineOSBuild": "25F80"})
        new["profile"]["uuid"] = "other"
        self.assertEqual([], m.diff(old, new))

    def test_reports_a_different_xcode(self):
        old = self.manifest()
        new = self.manifest(plist={"DTXcodeBuild": "17F200"})
        self.assertTrue(any("DTXcodeBuild" in line for line in m.diff(old, new)))

    def test_reports_real_differences(self):
        old = self.manifest()
        new = json.loads(json.dumps(old))
        new["info_plist"]["NSCameraUsageDescription"] = "changed"
        del new["files"]["Frameworks/App.framework/flutter_assets/AssetManifest.bin"]
        new["entitlements"]["get-task-allow"] = True
        new["toolchain"]["xcode"] = "Xcode 27.0"
        lines = m.diff(old, new)
        for text in ("NSCameraUsageDescription", "only in old", "get-task-allow", "toolchain.xcode"):
            self.assertTrue(any(text in line for line in lines), (text, lines))

    def test_toolchain_compared_only_when_both_have_it(self):
        old = self.manifest()
        new = json.loads(json.dumps(old))
        del old["toolchain"]
        self.assertEqual([], m.diff(old, new))


if __name__ == "__main__":
    unittest.main()

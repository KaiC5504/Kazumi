"""Describe a signed IPA as JSON, check it against what the TestFlight build must be,
or compare two.

    python scripts/ipa_manifest.py describe build/ios/ipa/kazumi.ipa --sha SHA \
        --toolchain toolchain.json --needle DANDANAPI_APPID --needle DANDANAPI_KEY
    python scripts/ipa_manifest.py check testflight-build.json \
        --bundle-id com.kaichuan.kazumi --build 33
    python scripts/ipa_manifest.py diff old.json new.json

The JSON goes into a public artifact, so nothing secret may enter it: --needle only
reports whether an environment variable's value is compiled into the Dart snapshot.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
from datetime import datetime

# CSMAGIC_EMBEDDED_ENTITLEMENTS: the XML entitlements blob in a code signature.
ENTITLEMENTS_MAGIC = b"\xfa\xde\x71\x71"

# What the build configs write; a wrong or empty value is rejected at upload too late.
PURPOSE_STRINGS = {
    "NSPhotoLibraryUsageDescription": "用于选择图片进行以图搜番",
    "NSPhotoLibraryAddUsageDescription": "用于将截图保存到相册",
    "NSCameraUsageDescription": "用于拍照进行以图搜番",
    "NSLocationWhenInUseUsageDescription": "Kazumi 不会读取你的位置",
}

# Differ between any two builds by design; `diff` doesn't report them. DT* keys stay:
# they name the Xcode and SDK, which should only change on purpose.
VOLATILE_INFO = re.compile(r"^(CFBundleVersion|BuildMachineOSBuild)$")
VOLATILE_PROFILE = {"name", "uuid", "expires"}


def jsonable(value):
    if isinstance(value, dict):
        return {k: jsonable(v) for k, v in value.items()}
    if isinstance(value, list):
        return [jsonable(v) for v in value]
    if isinstance(value, bytes):
        return "sha256:" + hashlib.sha256(value).hexdigest()
    if isinstance(value, datetime):
        return value.isoformat()
    return value


def leaks(text: str, values: list[str]) -> bool:
    """Whether text holds a value raw or base64-encoded at any byte offset."""
    for value in filter(None, values):
        raw = value.encode()
        forms = {value}
        for shift in range(3):
            tail = raw[shift:]
            core = base64.b64encode(tail[: len(tail) // 3 * 3]).decode()
            if core:
                forms |= {core, core.replace("+", "-").replace("/", "_")}
        if any(form in text for form in forms):
            return True
    return False


def provisioning_profile(blob: bytes) -> dict:
    """The plist inside a CMS-signed embedded.mobileprovision."""
    try:
        start = blob.index(b"<?xml")
        end = blob.index(b"</plist>", start) + len(b"</plist>")
        return plistlib.loads(blob[start:end])
    except ValueError:
        if not shutil.which("security"):
            raise
    # Not the usual layout; let macOS decode the CMS envelope properly.
    with tempfile.NamedTemporaryFile(suffix=".mobileprovision", delete=False) as f:
        f.write(blob)
    try:
        out = subprocess.run(["security", "cms", "-D", "-i", f.name],
                             capture_output=True, check=True).stdout
        return plistlib.loads(out)
    finally:
        os.unlink(f.name)


def signed_entitlements(binary: bytes) -> dict:
    at = binary.find(ENTITLEMENTS_MAGIC)
    while at != -1:
        try:
            # Big-endian length that includes the 8-byte header (XNU cs_blobs.h).
            length = struct.unpack(">I", binary[at + 4:at + 8])[0]
            return plistlib.loads(binary[at + 8:at + length])
        except Exception:
            at = binary.find(ENTITLEMENTS_MAGIC, at + 1)
    raise ValueError("the executable has no entitlements blob")


def describe(ipa_path: str, needles: list[str], sha: str | None = None,
             toolchain: dict | None = None) -> dict:
    with zipfile.ZipFile(ipa_path) as ipa:
        names = ipa.namelist()
        info_name = next(n for n in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n))
        root = info_name[: -len("Info.plist")]
        info = plistlib.loads(ipa.read(info_name))
        profile = provisioning_profile(ipa.read(root + "embedded.mobileprovision"))
        entitlements = signed_entitlements(ipa.read(root + info["CFBundleExecutable"]))
        snapshot = ipa.read(root + "Frameworks/App.framework/App")
        frameworks = {}
        for name in names:
            match = re.fullmatch(re.escape(root) + r"Frameworks/([^/]+)\.framework/Info\.plist", name)
            if match:
                frameworks[match.group(1)] = plistlib.loads(ipa.read(name)).get(
                    "CFBundleShortVersionString")
        files = {n[len(root):]: ipa.getinfo(n).file_size
                 for n in names if n.startswith(root) and not n.endswith("/")}

    compiled_in = {}
    for name in needles:
        value = os.environ.get(name, "")
        compiled_in[name] = bool(value) and value.encode() in snapshot
    manifest = {
        "sha": sha,
        "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"),
        "info_plist": jsonable(info),
        "profile": {
            "name": profile.get("Name"),
            "uuid": profile.get("UUID"),
            "team": profile.get("TeamIdentifier"),
            "expires": jsonable(profile.get("ExpirationDate")),
            "app_store": "ProvisionedDevices" not in profile
                         and not profile.get("ProvisionsAllDevices"),
            "certificates": [hashlib.sha1(c).hexdigest()
                             for c in profile.get("DeveloperCertificates", [])],
            "entitlements": jsonable(profile.get("Entitlements", {})),
        },
        "entitlements": jsonable(entitlements),
        "frameworks": frameworks,
        "files": files,
        "compiled_in": compiled_in,
    }
    if toolchain is not None:
        manifest["toolchain"] = toolchain
    # The manifest is a public artifact, and log masking never touches artifacts.
    if leaks(json.dumps(manifest, ensure_ascii=False), [os.environ.get(n, "") for n in needles]):
        raise ValueError("the IPA's metadata carries a --needle value; not describing it")
    return manifest


def check(manifest: dict, bundle_id: str, build: str) -> list[str]:
    info = manifest["info_plist"]
    problems = []
    for key, want in {
        "CFBundleIdentifier": bundle_id,
        "CFBundleVersion": build,
        "ITSAppUsesNonExemptEncryption": False,
        **PURPOSE_STRINGS,
    }.items():
        if info.get(key) != want:
            problems.append(f"Info.plist {key} is {info.get(key)!r}, expected {want!r}")
    if not manifest.get("version"):
        problems.append("Info.plist has no CFBundleShortVersionString")

    entitlements = manifest["entitlements"]
    if not str(entitlements.get("application-identifier", "")).endswith("." + bundle_id):
        problems.append(f"signed for {entitlements.get('application-identifier')!r}, "
                        f"not {bundle_id}")
    if entitlements.get("get-task-allow"):
        problems.append("signed with get-task-allow (a development signature)")
    if not (entitlements.get("beta-reports-active")
            or manifest["profile"]["entitlements"].get("beta-reports-active")):
        problems.append("neither the signature nor the profile has beta-reports-active, "
                        "so TestFlight won't take it")
    if not manifest["profile"]["app_store"]:
        problems.append("the provisioning profile isn't an App Store one")
    problems += [f"{name} isn't compiled into the app"
                 for name, found in manifest["compiled_in"].items() if not found]
    return problems


def diff(old: dict, new: dict) -> list[str]:
    lines = []

    def compare(label: str, a: dict, b: dict, skip=lambda key: False) -> None:
        for key in sorted(set(a) | set(b)):
            if skip(key) or a.get(key) == b.get(key):
                continue
            lines.append(f"{label}.{key}: {a.get(key)!r} -> {b.get(key)!r}")

    compare("info_plist", old["info_plist"], new["info_plist"], lambda k: bool(VOLATILE_INFO.match(k)))
    compare("profile", old["profile"], new["profile"], lambda k: k in VOLATILE_PROFILE)
    compare("entitlements", old["entitlements"], new["entitlements"])
    compare("frameworks", old["frameworks"], new["frameworks"])
    compare("compiled_in", old["compiled_in"], new["compiled_in"],
            lambda k: k not in old["compiled_in"] or k not in new["compiled_in"])
    if "toolchain" in old and "toolchain" in new:
        compare("toolchain", old["toolchain"], new["toolchain"])
    for name in sorted(set(old["files"]) - set(new["files"])):
        lines.append(f"files: only in old: {name}")
    for name in sorted(set(new["files"]) - set(old["files"])):
        lines.append(f"files: only in new: {name}")
    for name in sorted(set(old["files"]) & set(new["files"])):
        a, b = old["files"][name], new["files"][name]
        if max(a, b) >= 100_000 and abs(a - b) > 0.1 * max(a, b):
            lines.append(f"files: {name} {a} -> {b} bytes")
    return lines


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="ipa_manifest.py")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("describe")
    p.add_argument("ipa")
    p.add_argument("--sha")
    p.add_argument("--toolchain", help="JSON file describing the tools that built it")
    p.add_argument("--needle", action="append", default=[])
    p = sub.add_parser("check")
    p.add_argument("manifest")
    p.add_argument("--bundle-id", required=True)
    p.add_argument("--build", required=True)
    p = sub.add_parser("diff")
    p.add_argument("old")
    p.add_argument("new")
    args = parser.parse_args(argv)

    if args.command == "describe":
        toolchain = None
        if args.toolchain:
            with open(args.toolchain, encoding="utf-8") as f:
                toolchain = json.load(f)
        manifest = describe(args.ipa, args.needle, args.sha, toolchain)
        json.dump(manifest, sys.stdout, indent=1, sort_keys=True, ensure_ascii=False)
        print()
        return 0
    if args.command == "check":
        with open(args.manifest, encoding="utf-8") as f:
            problems = check(json.load(f), args.bundle_id, args.build)
        for problem in problems:
            print(f"  - {problem}")
        print("IPA check:", "FAIL" if problems else "pass")
        return 1 if problems else 0
    with open(args.old, encoding="utf-8") as f, open(args.new, encoding="utf-8") as g:
        lines = diff(json.load(f), json.load(g))
    print("\n".join(lines) if lines else "no differences beyond build-specific fields")
    return 0


if __name__ == "__main__":
    if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
        sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main(sys.argv[1:]))

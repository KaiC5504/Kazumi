"""Checks a public build output for the owner's hosts.

    python scripts/scan_public_build.py <folder | .apk | .zip> ...

Searches every file, recursing into zip-based archives, for `kaic5504.com`
(every personal host lives under it) as ASCII and as UTF-16LE (Android binary
XML and Windows version resources are UTF-16), case-insensitive. Plain
`kaic5504` would also match the fork's own github.com/KaiC5504 links, which
public builds need.

A scan that finds nothing proves nothing on its own, so each Dart AOT binary
(`app.so` on Windows, `libapp.so` on Android) must also contain a control
string every build carries, and at least one AOT binary must be found.

Exit 0: no hits, control found in every AOT binary.
"""

from __future__ import annotations

import io
import re
import sys
import zipfile
from pathlib import Path, PurePosixPath

NEEDLE = "kaic5504.com"
CONTROL = "raw.githubusercontent.com/Predidit/KazumiRules"
AOT_NAMES = {"app.so", "libapp.so"}
ARCHIVES = {".apk", ".zip", ".msix", ".aab", ".jar", ".ipa"}

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")


def patterns(text: str) -> list[re.Pattern[bytes]]:
    return [re.compile(re.escape(text.encode(enc)), re.I) for enc in ("ascii", "utf-16-le")]


NEEDLE_RE = patterns(NEEDLE)
CONTROL_RE = patterns(CONTROL)


def scan(name: str, data: bytes, hits: list[str], aot: dict[str, bool]) -> int:
    count = 1
    for pat in NEEDLE_RE:
        for m in pat.finditer(data):
            ctx = data[max(0, m.start() - 40): m.end() + 60].replace(b"\x00", b"")
            ctx = re.sub(rb"[^\x20-\x7e]", b".", ctx).decode("ascii")
            hits.append(f"{name}: ...{ctx}...")
    if PurePosixPath(name.replace("\\", "/")).name.lower() in AOT_NAMES:
        aot[name] = any(p.search(data) for p in CONTROL_RE)
    if Path(name).suffix.lower() in ARCHIVES or data[:4] == b"PK\x03\x04":
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                for info in z.infolist():
                    if not info.is_dir():
                        count += scan(f"{name}!/{info.filename}", z.read(info), hits, aot)
        except zipfile.BadZipFile:
            pass
    return count


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    hits: list[str] = []
    aot: dict[str, bool] = {}
    files = 0
    for arg in argv:
        root = Path(arg)
        if not root.exists():
            print(f"scan: {root} does not exist")
            return 1
        paths = [root] if root.is_file() else sorted(p for p in root.rglob("*") if p.is_file())
        for path in paths:
            files += scan(path.as_posix(), path.read_bytes(), hits, aot)

    for hit in hits:
        print(f"HIT {hit}")
    missing = sorted(name for name, found in aot.items() if not found)
    for name in missing:
        print(f"control string missing from {name}")
    if not aot:
        print("no Dart AOT binary (app.so / libapp.so) found; nothing was really scanned")
    ok = not hits and not missing and bool(aot)
    print(f"scan: {files} files, {len(hits)} hits; control found in "
          f"{len(aot) - len(missing)} of {len(aot)} binaries: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

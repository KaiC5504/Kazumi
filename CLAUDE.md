# Kazumi (KaiC fork)

Fork of `Predidit/Kazumi` (GPL-3.0). `origin` = `KaiC5504/Kazumi`, `upstream` =
`Predidit/Kazumi`. Keep the diff against upstream small so `git merge upstream/main`
stays easy:

- Never run `dart format` on upstream files. The repo uses the old (short) style and
  the current formatter rewrites whole files. Format only files this fork added.
- Don't bump upstream dependencies here.
- Regenerating code with build_runner reformats every `.g.dart`; keep only the ones
  whose source you changed (`git checkout` the rest).

Fork-only features: pre-upscaled episodes. The PC bakes the 质量档 Anime4K chain into
HEVC with ffmpeg + libplacebo (`lib/services/upscale/`), exports to a synced folder or
serves on the LAN, and weak devices (iPad Pro 3) import and play it with shaders off
(`DownloadEpisode.preUpscaled`). Also a 均衡档 tier using the Anime4K L models.

## Local tooling (Windows)

- Flutter via fvm (`fvm flutter ...`), version pinned in `pubspec.yaml`.
- Visual Studio 2026 Build Tools are required: `ech_http`'s native hook embeds a
  190 KB raw string literal that VS 2022's MSVC rejects (C2026). Upstream CI uses
  `windows-2025-vs2026`.
- ffmpeg must be a build with `libplacebo` (gyan.dev full build, at
  `D:\Tools\ffmpeg\bin`).

## Building and shipping

Flutter app; iOS is developed on Windows with no Mac. GitHub Actions compiles and
Codemagic signs. The full playbook, including every manual step and known failures, is
the global `ios-testflight` skill. Load it before touching signing, `codemagic.yaml` or
the Actions workflows.

Identity: Xcode target/scheme `Runner`, bundle id `com.kaichuan.kazumi` (patched at
build time from upstream's `com.example.kazumi`; extensions: none). Repo
`KaiC5504/Kazumi` (public). Codemagic app `Kazumi`.

1. Work on a feature branch or `dev`. Push. Upstream's `pr.yaml` is the compile check
   (`gh run list --branch <branch> --limit 1`, then `gh run watch <id> --exit-status`).
2. Merge to `main` and push.
3. `python scripts/codemagic.py status`, then `start main`, then `watch`.
4. Report the TestFlight build number, what changed and test steps for iPhone/iPad.

DanDanPlay danmaku needs our own `DANDANAPI_APPID` / `DANDANAPI_KEY` (Codemagic env
group, never committed). Without them danmaku search returns nothing.

The owner has authorised commit, push, Actions and Codemagic runs without asking.
Codemagic minutes are limited (500 a month across all apps; a Flutter iOS build is
~20-25 min), so never start a build before Actions is green.

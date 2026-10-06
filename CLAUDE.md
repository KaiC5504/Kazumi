# Kazumi (KaiC fork)

Fork of `Predidit/Kazumi` (GPL-3.0). `origin` = `KaiC5504/Kazumi`, `upstream` =
`Predidit/Kazumi`. Keep the diff against upstream small so `git merge upstream/main`
stays easy:

- Never run `dart format` on upstream files. The repo uses the old (short) style and
  the current formatter rewrites whole files. Format only files this fork added.
- Don't bump upstream dependencies here.
- Regenerating code with build_runner reformats every `.g.dart`; keep only the ones
  whose source you changed (`git checkout` the rest).

Fork-only code (dart format is fine here): `lib/services/upscale/`, `lib/services/skip/`,
`lib/services/library/` + `lib/pages/library/` (一起看 shared library),
`lib/services/update/testflight_update.dart`, `lib/services/player/syncplay_drift.dart`,
`lib/bean/dialog/glass_notice.dart`, and `server/` (library server, HK relay, netprobe).
For any other file, `git log --oneline upstream/main -- <file>` printing nothing means
the fork added it.

Pre-upscaled episodes: the PC bakes the 质量档 Anime4K chain into
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

1. Work on a feature branch or `dev`. Before the compile check, always bring the
   branch up to latest upstream: `git fetch upstream`, `git merge upstream/main`
   (resolve conflicts in favour of keeping both sides). The owner wants every
   TestFlight build to carry the newest upstream Kazumi, not only fork changes.
2. Push. Upstream's `pr.yaml` is the compile check. It only triggers on pull requests,
   so dispatch it on the fork, iOS only (with no `run_*` input it builds every
   platform): `gh workflow run pr.yaml -R KaiC5504/Kazumi --ref <branch> -f
   run_ios=true`, then `gh run list -R KaiC5504/Kazumi --branch <branch> --limit 1` and
   `gh run watch <id> -R KaiC5504/Kazumi --exit-status`. Without `-R`, `gh` lists
   upstream's runs.
3. Merge to `main` and push. Re-check `git rev-list --count main..upstream/main` is 0;
   if upstream moved during the check, merge again and re-run Actions.
4. `python scripts/codemagic.py status`, then `start main`, then `watch`.
5. Once it passes: `python scripts/codemagic.py publish-latest --notes "<短中文说明>"`.
   This writes `https://hk.kaic5504.com/app/latest.json`, and installed apps prompt
   for the update on launch, with 去更新 opening TestFlight. Add `--required` only when
   older builds must not keep running, e.g. a protocol change in 一起看. It locks
   older builds out 30 min later, so ask the owner first.
6. Report the TestFlight build number as `version (build)`, what changed (fork and
   upstream) and test steps for iPhone/iPad.

The fork's own version is the `--build-name` in `codemagic.yaml` (3.0.0 from build
15). Bump it there for a release, never in `pubspec.yaml`, which stays upstream's.

DanDanPlay danmaku needs our own `DANDANAPI_APPID` / `DANDANAPI_KEY` (Codemagic env
group, never committed). Without them danmaku search returns nothing.

The owner has authorised commit, push, Actions and Codemagic runs without asking.
Codemagic minutes are limited (500 a month across all apps; a Flutter iOS build is
~10 min), so never start a build before Actions is green.

# Kazumi (KaiC fork)

Read `D:/Repos/Apps/Kazumi/docs/local/fork-handbook.md` first: devices, viewing flows,
which server (HK relay, Hetzner) runs what, and the change timeline. Keep it current when
infrastructure moves. `docs/local/` is gitignored and holds the fork's specs and plans too;
never commit it (the path is absolute so other worktrees find it).

Fork of `Predidit/Kazumi` (GPL-3.0). `origin` = `KaiC5504/Kazumi`, `upstream` =
`Predidit/Kazumi`. This fork never sends PRs upstream: optimise for our own build
speed, not upstream's conventions. We do keep merging upstream into every build, so
keep the diff against upstream small enough that `git merge upstream/main` stays easy:

- Never run `dart format` on upstream files. The repo uses the old (short) style and
  the current formatter rewrites whole files. Format only files this fork added.
- Don't bump upstream dependencies here.
- Regenerating code with build_runner reformats every `.g.dart`; keep only the ones
  whose source you changed (`git checkout` the rest).

Fork-only code (dart format is fine here): `lib/services/upscale/`, `lib/services/skip/`,
`lib/services/library/` + `lib/pages/library/` (一起看 shared library),
`lib/services/update/testflight_update.dart`,
`lib/services/plugin/official_rules_sync.dart` (auto-installs official rules), `lib/services/player/syncplay_drift.dart`,
`lib/bean/dialog/glass_notice.dart`, `lib/bean/widget/source_quality_badge.dart`, and `server/` (library server, HK relay, netprobe).
Public build (fork-only too): `lib/build_flavor.dart`, `lib/services/update/public_update.dart`,
`lib/pages/download/public_gates.dart`, `lib/pages/about/fork_about_section.dart`,
`test/public_build_test.dart`, `scripts/public_check.py`, `scripts/scan_public_build.py`,
`.github/workflows/public-release.yaml`, `.github/README.md`, `branding/`.
For any other file, `git log --oneline upstream/main -- <file>` printing nothing means
the fork added it.

The Runpod cloud bake worker lives in `server/cloud/kazumi_bake_worker.py` and ships in
the app as a generated constant: after editing it, run `python
scripts/pack_cloud_worker.py`. Never declare a `.py`/`.sh` file as a Flutter asset:
App Store Connect rejects it as unsigned code at upload (builds 17 and 18).

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

1. Work on a feature branch or `dev`. Before the precheck, always bring the
   branch up to latest upstream: `git fetch upstream`, `git merge upstream/main`
   (resolve conflicts in favour of keeping both sides). The owner wants every
   TestFlight build to carry the newest upstream Kazumi, not only fork changes.
   Exception (owner, 2026-10-10): don't take upstream 4e821e48 (`rebaseIosDownloadPaths`
   in `storage.dart`). It rewrites iOS download paths without the fork's
   `upscaledVideoPath`, so baked episodes stop playing after a container move; the
   fork's `download_relocation.dart` already covers it. Until that call is neutralised
   (her path: partner tests, then move `partner-baseline`), build without merging
   upstream past it, and ask the owner.
2. `python scripts/precheck.py` (about 30 s). It diffs against the last Codemagic
   build that passed, then runs analyze (CI flags), the tests that import changed
   files, and an asset scan (App Store Connect rejects bundled files starting with
   `#!`, which no compile check catches). Exit 0: skip Actions. Exit 2: the native
   side changed (`pubspec.lock`, dependencies, `ios/`, `codemagic.yaml`), so push and
   run the fork's iOS-only, cached compile check: `gh workflow run ios-check.yaml -R
   KaiC5504/Kazumi --ref <branch>`, then `gh run list -R KaiC5504/Kazumi --workflow
   ios-check.yaml --limit 1` and watch it in the background with `gh run watch <id> -R
   KaiC5504/Kazumi --exit-status`. Without `-R`, `gh` lists upstream's runs.
   Upstream's `pr.yaml` (tests, then a sequential build, ~13 min) is no longer used.
   Then `python scripts/partner_check.py` (about 3 min) on the exact commit that will
   be built: the girlfriend's 一起看 and update path, with guards that fail if her
   build config, the files on her path (since the `partner-baseline` tag) or her tests
   changed. `codemagic.py start` refuses a commit it hasn't passed. If a guard fails,
   the change needs partner tests first. A deliberate change to her path (e.g. a
   一起看 fix) is signed off by moving the tag to that commit once its tests are in
   (`git tag -f partner-baseline <commit>`, `git push -f origin partner-baseline`);
   then test the build on the owner's iPhone before she gets it. Work that must not
   touch her path (the public build) never moves the tag.
3. Merge to `main` and push. Re-check `git rev-list --count main..upstream/main` is 0;
   if upstream moved during the check, merge again and re-run the precheck.
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

## Public release

A public Android APK + Windows zip + unsigned iOS IPA on this repo's Releases, separate from TestFlight (its
own version line from 3.0.0). `KAZUMI_PUBLIC=true` (read once, as a const, in
`lib/build_flavor.dart`) hides 一起看, cloud bake and library upload, and points updates,
rules and About at public sources. Only `public-release.yaml` passes it; codemagic.yaml
never does, so her build keeps the personal defaults with zero configuration.

- Code on her path changes only behind `kPublicBuild` / `showCloudUi`, and every commit on
  main still passes `partner_check.py` (never move `partner-baseline` for public work).
  Then `python scripts/public_check.py` (her-path rule, personal tests with no defines,
  the whole suite with the public defines; only `partner_flow_test.dart`,
  `testflight_update_test.dart` and the tests named in `PUBLIC_FAIL_TESTS` may
  fail there).
- Release: dispatch from main, `gh workflow run public-release.yaml -R KaiC5504/Kazumi
  --ref main -f version=X.Y.Z -F notes=@notes.txt` (a draft), check the draft with the
  owner (`docs/local/public-build-test-plan.md` §D), then `gh release edit X.Y.Z -R
  KaiC5504/Kazumi --draft=false --latest` and check `gh api
  repos/KaiC5504/Kazumi/releases/latest` lists both assets with `sha256:` digests.
  Rollback: mark a bad release `--prerelease` and ship the next version; never delete a
  published tag.
- Upstream's `release.yaml` is disabled on the fork (it fires on every tag push). After
  every upstream merge, `gh workflow list -R KaiC5504/Kazumi` must still show it
  `disabled_manually`; `public_check.py --static` fails the release otherwise.
- Never run a public build on the PC without the CI identity patches (it would open the
  owner's Hive). Keep the fork quiet: no upstream issue references (`Predidit/Kazumi#N`,
  issue URLs) in commits or release notes.
- `library_test.dart` "a cancelled upload stops, keeps its parts and resumes" is flaky
  under load: rerun once before blaming a change.

The owner has authorised commit, push, Actions and Codemagic runs without asking.
Codemagic minutes are limited (500 a month across all apps; a Flutter iOS build is
~10 min), so never start a build before the precheck passes (and `ios-check.yaml`,
when the precheck asks for it).

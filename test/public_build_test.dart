// Runs in both modes and checks what KAZUMI_PUBLIC switches:
//   fvm flutter test test/public_build_test.dart
//   fvm flutter test test/public_build_test.dart --dart-define=KAZUMI_PUBLIC=true --dart-define=KAZUMI_LIBRARY_SERVER=
// In personal mode it is a second witness that her build didn't move.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/bean/dialog/dialog.dart';
import 'package:kazumi/build_flavor.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/my/watch_stats.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/pages/about/about_page.dart';
import 'package:kazumi/pages/about/fork_about_section.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/download/public_gates.dart';
import 'package:kazumi/pages/my/my_space_view.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/request/clients/bangumi_client.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/library/library_controller.dart';
import 'package:kazumi/services/library/library_invite.dart';
import 'package:kazumi/services/network/bangumi_acceleration.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/update/auto_updater.dart';
import 'package:kazumi/services/update/public_update.dart';
import 'package:kazumi/services/update/testflight_update.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const hkSite = 'https://hk.kaic5504.com';
const librarySite = 'https://kazumi.kaic5504.com';

// Trimmed from what api.github.com returns for a release made by
// public-release.yaml.
const forkRelease = '''
{
  "html_url": "https://github.com/KaiC5504/Kazumi/releases/tag/3.0.0",
  "tag_name": "3.0.0",
  "name": "Kazumi 3.0.0",
  "draft": false,
  "prerelease": false,
  "published_at": "2026-10-12T08:00:00Z",
  "body": "- 首个公开版本",
  "assets": [
    {
      "name": "Kazumi_windows_3.0.0.zip",
      "content_type": "application/zip",
      "digest": "sha256:1f2e3d4c5b6a79881f2e3d4c5b6a79881f2e3d4c5b6a79881f2e3d4c5b6a7988",
      "browser_download_url": "https://github.com/KaiC5504/Kazumi/releases/download/3.0.0/Kazumi_windows_3.0.0.zip"
    },
    {
      "name": "Kazumi_android_3.0.0.apk",
      "content_type": "application/vnd.android.package-archive",
      "digest": "sha256:9a8b7c6d5e4f30219a8b7c6d5e4f30219a8b7c6d5e4f30219a8b7c6d5e4f3021",
      "browser_download_url": "https://github.com/KaiC5504/Kazumi/releases/download/3.0.0/Kazumi_android_3.0.0.apk"
    }
  ]
}
''';

void main() {
  late Directory directory;
  late PathProviderPlatform originalPathProvider;

  // The About page's app bar reads a window setting from Hive.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp('kazumi_public_test_');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });

  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = originalPathProvider;
    await directory.delete(recursive: true);
  });

  group('我的 page', () {
    for (final width in [400.0, 1200.0]) {
      testWidgets('一起看 only in the personal build (${width.toInt()} px)', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        MyDestination? opened;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MySpaceView(
                stats: const WatchStats(),
                onOpen: (d) => opened = d,
              ),
            ),
          ),
        );
        expect(find.text('一起看'), kPublicBuild ? findsNothing : findsOneWidget);
        for (final title in ['历史记录', '离线下载', '同步备份', '存储管理', '关于 Kazumi']) {
          expect(find.text(title), findsWidgets, reason: title);
        }
        await tester.tap(find.text('离线下载').first);
        expect(opened, MyDestination.downloads);
      });
    }
  });

  group('About page', () {
    for (final width in [400.0, 1200.0]) {
      testWidgets('keeps 检查更新 and the upstream links (${width.toInt()} px)', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var checks = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: AboutPage(
              onCheckUpdate: () async {
                checks++;
                return true;
              },
            ),
          ),
        );
        expect(find.text(TestflightUpdate.versionLabel), findsOneWidget);
        expect(find.text('检查更新'), findsOneWidget);
        expect(find.text('更新日志'), findsOneWidget);
        expect(find.text('项目'), findsOneWidget);
        expect(find.text('开源'), findsOneWidget);
        expect(find.text('源代码'), findsOneWidget);
        expect(
          find.byType(ForkAboutSection),
          kPublicBuild ? findsOneWidget : findsNothing,
        );
        expect(
          find.textContaining('与官方无关'),
          kPublicBuild ? findsOneWidget : findsNothing,
        );
        await tester.tap(find.text('检查更新'));
        await tester.pump();
        expect(checks, 1);
      });
    }
  });

  group('download page', () {
    test(
      'cloud and upload controls follow canBake only in the personal build',
      () {
        expect(showCloudUi(false), isFalse);
        expect(showCloudUi(true), kPublicBuild ? isFalse : isTrue);
      },
    );
  });

  group('built-in values', () {
    test('rules mirror', () {
      expect(
        ApiEndpoints.pluginShopMirror,
        kPublicBuild
            ? 'https://cdn.gh-proxy.org/https://raw.githubusercontent.com/Predidit/KazumiRules/main/'
            : '$hkSite/rules/',
      );
    });

    test('update sources', () {
      expect(
        ApiEndpoints.latestApp,
        kPublicBuild
            ? 'https://github.com/KaiC5504/Kazumi/releases/latest'
            : 'https://api.github.com/repos/Predidit/Kazumi/releases/latest',
      );
      expect(
        ApiEndpoints.latestAppMirror,
        kPublicBuild
            ? 'https://api.github.com/repos/KaiC5504/Kazumi/releases/latest'
            : 'https://api.kazumi.fyi/kazumi/v1/app/latest',
      );
      expect(
        TestflightUpdate.latestUri.toString(),
        kPublicBuild ? '' : '$hkSite/app/latest.json',
      );
      expect(
        TestflightUpdate.replacesUpstream,
        kPublicBuild ? Platform.isWindows : isTrue,
      );
    });

    test('nothing the public build uses points at the owner', () {
      if (!kPublicBuild) return;
      for (final value in [
        ApiEndpoints.pluginShopMirror,
        ApiEndpoints.latestApp,
        ApiEndpoints.latestAppMirror,
        TestflightUpdate.latestUri.toString(),
        defaultLibraryServer,
      ]) {
        expect(value, isNot(contains('kaic5504')));
      }
    });
  });

  group('Bangumi acceleration', () {
    setUp(() => GStorage.putSetting(SettingsKeys.bangumiAcceleration, ''));

    test('an unset mode becomes 直连 only in the public build', () async {
      applyPublicBangumiDefault();
      await Future<void>.delayed(Duration.zero);
      expect(
        BangumiAcceleration.current,
        kPublicBuild ? BangumiAcceleration.direct : BangumiAcceleration.mirror,
      );
    });

    test('a mode the user picked is kept', () async {
      await GStorage.putSetting(SettingsKeys.bangumiAcceleration, 'mirror');
      applyPublicBangumiDefault();
      await Future<void>.delayed(Duration.zero);
      expect(BangumiAcceleration.current, BangumiAcceleration.mirror);
    });
  });

  group('library server', () {
    test('default', () {
      if (defaultLibraryServer.isEmpty) return;
      expect(defaultLibraryServer, librarySite);
    });

    test('an empty server redeems nothing and contacts nobody', () async {
      if (defaultLibraryServer.isNotEmpty) {
        markTestSkipped('needs --dart-define=KAZUMI_LIBRARY_SERVER=');
        return;
      }
      final hosts = <String>[];
      final c = LibraryController(
        _FakeRepository(),
        DownloadController(
          _FakeRepository(),
          _FakeDownloadManager(),
          PluginsController(),
        ),
        _FakeDownloadManager(),
      );
      final error = await HttpOverrides.runWithHttpOverrides(
        () => c.redeemCode('kz7m4qpa'),
        _HostRecorder(hosts),
      );
      expect(error, isNotNull);
      expect(c.pendingInvite.value, isNull);
      expect(hosts.where((h) => h.isNotEmpty), isEmpty);
    });
  });

  group('fork release', () {
    test("AutoUpdater's parser picks the APK and its digest", () {
      final json = jsonDecode(forkRelease) as Map<String, dynamic>;
      final apk = getUpdateAssetForType(
        json['assets'] as List<dynamic>,
        InstallationType.androidApk,
      );
      expect(apk?['name'], 'Kazumi_android_3.0.0.apk');
      expect(getUpdateFileHashFromAsset(apk!), hasLength(64));
      expect(
        getUpdateDownloadUrlFromAsset(apk),
        startsWith('https://github.com/KaiC5504/Kazumi/releases/download/'),
      );
    });

    test('PublicUpdate reads it and compares versions', () async {
      PublicUpdate on(String version) => PublicUpdate(
        fetchLatest: () async => forkRelease,
        launch: (_) async => true,
        currentVersion: version,
      );
      final release = (await on('2.3.8').fetch())!;
      expect(release.version, '3.0.0');
      expect(
        release.page,
        'https://github.com/KaiC5504/Kazumi/releases/tag/3.0.0',
      );
      expect(release.notes, '- 首个公开版本');
      expect(on('2.3.8').isNewer(release), isTrue);
      expect(on('3.0.0').isNewer(release), isFalse);
      expect(on('3.0.1').isNewer(release), isFalse);
    });

    test('PublicUpdate ignores tags it cannot compare', () {
      expect(PublicRelease.tryParse({'tag_name': 'v3.0.0'}), isNull);
      expect(PublicRelease.tryParse({'message': 'Not Found'}), isNull);
    });
  });

  group('PublicUpdate prompt', () {
    late List<Uri> launched;

    PublicUpdate updater(String version, {bool reachable = true}) =>
        PublicUpdate(
          fetchLatest: () async =>
              reachable ? forkRelease : throw const SocketException('offline'),
          launch: (uri) async {
            launched.add(uri);
            return true;
          },
          currentVersion: version,
        );

    setUp(() => launched = []);

    testWidgets('a newer release offers 稍后 and 去下载', (tester) async {
      await pumpApp(tester);
      expect(await updater('2.3.8').check(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('发现新版本 3.0.0'), findsOneWidget);
      expect(find.text('- 首个公开版本'), findsOneWidget);

      await tester.tap(find.text('去下载'));
      await tester.pumpAndSettle();
      expect(find.text('发现新版本 3.0.0'), findsNothing);
      expect(launched, [
        Uri.parse('https://github.com/KaiC5504/Kazumi/releases/tag/3.0.0'),
      ]);
    });

    testWidgets('稍后 holds for this launch, a manual check still shows it', (
      tester,
    ) async {
      await pumpApp(tester);
      final u = updater('2.3.8');
      await u.check();
      await tester.pumpAndSettle();
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();
      expect(find.text('发现新版本 3.0.0'), findsNothing);

      await u.check();
      await tester.pumpAndSettle();
      expect(find.text('发现新版本 3.0.0'), findsNothing);

      await u.check(manual: true);
      await tester.pumpAndSettle();
      expect(find.text('发现新版本 3.0.0'), findsOneWidget);
      expect(launched, isEmpty);
    });

    testWidgets('up to date: silent on launch, a toast when asked', (
      tester,
    ) async {
      await pumpApp(tester);
      final u = updater('3.0.0');
      expect(await u.check(), isTrue);
      await tester.pump();
      expect(find.textContaining('已是最新版本'), findsNothing);

      expect(await u.check(manual: true), isTrue);
      await tester.pump();
      expect(find.text('已是最新版本 (3.0.0)'), findsOneWidget);
      expect(find.textContaining('发现新版本'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('offline: silent on launch, a toast when asked', (
      tester,
    ) async {
      await pumpApp(tester);
      final u = updater('2.3.8', reachable: false);
      expect(await u.check(), isFalse);
      await tester.pump();
      expect(find.textContaining('检查更新失败'), findsNothing);

      expect(await u.check(manual: true), isFalse);
      await tester.pump();
      expect(find.text('检查更新失败，请稍后重试'), findsOneWidget);
      expect(find.textContaining('发现新版本'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });
  });
}

Future<void> pumpApp(WidgetTester tester) => tester.pumpWidget(
  MaterialApp(
    navigatorKey: rootNavigatorKey,
    scaffoldMessengerKey: rootScaffoldMessengerKey,
    navigatorObservers: [KazumiDialog.observer],
    home: const Scaffold(body: Text('home')),
  ),
);

/// Records the host of every request and lets it through unchanged.
class _HostRecorder extends HttpOverrides {
  _HostRecorder(this.hosts);

  final List<String> hosts;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _HostClient(super.createHttpClient(context), hosts);
}

class _HostClient implements HttpClient {
  _HostClient(this._real, this._hosts);

  final HttpClient _real;
  final List<String> _hosts;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    _hosts.add(url.host);
    return _real.openUrl(method, url);
  }

  @override
  Duration? get connectionTimeout => _real.connectionTimeout;

  @override
  set connectionTimeout(Duration? value) => _real.connectionTimeout = value;

  @override
  void close({bool force = false}) => _real.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeRepository implements IDownloadRepository {
  @override
  List<DownloadRecord> getAllRecords() => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeDownloadManager implements IDownloadManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

// Pins down everything the partner's TestFlight app does, so a change that
// moves server addresses behind build flags can be shown not to touch her.
// Every request goes through a recording HttpClient that remembers the URL
// the app asked for and answers from a local fake server.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/my/watch_stats.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/my/my_space_view.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/request/apis/plugin_catalog_api.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/library/host_router.dart';
import 'package:kazumi/services/library/library_controller.dart';
import 'package:kazumi/services/library/library_invite.dart';
import 'package:kazumi/services/player/syncplay_endpoint.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/update/testflight_update.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const librarySite = 'https://kazumi.kaic5504.com';
const hkSite = 'https://hk.kaic5504.com';
const syncPlay = 'hk.kaic5504.com:8999';
const room = 'kaic-room';
const viewKey = 'view-key-from-invite';

void main() {
  late Directory directory;
  late PathProviderPlatform originalPathProvider;
  late HttpServer fake;
  final seen = <Uri>[];

  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp('kazumi_partner_test_');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
    fake = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fake.listen(_answer);
  });

  setUp(() async {
    seen.clear();
    await GStorage.resetSettings(SettingsKeys.all);
  });

  tearDownAll(() async {
    await fake.close(force: true);
    await Hive.close();
    PathProviderPlatform.instance = originalPathProvider;
    await directory.delete(recursive: true);
  });

  Future<T> recorded<T>(Future<T> Function() body) =>
      HttpOverrides.runWithHttpOverrides(
        body,
        _Recorder(seen, Uri.parse('http://127.0.0.1:${fake.port}')),
      );

  LibraryController library() => LibraryController(
    _FakeRepository(),
    DownloadController(
      _FakeRepository(),
      _FakeDownloadManager(),
      PluginsController(),
    ),
    _FakeDownloadManager(),
  );

  Future<void> seedBuild27() async {
    final put = GStorage.putSetting<String>;
    await put(SettingsKeys.libraryServer, librarySite);
    await put(SettingsKeys.libraryKey, viewKey);
    await put(SettingsKeys.libraryDisplayName, '她');
    await put(SettingsKeys.libraryMirrors, hkSite);
    await put(SettingsKeys.libraryRoom, room);
    await put(SettingsKeys.syncPlayEndPoint, syncPlay);
    await put(SettingsKeys.librarySyncPlayEndPoint, syncPlay);
    await put(SettingsKeys.libraryDeviceId, '0123456789abcdef');
    await put(
      SettingsKeys.libraryRouteCheck,
      RouteCheckResult(
        chosenHost: hkSite,
        byHost: const {},
        at: DateTime(2026, 10, 7),
      ).encode(),
    );
  }

  group('built-in addresses in her build', () {
    test('invite codes are redeemed on the library server', () {
      expect(defaultLibraryServer, librarySite);
    });

    test('the update prompt reads latest.json on HK', () {
      expect(TestflightUpdate.latestUri.toString(), '$hkSite/app/latest.json');
      expect(TestflightUpdate.replacesUpstream, isTrue);
    });

    test('rules come through the HK mirror, which is on by default', () {
      expect(ApiEndpoints.pluginShopMirror, '$hkSite/rules/');
      expect(GStorage.getSetting(SettingsKeys.enableGitProxy), isTrue);
    });
  });

  group('first install: she types the invite code', () {
    test('the code goes to the library server and joins her', () async {
      final c = library();
      final error = await recorded(() => c.redeemCode('kz7m 4qpa'));
      expect(error, isNull);
      expect(seen.single.toString(), '$librarySite/api/redeem');
      final invite = c.pendingInvite.value!;
      expect(invite.server, librarySite);
      expect(invite.key, viewKey);

      seen.clear();
      expect(await recorded(() => c.acceptInvite(invite, ' 她 ')), isNull);
      expect(seen.first.toString(), '$librarySite/api/config');
      expect(c.isConfigured, isTrue);
      expect(c.server, librarySite);
      expect(c.key, viewKey);
      expect(c.displayName, '她');
      expect(c.syncRoom, room);
      expect(GStorage.getSetting(SettingsKeys.libraryMirrors), hkSite);
      expect(GStorage.getSetting(SettingsKeys.syncPlayEndPoint), syncPlay);
      expect(
        GStorage.getSetting(SettingsKeys.librarySyncPlayEndPoint),
        syncPlay,
      );
      // Let the one-time background route check finish against the fake.
      await recorded(() => Future.delayed(const Duration(seconds: 1)));
    });
  });

  group('after an update from build 27', () {
    test('she is still joined, with nothing to re-enter', () async {
      await seedBuild27();
      final c = library();
      expect(c.isConfigured, isTrue);
      expect(c.server, librarySite);
      expect(c.key, viewKey);
      expect(c.displayName, '她');
      expect(c.syncRoom, room);
      expect(c.routeMode, RouteMode.auto);
      expect(c.pendingInvite.value, isNull);
    });

    test('the lobby goes through HK', () async {
      await seedBuild27();
      final c = library();
      expect(c.router.order.first.toString(), hkSite);
      await recorded(c.refresh);
      expect(c.error.value, isNull);
      expect(seen.first.toString(), '$hkSite/api/episodes');
    });

    test('HK still comes first if her route check never got stored', () async {
      await seedBuild27();
      await GStorage.putSetting<String>(SettingsKeys.libraryRouteCheck, '');
      expect(library().router.order.first.toString(), hkSite);
    });

    test('the stored route check is not run again', () async {
      await seedBuild27();
      await recorded(() async {
        library().scheduleRouteCheckOnce();
        await Future.delayed(const Duration(milliseconds: 300));
      });
      expect(seen, isEmpty);
    });

    test('SyncPlay joins the HK server over TLS', () {
      return seedBuild27().then((_) {
        final stored = GStorage.getSetting(SettingsKeys.syncPlayEndPoint);
        final parsed = parseSyncPlayEndPoint(stored)!;
        expect(parsed.host, 'hk.kaic5504.com');
        expect(parsed.port, 8999);
        // The player turns TLS on when the endpoint equals this setting.
        expect(
          stored.trim(),
          GStorage.getSetting(SettingsKeys.librarySyncPlayEndPoint),
        );
      });
    });
  });

  group('her update prompt', () {
    test('build 27 reads HK and is offered the newer build', () async {
      final update = TestflightUpdate(currentBuild: 27, isIOS: true);
      final release = await recorded(update.fetch);
      expect(seen.single.toString(), '$hkSite/app/latest.json');
      expect(release!.build, 28);
      expect(
        updateNeedFor(release, 27, DateTime.utc(2026, 10, 9)),
        UpdateNeed.optional,
      );
    });
  });

  group('rules in China', () {
    tearDown(DioFactory.reset);

    test('the rule catalog is fetched from the HK mirror', () async {
      final urls = <Uri>[];
      DioFactory.rulesRepoDio.httpClientAdapter = _RecordingAdapter(urls);
      await PluginCatalogApi.getPluginList();
      expect(urls.single.toString(), '$hkSite/rules/index.json');
    });
  });

  group('我的 page', () {
    for (final width in [400.0, 1200.0]) {
      testWidgets('shows 一起看 and opens it (${width.toInt()} px)', (
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
        await tester.tap(find.text('一起看'));
        expect(opened, MyDestination.together);
      });
    }
  });
}

Future<void> _answer(HttpRequest request) async {
  final body = switch (request.uri.path) {
    '/api/redeem' => {'key': viewKey},
    '/api/config' => {
      'syncplay': syncPlay,
      'syncplayTls': true,
      'room': room,
      'mirrors': [hkSite],
    },
    '/api/episodes' => {'episodes': []},
    '/app/latest.json' => {'build': 28, 'version': '3.2.0', 'notes': ''},
    _ => null,
  };
  await utf8.decodeStream(request);
  request.response.statusCode = body == null ? 404 : 200;
  if (body != null) request.response.write(jsonEncode(body));
  await request.response.close();
}

class _Recorder extends HttpOverrides {
  _Recorder(this.seen, this.target);

  final List<Uri> seen;
  final Uri target;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _RoutingClient(super.createHttpClient(context), seen, target);
}

class _RoutingClient implements HttpClient {
  _RoutingClient(this._real, this._seen, this._target);

  final HttpClient _real;
  final List<Uri> _seen;
  final Uri _target;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    _seen.add(url);
    return _real.openUrl(
      method,
      url.replace(
        scheme: _target.scheme,
        host: _target.host,
        port: _target.port,
      ),
    );
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);

  @override
  Duration? get connectionTimeout => _real.connectionTimeout;

  @override
  set connectionTimeout(Duration? value) => _real.connectionTimeout = value;

  @override
  void close({bool force = false}) => _real.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.urls);

  final List<Uri> urls;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    urls.add(options.uri);
    return ResponseBody.fromString('[]', 200);
  }

  @override
  void close({bool force = false}) {}
}

class _FakeRepository implements IDownloadRepository {
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

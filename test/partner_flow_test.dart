// Pins down everything the partner's TestFlight app does, so a change that
// moves server addresses behind build flags can be shown not to touch her.
// Every request goes through a recording HttpClient that remembers the URL
// the app asked for and answers from a local fake server.
//
// Her stored data is seeded with raw Hive keys, not SettingsKeys, so a renamed
// key fails here instead of quietly orphaning what her phone already has.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/bean/dialog/dialog.dart';
import 'package:kazumi/bean/dialog/glass_notice.dart';
import 'package:kazumi/modules/my/watch_stats.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/my/my_controller.dart';
import 'package:kazumi/pages/my/my_space_view.dart';
import 'package:kazumi/pages/video/episode_selection_panel.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/pages/player/controller/player_syncplay_controller.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/repositories/history_repository.dart';
import 'package:kazumi/repositories/danmaku_shield_repository.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/services/library/library_playback.dart';
import 'package:kazumi/request/apis/plugin_catalog_api.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/download/mirror_selector.dart';
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
const herName = '她';
const herDevice = '0123456789abcdef';
const episodeId = 'ep-fate-zero-2';
const bangumiId = 10639;

/// One request as the app made it, before the recorder redirected it.
class Seen {
  Seen(this.method, this.url);
  final String method;
  final Uri url;
  Map<String, dynamic>? body;

  @override
  String toString() => '$method $url';
}

void main() {
  late Directory directory;
  late PathProviderPlatform originalPathProvider;
  late HttpServer fake;
  final seen = <Seen>[];
  final bodies = <String, List<Map<String, dynamic>>>{};
  var latest = <String, dynamic>{};

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    Logger.level = Level.off;
    GlassNotice.debugOnShow = (_) {};
    directory = await Directory.systemTemp.createTemp('kazumi_partner_test_');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
    fake = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fake.listen((request) async {
      final text = await utf8.decodeStream(request);
      if (text.isNotEmpty) {
        final json = jsonDecode(text) as Map<String, dynamic>;
        bodies.putIfAbsent(request.uri.path, () => []).add(json);
      }
      final body = switch (request.uri.path) {
        '/api/redeem' => {'key': viewKey},
        '/api/config' => {
          'syncplay': syncPlay,
          'syncplayTls': true,
          'room': room,
          'mirrors': [hkSite],
        },
        '/api/episodes' => {
          'episodes': [_episodeJson()],
        },
        '/api/room/heartbeat' || '/api/room/select' => {'members': []},
        '/api/room/leave' => <String, dynamic>{},
        '/app/latest.json' => latest,
        _ => null,
      };
      request.response.statusCode = body == null ? 404 : 200;
      if (body != null) request.response.write(jsonEncode(body));
      await request.response.close();
    });
  });

  setUp(() async {
    seen.clear();
    bodies.clear();
    latest = {'build': 28, 'version': '3.2.0', 'notes': ''};
    await GStorage.resetSettings(SettingsKeys.all);
  });

  tearDownAll(() async {
    GlassNotice.debugOnShow = null;
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

  List<String> urls() => [for (final s in seen) '${s.method} ${s.url}'];

  LibraryController library() => LibraryController(
    _FakeRepository(),
    DownloadController(
      _FakeRepository(),
      _FakeDownloadManager(),
      PluginsController(),
    ),
    _FakeDownloadManager(),
  );

  /// What build 27 left in her settings box, written with the raw keys.
  Future<void> seedBuild27({bool routeCheck = true}) async {
    final box = Hive.box<dynamic>('setting');
    await box.putAll({
      'libraryServer': librarySite,
      'libraryKey': viewKey,
      'libraryDisplayName': herName,
      'libraryMirrors': hkSite,
      'libraryRoom': room,
      'syncPlayEndPoint': syncPlay,
      'librarySyncPlayEndPoint': syncPlay,
      'libraryDeviceId': herDevice,
      if (routeCheck)
        'libraryRouteCheck': RouteCheckResult(
          chosenHost: hkSite,
          byHost: const {},
          at: DateTime(2026, 10, 7),
        ).encode(),
    });
  }

  Future<void> until(bool Function() done, String what) async {
    for (var i = 0; i < 100; i++) {
      if (done()) return;
      await Future.delayed(const Duration(milliseconds: 50));
    }
    fail('timed out waiting for $what');
  }

  group('built-in addresses in her build', () {
    test('invite codes are redeemed on the library server', () {
      expect(defaultLibraryServer, librarySite);
    });

    test('the update prompt reads latest.json on HK and opens TestFlight', () {
      expect(TestflightUpdate.latestUri.toString(), '$hkSite/app/latest.json');
      expect(TestflightUpdate.replacesUpstream, isTrue);
      expect(
        TestflightUpdate.testflightUri.toString(),
        'itms-beta://beta.itunes.apple.com/v1/app/6818711929',
      );
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
      expect(urls(), ['POST $librarySite/api/redeem']);
      expect(bodies['/api/redeem'], [
        {'code': 'KZ7M4QPA'},
      ]);
      final invite = c.pendingInvite.value!;
      expect(invite.server, librarySite);
      expect(invite.key, viewKey);

      seen.clear();
      final routes = c.routeVersion.value;
      expect(
        await recorded(() => c.acceptInvite(invite, ' $herName ')),
        isNull,
      );
      expect(urls().first, 'GET $librarySite/api/config');
      expect(c.pendingInvite.value, isNull);
      expect(c.isConfigured, isTrue);
      expect(c.server, librarySite);
      expect(c.key, viewKey);
      expect(c.displayName, herName);
      expect(c.syncRoom, room);
      final box = Hive.box<dynamic>('setting');
      expect(box.get('libraryServer'), librarySite);
      expect(box.get('libraryKey'), viewKey);
      expect(box.get('libraryMirrors'), hkSite);
      expect(box.get('syncPlayEndPoint'), syncPlay);
      expect(box.get('librarySyncPlayEndPoint'), syncPlay);

      // The one-time route check runs in the background and tries HK.
      await recorded(
        () => until(() => c.routeVersion.value > routes, 'the route check'),
      );
      expect(
        seen.any((s) => s.url.host == 'hk.kaic5504.com'),
        isTrue,
        reason: urls().join('\n'),
      );
    });

    test('a wrong code says so and saves nothing', () async {
      final c = library();
      expect(await recorded(() => c.redeemCode('abc')), contains('8 位'));
      expect(seen, isEmpty);
      expect(c.isConfigured, isFalse);
    });
  });

  group('after an update from build 27', () {
    test('she is still joined, with nothing to re-enter', () async {
      await seedBuild27();
      final c = library();
      expect(c.isConfigured, isTrue);
      expect(c.server, librarySite);
      expect(c.key, viewKey);
      expect(c.displayName, herName);
      expect(c.syncRoom, room);
      expect(c.deviceId, herDevice);
      expect(c.routeMode, RouteMode.auto);
      expect(c.storedRoute?.chosenHost, hkSite);
      expect(c.pendingInvite.value, isNull);
    });

    test('the lobby goes through HK under her name, and leaving says so', () {
      return recorded(() async {
        await seedBuild27();
        final c = library();
        await c.enterLobby();
        expect(c.error.value, isNull);
        expect(c.episodes.single.id, episodeId);
        await until(
          () => bodies['/api/room/heartbeat'] != null,
          'the first heartbeat',
        );
        expect(
          urls(),
          containsAll([
            'GET $hkSite/api/config',
            'GET $hkSite/api/episodes',
            'POST $hkSite/api/room/heartbeat',
          ]),
        );
        expect(seen.where((s) => s.url.host != 'hk.kaic5504.com'), isEmpty);
        expect(bodies['/api/room/heartbeat']!.first, {
          'deviceId': herDevice,
          'name': herName,
          'state': 'lobby',
          'episodeId': null,
        });

        await c.leaveLobby();
        expect(urls().last, 'POST $hkSite/api/room/leave');
        expect(bodies['/api/room/leave']!.single, {'deviceId': herDevice});
      });
    });

    test('a config refresh leaves her settings as they were', () {
      return recorded(() async {
        await seedBuild27();
        final box = Hive.box<dynamic>('setting');
        final before = {for (final k in box.keys) k: box.get(k)};
        final c = library();
        await c.enterLobby();
        await c.leaveLobby();
        for (final key in [
          'libraryServer',
          'libraryKey',
          'libraryDisplayName',
          'libraryMirrors',
          'libraryRoom',
          'syncPlayEndPoint',
          'librarySyncPlayEndPoint',
          'libraryDeviceId',
          'libraryRouteCheck',
        ]) {
          expect(box.get(key), before[key], reason: key);
        }
      });
    });

    test('streams and downloads try HK first, then the library server', () {
      return seedBuild27().then((_) {
        library();
        final url = '$librarySite/episodes/$episodeId/video.mp4?token=$viewKey';
        expect(MirrorRegistry.expand!(url), [
          '$hkSite/episodes/$episodeId/video.mp4?token=$viewKey',
          url,
        ]);
      });
    });

    test('HK still comes first if her route check never got stored', () async {
      await seedBuild27(routeCheck: false);
      expect(library().router.order.first.toString(), hkSite);
    });

    test('the stored route check is not run again', () async {
      await seedBuild27();
      final c = library();
      await recorded(() async {
        c.scheduleRouteCheckOnce();
        await Future.delayed(const Duration(seconds: 1));
      });
      expect(seen, isEmpty);
      expect(c.routeVersion.value, 0);
    });

    test('without a stored check it does run (so the test above can fail)', () {
      return recorded(() async {
        await seedBuild27(routeCheck: false);
        final c = library();
        c.scheduleRouteCheckOnce();
        // Waits for the check to finish, so it can't leak into later tests.
        await until(() => c.routeVersion.value > 0, 'the route check');
        expect(seen, isNotEmpty);
      });
    });
  });

  group('starting an episode from the lobby', () {
    test('joins her SyncPlay room under her name and shows her watching', () {
      return recorded(() async {
        await seedBuild27();
        final c = library();
        await c.refresh();
        final player = _FakePlayer();
        c.onEpisodeStarted(2, player, _noEpisodeChange);
        expect(player.rooms, [(room, herName)]);
        await until(
          () => (bodies['/api/room/heartbeat'] ?? []).any(
            (b) => b['state'] == 'watching',
          ),
          'a watching heartbeat',
        );
        expect(
          bodies['/api/room/heartbeat']!.firstWhere(
            (b) => b['state'] == 'watching',
          ),
          {
            'deviceId': herDevice,
            'name': herName,
            'state': 'watching',
            'episodeId': episodeId,
          },
        );

        seen.clear();
        c.onPlaybackClosed();
        await until(
          () => bodies['/api/room/leave'] != null,
          'leaving the room',
        );
        expect(urls(), contains('POST $hkSite/api/room/leave'));
      });
    });

    test('does not open a second room when already in one', () {
      return recorded(() async {
        await seedBuild27();
        final c = library();
        await c.refresh();
        final player = _FakePlayer()..alreadyInRoom = true;
        c.onEpisodeStarted(2, player, _noEpisodeChange);
        expect(player.rooms, isEmpty);
        c.onPlaybackClosed();
        await until(() => bodies['/api/room/leave'] != null, 'leaving');
      });
    });
  });

  group('SyncPlay with her saved settings', () {
    // A local socket stands in for hk:8999. Her two saved endpoints are
    // equal, which is what turns TLS on. Syncplay upgrades with STARTTLS: the
    // client asks in plain JSON, the server agrees, then the TLS handshake
    // starts. The bytes on the wire show what the real player code did.
    Future<({String firstLine, List<int> afterAgree})> talk({
      required bool asSaved,
    }) async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final endpoint = '127.0.0.1:${server.port}';
      final box = Hive.box<dynamic>('setting');
      await box.put('syncPlayEndPoint', endpoint);
      await box.put('librarySyncPlayEndPoint', asSaved ? endpoint : '');
      final firstLine = Completer<String>();
      final afterAgree = Completer<List<int>>();
      server.listen((socket) {
        final bytes = <int>[];
        var agreed = false;
        socket.listen((data) {
          if (agreed) {
            if (!afterAgree.isCompleted) afterAgree.complete(data);
            return;
          }
          bytes.addAll(data);
          final text = utf8.decode(bytes, allowMalformed: true);
          final end = text.indexOf('\n');
          if (end < 0 || firstLine.isCompleted) return;
          final line = text.substring(0, end).trim();
          firstLine.complete(line);
          if (line.contains('startTLS')) {
            agreed = true;
            final agree = jsonEncode({
              'TLS': {'startTLS': 'true'},
            });
            socket.write('$agree\r\n');
          }
        }, onError: (_) {});
      });
      final sync = _syncController();
      unawaited(sync.createRoom(room, herName, _noEpisodeChange));
      final line = await firstLine.future.timeout(const Duration(seconds: 10));
      final upgraded = line.contains('startTLS')
          ? await afterAgree.future.timeout(const Duration(seconds: 10))
          : <int>[];
      await sync.dispose();
      await server.close();
      return (firstLine: line, afterAgree: upgraded);
    }

    test('her saved endpoint upgrades to TLS before saying hello', () async {
      final r = await talk(asSaved: true);
      expect(jsonDecode(r.firstLine), {
        'TLS': {'startTLS': 'send'},
      });
      expect(
        r.afterAgree.first,
        0x16,
        reason: 'a TLS ClientHello starts with 0x16',
      );
    });

    test('an endpoint that is not the library one stays plain', () async {
      final r = await talk(asSaved: false);
      final hello = jsonDecode(r.firstLine) as Map<String, dynamic>;
      expect(hello.keys, ['Hello']);
      expect(hello['Hello']['username'], herName);
      expect(hello['Hello']['room']['name'], room);
    });

    test('her saved endpoint is hk.kaic5504.com:8999', () async {
      await seedBuild27();
      final parsed = parseSyncPlayEndPoint(
        GStorage.getSetting(SettingsKeys.syncPlayEndPoint),
      )!;
      expect(parsed.host, 'hk.kaic5504.com');
      expect(parsed.port, 8999);
    });
  });

  group('her update prompt', () {
    test('build 27 reads HK and is offered the newer build', () async {
      final update = TestflightUpdate(currentBuild: 27, isIOS: true);
      final release = await recorded(update.fetch);
      expect(urls(), ['GET $hkSite/app/latest.json']);
      expect(release!.build, 28);
      expect(
        updateNeedFor(release, 27, DateTime.utc(2026, 10, 9)),
        UpdateNeed.optional,
      );
    });

    test('the startup check in 我的 goes to the TestFlight checker', () async {
      final my = MyController(
        _FakeHistoryRepository(),
        _FakeRepository(),
        _FakeShieldRepository(),
      );
      expect(await recorded(() => my.checkUpdate(type: 'auto')), isTrue);
      expect(urls(), ['GET $hkSite/app/latest.json']);
    });

    Future<void> pumpApp(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootNavigatorKey,
        scaffoldMessengerKey: rootScaffoldMessengerKey,
        navigatorObservers: [KazumiDialog.observer],
        home: const Scaffold(body: Text('home')),
      ),
    );

    testWidgets('build 27 sees 有新版本, and 去更新 opens Kazumi in TestFlight', (
      tester,
    ) async {
      await pumpApp(tester);
      final launched = <Uri>[];
      final update = TestflightUpdate(
        launch: (uri) async {
          launched.add(uri);
          return true;
        },
        currentBuild: 27,
        isIOS: true,
      );
      addTearDown(update.dispose);
      await tester.runAsync(() => recorded(update.check));
      await tester.pumpAndSettle();
      expect(urls(), ['GET $hkSite/app/latest.json']);
      expect(find.text('有新版本 3.2.0 (28)'), findsOneWidget);
      expect(find.text('稍后'), findsOneWidget);

      await tester.tap(find.text('去更新'));
      await tester.pumpAndSettle();
      expect(launched, [TestflightUpdate.testflightUri]);
    });

    testWidgets('a required update gives build 27 no 稍后', (tester) async {
      latest = {
        'build': 28,
        'version': '3.2.0',
        'minBuild': 28,
        'requiredSince': DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 1))
            .toIso8601String(),
        'notes': '',
      };
      await pumpApp(tester);
      final update = TestflightUpdate(
        launch: (_) async => true,
        currentBuild: 27,
        isIOS: true,
      );
      addTearDown(update.dispose);
      await tester.runAsync(() => recorded(update.check));
      await tester.pumpAndSettle();
      expect(update.shownNeed, UpdateNeed.required);
      expect(find.text('去更新'), findsOneWidget);
      expect(find.text('稍后'), findsNothing);
    });

    testWidgets('build 28 itself is not prompted', (tester) async {
      await pumpApp(tester);
      final update = TestflightUpdate(currentBuild: 28, isIOS: true);
      addTearDown(update.dispose);
      await tester.runAsync(() => recorded(update.check));
      await tester.pumpAndSettle();
      expect(update.shownNeed, UpdateNeed.none);
      expect(find.text('去更新'), findsNothing);
    });

    testWidgets('coming back after 30 min checks again, sooner does not', (
      tester,
    ) async {
      var now = DateTime.utc(2026, 10, 9, 12);
      var fetches = 0;
      final update = TestflightUpdate(
        fetchLatest: () async {
          fetches++;
          return jsonEncode({'build': 27, 'version': '3.1.0', 'notes': ''});
        },
        clock: () => now,
        currentBuild: 27,
        isIOS: true,
      );
      addTearDown(update.dispose);
      await tester.runAsync(update.check);
      expect(fetches, 1);

      // iOS walks through each state on the way out and back in.
      Future<void> backgroundFor(Duration away) async {
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        now = now.add(away);
        for (final state in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        await tester.runAsync(() => Future.delayed(Duration.zero));
        await tester.pump();
      }

      await backgroundFor(const Duration(minutes: 10));
      expect(fetches, 1);
      await backgroundFor(const Duration(minutes: 31));
      expect(fetches, 2);
    });
  });

  group('rules in China', () {
    late List<Uri> requested;

    setUp(() {
      requested = [];
      DioFactory.rulesRepoDio.httpClientAdapter = _RecordingAdapter(requested);
    });
    tearDown(DioFactory.reset);

    test('the rule catalog is fetched from the HK mirror', () async {
      await PluginCatalogApi.getPluginList();
      expect(requested.single.toString(), '$hkSite/rules/index.json');
    });

    test('each rule file is fetched from the HK mirror too', () async {
      try {
        await PluginCatalogApi.getPlugin('AGE');
      } catch (_) {
        // The fake answers with an empty list, not a rule; only the URL matters.
      }
      expect(requested.single.toString(), '$hkSite/rules/AGE.json');
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
        expect(find.text('一起看'), findsOneWidget);
        await tester.tap(find.text('一起看'));
        expect(opened, MyDestination.together);
      });
    }
  });

  group('episode grid on the video page', () {
    Future<List<(int, int)>> pumpPanel(
      WidgetTester tester, {
      required int episodes,
      int selected = 1,
    }) async {
      tester.view.physicalSize = const Size(440, 956);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final picked = <(int, int)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EpisodeSelectionPanel(
              title: 'Fate/Zero',
              roads: [
                Road(
                  name: '播放列表1',
                  data: [for (var i = 1; i <= episodes; i++) 'ep$i'],
                  identifier: const [],
                ),
              ],
              selectedRoad: 0,
              selectedEpisode: selected,
              onEpisodeSelected: (episode, road) => picked.add((episode, road)),
              downloads: const {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return picked;
    }

    testWidgets('a 13 episode cour fits on her iPhone, three to a row', (
      tester,
    ) async {
      await pumpPanel(tester, episodes: 13);
      for (var i = 1; i <= 13; i++) {
        expect(find.text('第$i集').hitTestable(), findsOneWidget);
      }
      final second = tester.getTopLeft(find.text('第2集'));
      expect(tester.getTopLeft(find.text('第3集')).dy, second.dy);
      expect(tester.getTopLeft(find.text('第5集')).dy, greaterThan(second.dy));
    });

    testWidgets('tapping an episode plays it on that road', (tester) async {
      final picked = await pumpPanel(tester, episodes: 13);
      await tester.tap(find.text('第5集'));
      expect(picked, [(5, 0)]);
    });

    testWidgets('定位当前集 brings a far episode into view', (tester) async {
      await pumpPanel(tester, episodes: 120, selected: 100);
      expect(find.text('第100集').hitTestable(), findsNothing);
      await tester.tap(find.byTooltip('定位当前集'));
      await tester.pumpAndSettle();
      expect(find.text('第100集').hitTestable(), findsOneWidget);
    });
  });
}

Map<String, dynamic> _episodeJson() => {
  'id': episodeId,
  'version': 1,
  'bangumiId': bangumiId,
  'pluginName': 'aafun',
  'bangumiName': 'Fate/Zero',
  'episodeNumber': 2,
  'watchedBy': [herName],
};

PlayerSyncPlayController _syncController() => PlayerSyncPlayController(
  bangumiId: () => bangumiId,
  currentEpisode: () => 2,
  currentRoad: () => 0,
  playing: () => false,
  currentPosition: () => Duration.zero,
  playerPosition: () => Duration.zero,
  duration: () => const Duration(minutes: 24),
  completed: () => false,
  pause: ({enableSync = true}) async {},
  play: ({enableSync = true}) async {},
  seek: (_, {enableSync = true}) async {},
  setRateFactor: (_) async {},
  clock: DateTime.now,
);

class _FakePlayer implements PlayerController {
  final rooms = <(String, String)>[];
  bool alreadyInRoom = false;
  late final PlayerSyncPlayController _sync = _syncController();

  @override
  int get bangumiId => 10639;

  @override
  PlayerSyncPlayController get syncplay =>
      alreadyInRoom ? _InRoomSync() : _sync;

  @override
  Future<void> createSyncPlayRoom(
    String room,
    String username,
    EpisodeChanger changeEpisode,
  ) async {
    rooms.add((room, username));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _InRoomSync implements PlayerSyncPlayController {
  @override
  bool get inRoom => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Recorder extends HttpOverrides {
  _Recorder(this.seen, this.target);

  final List<Seen> seen;
  final Uri target;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _RoutingClient(super.createHttpClient(context), seen, target);
}

class _RoutingClient implements HttpClient {
  _RoutingClient(this._real, this._seen, this._target);

  final HttpClient _real;
  final List<Seen> _seen;
  final Uri _target;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    _seen.add(Seen(method, url));
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
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);

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
  List<DownloadRecord> getAllRecords() => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeDownloadManager implements IDownloadManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHistoryRepository implements IHistoryRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeShieldRepository implements IDanmakuShieldRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

Future<void> _noEpisodeChange(
  int episode, {
  int currentRoad = 0,
  int offset = 0,
}) async {}

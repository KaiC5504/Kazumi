import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/download/mirror_selector.dart';
import 'package:kazumi/services/download/parted_transfer.dart';
import 'package:kazumi/services/library/library_api.dart';
import 'package:kazumi/services/library/library_controller.dart';
import 'package:kazumi/services/library/library_invite.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/upscale/upscale_controller.dart';
import 'package:kazumi/services/upscale/upscaled_package.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  group('LibraryInvite.parse', () {
    test('reads the app link', () {
      final invite = LibraryInvite.parse(
        'kazumi-library://join?server=https%3A%2F%2Fkazumi.example.com&key=abc%2B1',
      );
      expect(invite?.server, 'https://kazumi.example.com');
      expect(invite?.key, 'abc+1');
    });

    test('reads a pasted web invite inside a chat message', () {
      final invite = LibraryInvite.parse(
        '来一起看 https://kazumi.example.com/join#k=secret-key 点这里',
      );
      expect(invite?.server, 'https://kazumi.example.com');
      expect(invite?.key, 'secret-key');
    });

    test('rejects links without a key or with a non-http server', () {
      expect(LibraryInvite.parse('https://kazumi.example.com/join'), isNull);
      expect(
        LibraryInvite.parse('kazumi-library://join?server=ftp://x&key=k'),
        isNull,
      );
      expect(LibraryInvite.parse('kazumi://abcdef'), isNull);
    });

    test('web link round-trips', () {
      const invite = LibraryInvite(server: 'https://a.example', key: 'k/1');
      final parsed = LibraryInvite.parse(invite.webLink);
      expect(parsed?.server, invite.server);
      expect(parsed?.key, invite.key);
    });
  });

  test('invite codes are typed loosely', () {
    expect(normalizeInviteCode(' kz7m-4qpa '), 'KZ7M4QPA');
    expect(normalizeInviteCode('KZ7M 4QPA'), 'KZ7M4QPA');
    expect(normalizeInviteCode('KZ7M-4QP'), isNull);
  });

  group('LibraryApi', () {
    test('normalizes the server and puts the key on file urls', () {
      final api = LibraryApi('kazumi.example.com/join?x=1#k', 'k 1');
      expect(api.baseUri.toString(), 'https://kazumi.example.com');
      final video = api.videoUri('abc');
      expect(video.path, '/episodes/abc/video.mp4');
      expect(video.queryParameters['token'], 'k 1');
      expect(api.ownsUrl(video.toString()), isTrue);
      expect(api.ownsUrl('http://192.168.1.2:38520/episodes/abc'), isFalse);

      final relay = api.videoUri('abc', via: Uri.parse('https://hk.example.com'));
      expect(relay.toString(),
          'https://hk.example.com/episodes/abc/video.mp4?token=k+1');
      expect(api.ownsUrl(relay.toString()), isTrue,
          reason: 'downloads through a relay are still cleaned up');
      expect(
          api.ownsUrl('https://hk.example.com/episodes/abc/video.mp4?token=x'),
          isFalse);
    });

    test('room state tolerates missing fields', () {
      final state = LibraryRoomState.fromJson({
        'members': [
          {
            'deviceId': 'd1',
            'name': 'A',
            'state': 'watching',
            'episodeId': 'e',
          },
        ],
        'selection': {'seq': 3, 'episodeId': 'e', 'by': 'A'},
      });
      expect(state.members.single.watching, isTrue);
      expect(state.selection?.seq, 3);
      expect(state.selection?.byDeviceId, '');
    });
  });

  // The resumable upload only retries a LibraryException; anything else
  // aborts the whole upload instead of resuming it.
  group('LibraryApi.upload reports a dropped upload as LibraryException', () {
    late Directory tmp;
    late File source;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('kazumi_upload_test');
      source = File('${tmp.path}/video.mp4')..writeAsBytesSync([1, 2, 3]);
    });
    tearDown(() => tmp.delete(recursive: true));

    test('when the server never answers', () async {
      final stalled = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      stalled.listen((request) => request.drain<void>());
      addTearDown(() => stalled.close(force: true));
      final api = LibraryApi(
        'http://127.0.0.1:${stalled.port}',
        'k',
        responseTimeout: const Duration(milliseconds: 300),
      );
      await expectLater(
        api.upload('id', upscaledVideoFileName, source, offset: 0),
        throwsA(isA<LibraryException>()),
      );
    });

    test('when the TLS handshake fails', () async {
      final plain = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      plain.listen((socket) {
        socket.listen(
          (_) => socket.write('HTTP/1.1 400 Bad Request\r\n\r\n'),
          onError: (_) {},
        );
      });
      addTearDown(plain.close);
      final api = LibraryApi('https://127.0.0.1:${plain.port}', 'k');
      await expectLater(
        api.upload('id', upscaledVideoFileName, source, offset: 0),
        throwsA(isA<LibraryException>()),
      );
    });
  });

  group('LibraryController', () {
    late Directory hive;
    late HttpServer server;
    var listed = <Map<String, dynamic>>[];

    Map<String, dynamic> episode(int bangumiId) => {
      'id': 'ep-$bangumiId',
      'version': 1,
      'bangumiId': bangumiId,
      'pluginName': 'p',
      'bangumiName': 'B$bangumiId',
      'episodeNumber': 1,
    };

    setUpAll(() async {
      hive = await Directory.systemTemp.createTemp('kazumi_library_hive');
      PathProviderPlatform.instance = _TestPaths(hive.path);
      Hive.init(hive.path);
      await GStorage.init();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await request.drain<void>();
        request.response.write(
          jsonEncode(
            request.uri.path == '/api/episodes' ? {'episodes': listed} : {},
          ),
        );
        await request.response.close();
      });
      await GStorage.putSetting<String>(
        SettingsKeys.libraryServer,
        'http://127.0.0.1:${server.port}',
      );
      await GStorage.putSetting<String>(SettingsKeys.libraryKey, 'k');
      await GStorage.putSetting<String>(SettingsKeys.libraryDisplayName, 'me');
      await GStorage.putSetting<bool>(SettingsKeys.libraryWifiOnly, false);
    });
    tearDownAll(() async {
      await server.close(force: true);
      await Hive.close();
      await hive.delete(recursive: true);
    });
    tearDown(MirrorRegistry.reset);

    test('a refresh during a lobby prefetch does not stop it', () async {
      final downloads = _FakeDownloads();
      final manager = _FakeManager(hive.path);
      final c = LibraryController(_FakeRepository(), downloads, manager);
      listed = [episode(1), episode(2)];
      await c.refresh();

      final prefetch = c.prefetchFromLobby();
      await manager.firstAsked.future;
      listed = [episode(1), episode(2), episode(3)];
      await c.refresh();
      expect(c.episodes, hasLength(3));
      manager.release.complete();

      await prefetch;
      expect(downloads.queued, containsAll([1, 2]));
    });
  });

  // Runs against a real server when KAZUMI_LIBRARY_TEST_URL, _VIEW_KEY and
  // _ADMIN_KEY are set, e.g. `uv run uvicorn` from server/.
  final env = Platform.environment;
  final url = env['KAZUMI_LIBRARY_TEST_URL'];
  group('LibraryApi against a live server', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('kazumi_library_test');
    });
    tearDown(() => tmp.delete(recursive: true));

    test(
      'upload resumes, commits, lists, streams and syncs the room',
      () async {
        final admin = LibraryApi(url!, env['KAZUMI_LIBRARY_TEST_ADMIN_KEY']!);
        final viewer = LibraryApi(url, env['KAZUMI_LIBRARY_TEST_VIEW_KEY']!);
        const manifest = UpscaledEpisodeManifest(
          bangumiId: 10639,
          pluginName: 'aafun',
          bangumiName: 'Fate/Zero',
          bangumiCover: '',
          episodeNumber: 2,
          episodeName: '第02集',
          road: 0,
          episodePageUrl: '',
          danDanBangumiID: 0,
          tier: 'quality',
          width: 0,
          height: 1440,
          sizeBytes: 3 * 1024 * 1024,
          hasDanmaku: false,
        );
        final bytes = List<int>.generate(manifest.sizeBytes, (i) => i % 251);
        final full = File('${tmp.path}/video.mp4')..writeAsBytesSync(bytes);
        final half = File('${tmp.path}/half.mp4')
          ..writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
        final id = manifest.shareId;

        await expectLater(
          admin.commit(id, manifest),
          throwsA(isA<LibraryException>()),
        );

        // A dropped upload leaves half the file; the retry resumes from it.
        await admin.upload(id, upscaledVideoFileName, half, offset: 0);
        final offset = await admin.uploadedSize(id, upscaledVideoFileName);
        expect(offset, bytes.length ~/ 2);
        await admin.upload(id, upscaledVideoFileName, full, offset: offset);
        await admin.commit(id, manifest);

        final episodes = await viewer.episodes();
        final listed = episodes.singleWhere((e) => e.id == id);
        expect(listed.manifest.episodeNumber, 2);
        expect(listed.manifest.recordKey, 'aafun_10639');

        final downloaded = await viewer.download(viewer.videoUri(id));
        expect(downloaded, bytes);

        await expectLater(
          viewer.uploadedSize(id, upscaledVideoFileName),
          throwsA(
            isA<LibraryException>().having(
              (e) => e.statusCode,
              'statusCode',
              401,
            ),
          ),
          reason: 'the view key must not upload',
        );

        final invite = await admin.createInvite();
        expect(
          await LibraryApi.redeem(url, invite.code.toLowerCase()),
          env['KAZUMI_LIBRARY_TEST_VIEW_KEY'],
        );
        await expectLater(
          LibraryApi.redeem(url, 'AAAA-AAAA'),
          throwsA(
            isA<LibraryException>().having(
              (e) => e.message,
              'message',
              contains('邀请码'),
            ),
          ),
        );

        final config = await viewer.config();
        expect(config.room, isNotEmpty);
        expect(config.mirrors, env['KAZUMI_LIBRARY_TEST_MIRRORS']?.split(',') ?? []);

        final sample = await LibraryApi.probe(viewer.videoUri(id), bytes: 1024);
        expect(sample, isNotNull);
        expect(
          await LibraryApi.probe(
              viewer.videoUri(id, via: Uri.parse('http://127.0.0.1:1'))),
          isNull,
        );

        await viewer.heartbeat(deviceId: 'phone', name: '她', state: 'lobby');
        final picked = await viewer.select(
          deviceId: 'ipad',
          name: 'KaiC',
          episodeId: id,
        );
        expect(picked.selection?.episodeId, id);
        expect(picked.selection?.byDeviceId, 'ipad');
        expect(picked.members.map((m) => m.deviceId), contains('phone'));

        await viewer.markWatched(id, '她');
        expect(
          (await viewer.episodes()).where((e) => e.id == id),
          isNotEmpty,
          reason: 'KaiC picked it, so he counts and has not watched yet',
        );
        await viewer.markWatched(id, 'KaiC');
        final after = await viewer.episodes();
        expect(
          after.where((e) => e.id == id),
          isEmpty,
          reason: 'everyone active has watched it, so the server drops it',
        );
      },
    );

    test('uploads and downloads in parts over several connections', () async {
      final admin = LibraryApi(url!, env['KAZUMI_LIBRARY_TEST_ADMIN_KEY']!);
      final viewer = LibraryApi(url, env['KAZUMI_LIBRARY_TEST_VIEW_KEY']!);
      const partSize = 256 * 1024;
      const manifest = UpscaledEpisodeManifest(
        bangumiId: 27364,
        pluginName: 'parts',
        bangumiName: '冰菓',
        bangumiCover: '',
        episodeNumber: 3,
        episodeName: '第03集',
        road: 0,
        episodePageUrl: '',
        danDanBangumiID: 0,
        tier: 'quality',
        width: 0,
        height: 1440,
        sizeBytes: 3 * 1024 * 1024 + 123,
        hasDanmaku: false,
      );
      final bytes = List<int>.generate(manifest.sizeBytes, (i) => i * 7 % 253);
      final video = File('${tmp.path}/video.mp4')..writeAsBytesSync(bytes);
      final id = manifest.shareId;

      // Parts from an earlier, interrupted run are kept and not sent again.
      for (final index in [0, 5]) {
        await admin.uploadPart(id, upscaledVideoFileName, video,
            index: index,
            start: index * partSize,
            end: (index + 1) * partSize);
      }
      final before = await admin.uploadedParts(id, upscaledVideoFileName);
      expect(before, {0: partSize, 5: partSize});

      final progress = <int>[];
      await UpscaleController.uploadInParts(
        admin,
        id,
        upscaledVideoFileName,
        video,
        partSize: partSize,
        onProgress: progress.add,
      );
      expect(progress.first, 2 * partSize);
      expect(progress.last, bytes.length);
      await admin.commit(id, manifest);

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final target = File('${tmp.path}/download.mp4.tmp');
      final ok = await downloadInParts(
        tmpFile: target,
        partsLog: File('${tmp.path}/download.mp4.parts'),
        totalSize: bytes.length,
        partSize: partSize,
        stopped: () => false,
        openRange: (start, end) async {
          final request = await client.getUrl(viewer.videoUri(id));
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-${end - 1}');
          final response = await request.close();
          expect(response.statusCode, HttpStatus.partialContent);
          return response;
        },
      );
      expect(ok, isTrue);
      expect(await target.readAsBytes(), bytes);

      await expectLater(
        viewer.uploadedParts(id, upscaledVideoFileName),
        throwsA(isA<LibraryException>()
            .having((e) => e.statusCode, 'statusCode', 401)),
        reason: 'the view key must not upload',
      );
    });

    test('a cancelled upload stops, keeps its parts and resumes', () async {
      final admin = LibraryApi(url!, env['KAZUMI_LIBRARY_TEST_ADMIN_KEY']!);
      const partSize = 64 * 1024;
      const manifest = UpscaledEpisodeManifest(
        bangumiId: 27364,
        pluginName: 'cancel',
        bangumiName: '冰菓',
        bangumiCover: '',
        episodeNumber: 8,
        episodeName: '第08集',
        road: 0,
        episodePageUrl: '',
        danDanBangumiID: 0,
        tier: 'quality',
        width: 0,
        height: 1440,
        sizeBytes: 64 * partSize,
        hasDanmaku: false,
      );
      final bytes = List<int>.generate(manifest.sizeBytes, (i) => i % 241);
      final video = File('${tmp.path}/video.mp4')..writeAsBytesSync(bytes);
      final id = manifest.shareId;

      final cancel = Completer<void>();
      var sent = 0;
      await expectLater(
        UpscaleController.uploadInParts(
          admin,
          id,
          upscaledVideoFileName,
          video,
          partSize: partSize,
          cancel: cancel,
          onProgress: (n) {
            sent = n;
            // Progress counts bytes not yet acknowledged, and a whole wave
            // of parts can be in flight; past that, 8 parts are on the server.
            if (n >= (transferConnections + 8) * partSize &&
                !cancel.isCompleted) {
              cancel.complete();
            }
          },
        ),
        throwsA(isA<UploadCancelled>()),
      );
      final kept = await admin.uploadedParts(id, upscaledVideoFileName);
      expect(kept, isNotEmpty);
      expect(kept!.length, lessThan(64), reason: 'it stopped early');
      expect(sent, lessThan(bytes.length));

      final progress = <int>[];
      await UpscaleController.uploadInParts(
        admin,
        id,
        upscaledVideoFileName,
        video,
        partSize: partSize,
        onProgress: progress.add,
      );
      expect(progress.first, greaterThanOrEqualTo(kept.length * partSize));
      await admin.commit(id, manifest);
      final viewer = LibraryApi(url, env['KAZUMI_LIBRARY_TEST_VIEW_KEY']!);
      expect(await viewer.download(viewer.videoUri(id)), bytes);
      expect((await admin.episodes()).map((e) => e.id), contains(id),
          reason: 'the admin key can list the library too');
    });
  }, skip: url == null ? 'KAZUMI_LIBRARY_TEST_URL not set' : false);
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _FakeRepository implements IDownloadRepository {
  @override
  DownloadRecord? getRecord(String key) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeDownloads implements DownloadController {
  final queued = <int>[];

  @override
  Future<void> enqueuePreUpscaled(
    DownloadRecord record,
    DownloadEpisode episode,
  ) async => queued.add(record.bangumiId);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Holds the first download until [release] completes.
class _FakeManager implements IDownloadManager {
  _FakeManager(this.dir);

  final String dir;
  final firstAsked = Completer<void>();
  final release = Completer<void>();

  @override
  Future<String> episodeDirectoryFor(
    int bangumiId,
    String pluginName,
    int episodeNumber,
  ) async {
    if (!firstAsked.isCompleted) {
      firstAsked.complete();
      await release.future;
    }
    return '$dir/$bangumiId/$episodeNumber';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

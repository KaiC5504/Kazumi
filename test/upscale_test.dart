import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/services/skip/skip_segments.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/upscale/lan_share.dart';
import 'package:kazumi/services/upscale/upscale_baker.dart';
import 'package:kazumi/services/upscale/upscale_controller.dart';
import 'package:kazumi/services/upscale/upscaled_package.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

UpscaledEpisodeManifest _manifest({
  int episode = 3,
  int size = 10,
  SkipSegments skip = SkipSegments.empty,
}) => UpscaledEpisodeManifest(
  bangumiId: 42,
  pluginName: 'demo',
  bangumiName: '测试/番剧: 第二季?',
  bangumiCover: 'https://example.com/c.jpg',
  episodeNumber: episode,
  episodeName: '',
  road: 1,
  episodePageUrl: '/play/42-1-3',
  danDanBangumiID: 7,
  tier: 'quality',
  width: 0,
  height: 1440,
  sizeBytes: size,
  hasDanmaku: true,
  skipSegments: skip,
);

void main() {
  group('UpscaledEpisodeManifest', () {
    test('round-trips through json', () {
      final original = _manifest();
      final decoded = UpscaledEpisodeManifest.decode(original.encode());
      expect(decoded.toJson(), original.toJson());
      expect(decoded.recordKey, 'demo_42');
      expect(decoded.displayEpisodeName, '第3集');
    });

    test('rejects manifests from a newer format', () {
      final json = _manifest().toJson()..['version'] = 99;
      expect(
        () => UpscaledEpisodeManifest.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects names that would save outside its folder', () {
      for (final bad in <String, Object>{
        'pluginName': r'x\..\..\Documents',
        'pluginName ': 'x/../../Documents',
        'pluginName  ': '..',
        'pluginName   ': '',
        'pluginName    ': 'C:',
        'bangumiId': -1,
        'episodeNumber': -3,
      }.entries) {
        final json = _manifest().toJson()..[bad.key.trim()] = bad.value;
        expect(
          () => UpscaledEpisodeManifest.fromJson(json),
          throwsA(isA<FormatException>()),
          reason: '${bad.key.trim()} = ${bad.value}',
        );
      }
      for (final good in ['欧乐影院', 'AGE', '7sefun', 'girigiri love']) {
        final json = _manifest().toJson()..['pluginName'] = good;
        expect(UpscaledEpisodeManifest.fromJson(json).pluginName, good);
      }
    });

    test('builds a pre-upscaled download episode', () {
      final (record, episode) = _manifest().toDownloadEntities();
      expect(record.key, 'demo_42');
      expect(episode.preUpscaled, isTrue);
      expect(episode.danDanBangumiID, 7);
      expect(episode.status, DownloadStatus.pending);
    });

    test('share ids are url safe and distinct per episode', () {
      final a = _manifest(episode: 1).shareId;
      final b = _manifest(episode: 2).shareId;
      expect(a, isNot(b));
      expect(Uri.encodeComponent(a), a);
    });

    test('share ids parse back to the episode they name', () {
      for (final (key, episode) in [
        ('demo_42', 3),
        ('demo_42', 12),
        ('a|b_7', 1),
        ('欧乐影院_9', 100),
      ]) {
        final id = UpscaledEpisodeManifest.shareIdFor(key, episode);
        expect(UpscaledEpisodeManifest.parseShareId(id), (key, episode));
      }
      final padded = '${UpscaledEpisodeManifest.shareIdFor('demo_42', 12)}==';
      for (final bad in ['', 'x', '!!', '%2F', padded, 'ZGVtbw']) {
        expect(UpscaledEpisodeManifest.parseShareId(bad), isNull, reason: bad);
      }
    });

    test('export folder names drop characters Windows and iOS reject', () {
      expect(upscaledExportDirName(_manifest()), '测试_番剧_ 第二季_ - 第3集');
    });
  });

  group('LanShare', () {
    late Directory tmp;
    late LanShareServer server;
    late File video;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('kazumi_lan_');
      video = File(path.join(tmp.path, 'video.mp4'));
      await video.writeAsBytes(List.generate(1000, (i) => i % 256));
      final shared = UpscaledEpisodeFiles(
        manifest: _manifest(size: 1000),
        videoPath: video.path,
      );
      server = LanShareServer(
        () => [shared],
        (id) => id == shared.manifest.shareId ? shared : null,
      );
      await server.start('123456', port: 0);
    });

    tearDown(() async {
      await server.stop();
      await tmp.delete(recursive: true);
    });

    test('lists episodes for the right code only', () async {
      final ok = LanShareClient('127.0.0.1:${server.port}', '123456');
      final episodes = await ok.listEpisodes();
      expect(episodes.single.episodeNumber, 3);

      final wrong = LanShareClient('127.0.0.1:${server.port}', '000000');
      expect(wrong.listEpisodes(), throwsA(isA<LanShareException>()));
    });

    test('serves byte ranges so transfers can resume', () async {
      final client = LanShareClient('127.0.0.1:${server.port}', '123456');
      final http = HttpClient();
      final request = await http.getUrl(client.videoUri(_manifest()));
      request.headers.set(lanShareTokenHeader, '123456');
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=900-');
      final response = await request.close();
      final body = await response.fold<List<int>>([], (a, b) => a..addAll(b));
      http.close();

      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 900-999/1000',
      );
      expect(body.length, 100);
      expect(body.first, 900 % 256);
    });

    test('missing danmaku is a 404, not a crash', () async {
      final client = LanShareClient('127.0.0.1:${server.port}', '123456');
      expect(
        client.download(client.danmakuUri(_manifest())),
        throwsA(isA<LanShareException>()),
      );
    });
  });

  group('UpscaleBaker', () {
    test('bakes the quality chain into HEVC', () async {
      final (ffmpeg, _) = await UpscaleBaker.detect('');
      if (ffmpeg == null) {
        markTestSkipped('ffmpeg with libplacebo not installed');
        return;
      }
      final tmp = await Directory.systemTemp.createTemp('kazumi_bake_');
      addTearDown(() => tmp.delete(recursive: true));
      final shadersDir = Directory(path.join(tmp.path, 'shaders'))
        ..createSync();
      for (final f in Directory(
        'assets/shaders',
      ).listSync().whereType<File>()) {
        f.copySync(path.join(shadersDir.path, path.basename(f.path)));
      }
      final source = path.join(tmp.path, 'src.mp4');
      final gen = await Process.run(ffmpeg.executable, [
        '-hide_banner',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=s=640x360:r=24:d=2',
        '-f',
        'lavfi',
        '-i',
        'sine=d=2',
        '-c:v',
        'libx264',
        '-c:a',
        'aac',
        '-shortest',
        source,
      ]);
      expect(gen.exitCode, 0, reason: gen.stderr.toString());

      final progress = <double>[];
      final output = path.join(tmp.path, 'out', 'video.mp4');
      await UpscaleBaker().bake(
        ffmpeg: ffmpeg,
        input: source,
        output: output,
        shaderPath: await UpscaleBaker.buildCombinedShader(shadersDir.path),
        targetHeight: 720,
        onProgress: progress.add,
      );

      expect(File(output).existsSync(), isTrue);
      expect(File('$output.tmp.mp4').existsSync(), isFalse);
      expect(progress.last, 1.0);
      final probe = await Process.run(ffmpeg.executable, [
        '-hide_banner',
        '-i',
        output,
      ]);
      expect(probe.stderr as String, contains('hevc'));
      expect(probe.stderr as String, contains('1280x720'));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('UpscaleController', () {
    late Directory home;
    late PathProviderPlatform originalPaths;

    setUpAll(() async {
      Logger.level = Level.off;
      home = await Directory.systemTemp.createTemp('kazumi_upscale_ctl_');
      originalPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TestPaths(home.path);
      Hive.init(home.path);
      await GStorage.init();
    });

    tearDownAll(() async {
      await Hive.close();
      PathProviderPlatform.instance = originalPaths;
      await home.delete(recursive: true);
    });

    UpscaleController controllerWith([
      List<DownloadRecord> records = const [],
      _FakeRepository? repository,
    ]) => UpscaleController(
      repository ?? _FakeRepository(records),
      _FakeDownloadManager(),
      DownloadController(
        _FakeRepository(records),
        DownloadManager(),
        PluginsController(),
      ),
      ShaderAssetService(),
    );

    test('an offered episode is compared with the copy already here', () async {
      final dir = await Directory.systemTemp.createTemp('kazumi_import_');
      addTearDown(() => dir.delete(recursive: true));
      const skip = SkipSegments(
        opening: SkipRange(80, 170, SkipSource.fingerprint),
      );
      final video = File(path.join(dir.path, 'video.mp4'))
        ..writeAsBytesSync(List.filled(10, 0));
      final (record, imported) = _manifest(episode: 3).toDownloadEntities();
      imported
        ..status = DownloadStatus.completed
        ..localM3u8Path = video.path
        ..skipSegments = skip.encode();
      final (_, original) = _manifest(episode: 4).toDownloadEntities();
      original
        ..preUpscaled = false
        ..status = DownloadStatus.completed
        ..localM3u8Path = video.path;
      record.episodes
        ..[3] = imported
        ..[4] = original;
      final controller = controllerWith([record]);

      UpscaledImportState stateOf({
        required int episode,
        int size = 10,
        SkipSegments skip = skip,
      }) => controller.importState(
        _manifest(episode: episode, size: size, skip: skip),
      );
      expect(stateOf(episode: 3), UpscaledImportState.upToDate);
      expect(
        stateOf(episode: 3, skip: SkipSegments.empty),
        UpscaledImportState.skipTimesOnly,
      );
      expect(stateOf(episode: 3, size: 11), UpscaledImportState.replaces);
      expect(stateOf(episode: 4), UpscaledImportState.replaces);
      expect(stateOf(episode: 5), UpscaledImportState.fresh);
      imported.status = DownloadStatus.downloading;
      expect(stateOf(episode: 3), UpscaledImportState.replaces);
    });

    test('launch drops originals kept by older builds', () async {
      final root = await Directory.systemTemp.createTemp('kazumi_drop_');
      addTearDown(() => root.delete(recursive: true));
      String episodeDir(int n) =>
          path.join(root.path, '${_manifest().bangumiId}_plugin', '$n');
      File write(int n, String name, String content) =>
          File(path.join(episodeDir(n), name))
            ..createSync(recursive: true)
            ..writeAsStringSync(content);

      final (record, kept) = _manifest(episode: 1).toDownloadEntities();
      final (_, lost) = _manifest(episode: 2).toDownloadEntities();
      final original = write(1, 'video.mp4', 'original');
      final bake = write(1, path.join('upscaled', 'video.mp4'), 'baked');
      kept
        ..preUpscaled = false
        ..status = DownloadStatus.completed
        ..downloadDirectory = episodeDir(1)
        ..localM3u8Path = original.path
        ..upscaleStatus = UpscaleStatus.done
        ..upscaledVideoPath = bake.path;
      final gone = path.join(episodeDir(2), 'upscaled', 'video.mp4');
      lost
        ..preUpscaled = false
        ..status = DownloadStatus.completed
        ..downloadDirectory = episodeDir(2)
        ..localM3u8Path = gone
        ..upscaleStatus = UpscaleStatus.done
        ..upscaledVideoPath = gone;
      record.episodes
        ..[1] = kept
        ..[2] = lost;
      final repository = _FakeRepository([record]);

      await controllerWith(const [], repository).init();
      for (var i = 0; i < 100 && repository.puts < 2; i++) {
        await Future.delayed(const Duration(milliseconds: 10));
      }

      expect(original.existsSync(), isFalse);
      expect(kept.localM3u8Path, bake.path);
      expect(kept.totalBytes, 'baked'.length);
      expect(kept.playsUpscaled, isTrue);
      expect(lost.status, DownloadStatus.failed);
      expect(lost.upscaleStatus, UpscaleStatus.none);
      expect(repository.puts, 2);
    });

    test('LAN share finds an episode by id as the listing has it', () async {
      final dir = await Directory.systemTemp.createTemp('kazumi_share_');
      addTearDown(() => dir.delete(recursive: true));
      final (record, baked) = _manifest(episode: 3).toDownloadEntities();
      final (_, notBaked) = _manifest(episode: 4).toDownloadEntities();
      final video = File(path.join(dir.path, 'video.mp4'))
        ..writeAsBytesSync(List.filled(64, 1));
      baked
        ..downloadDirectory = dir.path
        ..upscaleStatus = UpscaleStatus.done
        ..upscaledVideoPath = video.path
        ..upscaledHeight = 1440;
      record.episodes
        ..[3] = baked
        ..[4] = notBaked;
      final controller = controllerWith([record]);

      final listed = controller.sharedEpisodes().single;
      final found = controller.sharedEpisode(listed.manifest.shareId);
      expect(found?.manifest.toJson(), listed.manifest.toJson());
      expect(found?.videoPath, video.path);
      expect(found?.danmakuPath, isNull);
      expect(found?.manifest.toJson()['width'], 0);

      for (final id in [
        UpscaledEpisodeManifest.shareIdFor(record.key, 4),
        UpscaledEpisodeManifest.shareIdFor('other_1', 3),
        'not base64!',
      ]) {
        expect(controller.sharedEpisode(id), isNull, reason: id);
      }
    });

    test(
      'a library refresh that failed to start does not block the next',
      () async {
        var requests = 0;
        final library = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => library.close(force: true));
        library.listen((request) async {
          requests++;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'episodes': [
                {..._manifest().toJson(), 'id': 'ep3'},
              ],
            }),
          );
          await request.response.close();
        });
        final controller = controllerWith();

        await GStorage.putSetting(SettingsKeys.libraryAdminKey, 'admin');
        // The port doesn't parse, so LibraryApi throws before its first await.
        await GStorage.putSetting(SettingsKeys.libraryServer, 'library:abc');
        await controller.refreshLibrary();
        expect(controller.libraryIds, isEmpty);

        await GStorage.putSetting(
          SettingsKeys.libraryServer,
          'http://127.0.0.1:${library.port}',
        );
        await controller.refreshLibrary();
        expect(requests, 1);
        expect(controller.libraryIds, {'ep3'});
      },
    );
  });
}

class _FakeRepository implements IDownloadRepository {
  _FakeRepository([this.records = const []]);

  final List<DownloadRecord> records;

  @override
  List<DownloadRecord> getAllRecords() => records;

  @override
  DownloadRecord? getRecord(String key) =>
      records.where((r) => r.key == key).firstOrNull;

  @override
  DownloadEpisode? getEpisode(
    int bangumiId,
    String pluginName,
    int episodeNumber,
  ) => getRecord('${pluginName}_$bangumiId')?.episodes[episodeNumber];

  int puts = 0;

  @override
  Future<void> putRecord(DownloadRecord record) async => puts++;

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

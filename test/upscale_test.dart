import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/services/upscale/lan_share.dart';
import 'package:kazumi/services/upscale/upscale_baker.dart';
import 'package:kazumi/services/upscale/upscaled_package.dart';
import 'package:path/path.dart' as path;

UpscaledEpisodeManifest _manifest({int episode = 3, int size = 10}) =>
    UpscaledEpisodeManifest(
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
      server = LanShareServer(
        () => [
          SharedUpscaledEpisode(
            manifest: _manifest(size: 1000),
            videoPath: video.path,
          ),
        ],
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
}

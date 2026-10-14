import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/services/upscale/upscale_controller.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory root;
  late String dir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('drop_original_');
    dir = path.join(root.path, '492352_xfdmnext', '1');
    Directory(dir).createSync(recursive: true);
  });
  tearDown(() => root.deleteSync(recursive: true));

  String write(String relative, [String content = 'original']) {
    final file = File(path.join(dir, relative))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    return file.path;
  }

  bool exists(String relative) => File(path.join(dir, relative)).existsSync();

  DownloadEpisode baked(String source, {String episodeDir = ''}) =>
      DownloadEpisode(
        1,
        '前篇',
        0,
        DownloadStatus.completed,
        1,
        1,
        1,
        source,
        episodeDir.isEmpty ? dir : episodeDir,
        'https://example.com/v.m3u8',
        null,
        '',
        8,
        '',
        upscaleStatus: UpscaleStatus.done,
        upscaledVideoPath: path.join(
          episodeDir.isEmpty ? dir : episodeDir,
          'upscaled',
          'video.mp4',
        ),
        upscaledHeight: 2160,
      );

  test('an mp4 download is replaced by its bake', () async {
    final source = write('video.mp4');
    final bake = write(path.join('upscaled', 'video.mp4'), 'baked video!');
    write('skip_fingerprint.json');
    write('danmaku.json');
    final e = baked(source);
    expect(e.playsUpscaled, isFalse);

    expect(await UpscaleController.dropOriginal(e), isTrue);

    expect(exists('video.mp4'), isFalse);
    expect(File(bake).readAsStringSync(), 'baked video!');
    expect(exists('skip_fingerprint.json'), isTrue);
    expect(exists('danmaku.json'), isTrue);
    expect(e.localM3u8Path, bake);
    expect(e.totalBytes, 'baked video!'.length);
    expect(e.playsUpscaled, isTrue);
    expect(e.upscaleStatus, UpscaleStatus.done);

    expect(await UpscaleController.dropOriginal(e), isFalse);
  });

  test('an HLS download loses its playlist, segments and keys', () async {
    final source = write('playlist.m3u8');
    write('seg_00000.ts');
    write('seg_00001.ts');
    write('seg_00002.ts.tmp');
    write('key_0.key');
    write('notes.txt');
    write(path.join('upscaled', 'video.mp4'), 'baked');

    expect(await UpscaleController.dropOriginal(baked(source)), isTrue);

    final left = Directory(
      dir,
    ).listSync().map((e) => path.basename(e.path)).toSet();
    expect(left, {'upscaled', 'notes.txt'});
  });

  test('keeps the original while there is no usable bake', () async {
    final source = write('video.mp4');
    final e = baked(source);
    expect(await UpscaleController.dropOriginal(e), isFalse);
    write(path.join('upscaled', 'video.mp4'), '');
    expect(await UpscaleController.dropOriginal(e), isFalse);
    expect(exists('video.mp4'), isTrue);
    expect(e.localM3u8Path, source);

    e.upscaleStatus = UpscaleStatus.failed;
    write(path.join('upscaled', 'video.mp4'), 'baked');
    expect(await UpscaleController.dropOriginal(e), isFalse);
    expect(exists('video.mp4'), isTrue);
  });

  test('never deletes outside an episode folder', () async {
    final loose = path.join(root.path, 'Videos');
    final source = File(path.join(loose, 'video.mp4'))
      ..createSync(recursive: true)
      ..writeAsStringSync('mine');
    File(path.join(loose, 'upscaled', 'video.mp4'))
      ..createSync(recursive: true)
      ..writeAsStringSync('baked');
    final e = baked(source.path, episodeDir: loose);
    expect(await UpscaleController.dropOriginal(e), isFalse);
    expect(source.existsSync(), isTrue);
  });

  test('imported episodes already play upscaled and are left alone', () async {
    final source = write('video.mp4');
    final e = baked(source)
      ..preUpscaled = true
      ..upscaleStatus = UpscaleStatus.none
      ..upscaledVideoPath = '';
    expect(e.playsUpscaled, isTrue);
    expect(await UpscaleController.dropOriginal(e), isFalse);
    expect(exists('video.mp4'), isTrue);
  });
}

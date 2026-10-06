import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/services/upscale/upscale_controller.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('cloud_bake_'));
  tearDown(() => dir.deleteSync(recursive: true));

  DownloadEpisode episode() => DownloadEpisode(
    3,
    'ep3',
    0,
    DownloadStatus.completed,
    1,
    1,
    1,
    '',
    dir.path,
    '',
    null,
    '',
    0,
    '',
  );

  void writeBake({String? marker}) {
    final upscaled = Directory(path.join(dir.path, 'upscaled'))..createSync();
    File(path.join(upscaled.path, 'video.mp4')).writeAsStringSync('x');
    if (marker != null) {
      File(
        path.join(upscaled.path, 'cloud_baked.json'),
      ).writeAsStringSync(marker);
    }
  }

  test('adopts a cloud bake with its marker height', () {
    writeBake(marker: '{"height":2160}');
    final e = episode();
    expect(UpscaleController.adoptCloudBake(e), isTrue);
    expect(e.upscaleStatus, UpscaleStatus.done);
    expect(e.upscaledHeight, 2160);
    expect(e.upscaledVideoPath, path.join(dir.path, 'upscaled', 'video.mp4'));
  });

  test('ignores a video without the marker', () {
    writeBake();
    final e = episode();
    expect(UpscaleController.adoptCloudBake(e), isFalse);
    expect(e.upscaleStatus, UpscaleStatus.none);
  });

  test('falls back to 1440 on a bad marker and skips finished episodes', () {
    writeBake(marker: 'not json');
    final e = episode();
    expect(UpscaleController.adoptCloudBake(e), isTrue);
    expect(e.upscaledHeight, 1440);
    expect(UpscaleController.adoptCloudBake(e), isFalse);
  });
}

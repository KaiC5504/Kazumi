import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/upscale/upscaled_package.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class UpscaledImportCandidate {
  const UpscaledImportCandidate({
    required this.manifest,
    required this.videoPath,
    this.danmakuPath,
  });

  final UpscaledEpisodeManifest manifest;
  final String videoPath;
  final String? danmakuPath;
}

/// Reads exported episode folders from wherever the user keeps them
/// (iCloud Drive, OneDrive, a USB drive, a desktop folder).
class UpscaledImportService {
  static const _channel = MethodChannel('com.predidit.kazumi/folder_import');

  // iCloud items not downloaded yet show up as ".name.icloud" placeholders.
  static final _iCloudPlaceholder = RegExp(r'^\.(.+)\.icloud$');

  Future<String?> pickFolder() async {
    if (Platform.isIOS) {
      return _channel.invokeMethod<String>('pickFolder');
    }
    return FilePicker.platform.getDirectoryPath(dialogTitle: '选择超分剧集文件夹');
  }

  Future<void> releaseFolder() async {
    if (Platform.isIOS) {
      await _channel.invokeMethod<void>('releaseFolder');
    }
  }

  Future<List<UpscaledImportCandidate>> scan(String rootPath) async {
    final candidates = <UpscaledImportCandidate>[];
    final manifestDirs = <String>{};
    await for (final entity in Directory(
      rootPath,
    ).list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (_realName(path.basename(entity.path)) == upscaledManifestFileName) {
        manifestDirs.add(path.dirname(entity.path));
      }
    }

    final tempDir = await getTemporaryDirectory();
    for (final dir in manifestDirs) {
      try {
        final localManifest = path.join(
          tempDir.path,
          'kazumi_import_manifest.json',
        );
        await copy(path.join(dir, upscaledManifestFileName), localManifest);
        final manifest = UpscaledEpisodeManifest.decode(
          await File(localManifest).readAsString(),
        );
        candidates.add(
          UpscaledImportCandidate(
            manifest: manifest,
            videoPath: path.join(dir, upscaledVideoFileName),
            danmakuPath: manifest.hasDanmaku
                ? path.join(dir, upscaledDanmakuFileName)
                : null,
          ),
        );
      } catch (e) {
        KazumiLogger().w('UpscaledImport: skipping $dir', error: e);
      }
    }
    candidates.sort((a, b) {
      final byName = a.manifest.bangumiName.compareTo(b.manifest.bangumiName);
      return byName != 0
          ? byName
          : a.manifest.episodeNumber.compareTo(b.manifest.episodeNumber);
    });
    return candidates;
  }

  /// Copies [src] to [dst]. [onProgress] is driven by polling the destination
  /// size because the native copy is a single blocking call.
  Future<void> copy(
    String src,
    String dst, {
    int expectedBytes = 0,
    void Function(double)? onProgress,
  }) async {
    await Directory(path.dirname(dst)).create(recursive: true);
    Timer? poller;
    if (onProgress != null && expectedBytes > 0) {
      poller = Timer.periodic(const Duration(milliseconds: 500), (_) async {
        try {
          final file = File(dst);
          if (await file.exists()) {
            onProgress((await file.length() / expectedBytes).clamp(0.0, 1.0));
          }
        } on FileSystemException {
          // The file may be mid-replace; the next tick will catch up.
        }
      });
    }
    try {
      if (Platform.isIOS) {
        await _channel.invokeMethod<void>('coordinatedCopy', {
          'src': src,
          'dst': dst,
        });
      } else {
        await File(src).copy(dst);
      }
    } finally {
      poller?.cancel();
    }
    onProgress?.call(1.0);
  }

  static String _realName(String name) =>
      _iCloudPlaceholder.firstMatch(name)?.group(1) ?? name;
}

import 'dart:io';

import 'package:kazumi/modules/download/download_module.dart';
import 'package:path/path.dart' as p;

/// The episode folder a download was saved under, or '' if it never got one.
String storedEpisodeDir(DownloadEpisode episode) {
  final dir = episode.downloadDirectory.trim();
  if (dir.isNotEmpty) return dir;
  return episode.localM3u8Path.isEmpty ? '' : p.dirname(episode.localM3u8Path);
}

/// iOS can give the app a new container path on update. The files move with
/// it but the absolute paths saved with each download don't, so this points
/// them at [newDir], keeping each file's place inside the episode folder.
void rebaseEpisodePaths(DownloadEpisode episode, String newDir) {
  final oldDir = storedEpisodeDir(episode);
  String move(String file) {
    if (file.isEmpty || oldDir.isEmpty || !p.isWithin(oldDir, file)) {
      return file;
    }
    return p.join(newDir, p.relative(file, from: oldDir));
  }

  episode.localM3u8Path = move(episode.localM3u8Path);
  episode.upscaledVideoPath = move(episode.upscaledVideoPath);
  episode.downloadDirectory = newDir;
}

/// Moves a downloads folder to [to], merging into what's already there.
/// Renames stay inside one volume, so even large videos move instantly.
/// Anything that would overwrite is left where it was.
Future<void> moveDownloads(Directory from, String to) async {
  if (!await Directory(to).exists()) {
    await Directory(p.dirname(to)).create(recursive: true);
    await from.rename(to);
    return;
  }
  await for (final entity in from.list(followLinks: false)) {
    final target = p.join(to, p.basename(entity.path));
    final existing = await FileSystemEntity.type(target, followLinks: false);
    if (existing == FileSystemEntityType.notFound) {
      await entity.rename(target);
    } else if (entity is Directory &&
        existing == FileSystemEntityType.directory) {
      await moveDownloads(entity, target);
    }
  }
  if (await from.list().isEmpty) await from.delete();
}

/// Deletes `<show>/<episode>.importing` folders under [base]. An import
/// stages there and renames it into place, so one left at startup was cut
/// short. Nothing else is touched: a folder without a record may still be
/// someone's video if the records failed to load.
Future<void> clearInterruptedImports(String base) async {
  final root = Directory(base);
  if (!await root.exists()) return;
  final showFolder = RegExp(r'^\d+_.+$');
  final staging = RegExp(r'^\d+\.importing$');
  await for (final show in root.list(followLinks: false)) {
    if (show is! Directory || !showFolder.hasMatch(p.basename(show.path))) {
      continue;
    }
    await for (final entry in show.list(followLinks: false)) {
      if (entry is Directory && staging.hasMatch(p.basename(entry.path))) {
        await entry.delete(recursive: true);
      }
    }
  }
}

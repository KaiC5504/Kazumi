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

/// Deletes episode folders under [base] that no record owns: ones a delete
/// missed while their saved path was stale, and imports that never finished
/// (`<episode>.importing`). Only names the download manager writes are
/// touched, since on iOS the folder is also open to the Files app.
Future<void> sweepOrphanedDownloads(
  String base,
  Iterable<DownloadRecord> records,
) async {
  final owned = <String, Set<String>>{};
  for (final record in records) {
    owned
        .putIfAbsent('${record.bangumiId}_${record.pluginName}', () => {})
        .addAll(record.episodes.keys.map((n) => '$n'));
  }
  // No records more likely means they failed to load than that nothing is
  // downloaded, and baked episodes are too big to lose on a guess.
  if (owned.isEmpty) return;
  final root = Directory(base);
  if (!await root.exists()) return;
  final showFolder = RegExp(r'^\d+_.+$');
  final episodeFolder = RegExp(r'^\d+(\.importing)?$');
  await for (final show in root.list(followLinks: false)) {
    final name = p.basename(show.path);
    if (show is! Directory || !showFolder.hasMatch(name)) continue;
    final episodes = owned[name] ?? const <String>{};
    await for (final entry in show.list(followLinks: false)) {
      final episode = p.basename(entry.path);
      if (entry is Directory &&
          episodeFolder.hasMatch(episode) &&
          !episodes.contains(episode)) {
        await entry.delete(recursive: true);
      }
    }
    if (await show.list().isEmpty) await show.delete();
  }
}

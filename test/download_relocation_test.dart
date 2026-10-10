import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/services/download/download_relocation.dart';
import 'package:path/path.dart' as p;

DownloadEpisode _episode({
  String dir = '',
  String video = '',
  String upscaled = '',
}) => DownloadEpisode(
  3,
  '第3集',
  0,
  DownloadStatus.completed,
  1,
  0,
  0,
  video,
  dir,
  '',
  DateTime(2026),
  '',
  0,
  '',
  upscaledVideoPath: upscaled,
);

void main() {
  final oldDir = p.join(
    p.separator,
    'var',
    'Application',
    'OLD-UUID',
    'downloads',
    '10639_aafun',
    '3',
  );
  final newDir = p.join(
    p.separator,
    'var',
    'Application',
    'NEW-UUID',
    'Documents',
    'Downloads',
    '10639_aafun',
    '3',
  );

  test('moves every saved path into the new episode folder', () {
    final episode = _episode(
      dir: oldDir,
      video: p.join(oldDir, 'playlist.m3u8'),
      upscaled: p.join(oldDir, 'upscaled', 'video.mp4'),
    );
    rebaseEpisodePaths(episode, newDir);
    expect(episode.downloadDirectory, newDir);
    expect(episode.localM3u8Path, p.join(newDir, 'playlist.m3u8'));
    expect(episode.upscaledVideoPath, p.join(newDir, 'upscaled', 'video.mp4'));
  });

  test('leaves empty paths and paths outside the folder alone', () {
    final elsewhere = p.join(p.separator, 'mnt', 'export', 'video.mp4');
    final episode = _episode(dir: oldDir, upscaled: elsewhere);
    rebaseEpisodePaths(episode, newDir);
    expect(episode.localM3u8Path, '');
    expect(episode.upscaledVideoPath, elsewhere);
  });

  test('older records without a folder use the video file location', () {
    final episode = _episode(video: p.join(oldDir, 'video.mp4'));
    expect(storedEpisodeDir(episode), oldDir);
    rebaseEpisodePaths(episode, newDir);
    expect(episode.localM3u8Path, p.join(newDir, 'video.mp4'));
    expect(storedEpisodeDir(_episode()), '');
  });

  // Upstream's rebaseIosDownloadPaths runs before the relocation above and
  // doesn't know upscaledVideoPath, so baked episodes would lose their video.
  test('nothing in lib calls upstream\'s iOS path rebase', () {
    final callers = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !f.path.endsWith('download_path_migration.dart'))
        .where((f) => f.readAsStringSync().contains('rebaseIosDownloadPaths('))
        .map((f) => f.path)
        .toList();
    expect(callers, isEmpty);
  });

  group('moveDownloads', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('kazumi_relocation_test');
    });
    tearDown(() => tmp.delete(recursive: true));

    File write(String relative, String content) =>
        File(p.join(tmp.path, relative))
          ..createSync(recursive: true)
          ..writeAsStringSync(content);

    test('renames the whole folder when nothing is there yet', () async {
      write(p.join('old', '1_a', '3', 'video.mp4'), 'v');
      final to = p.join(tmp.path, 'Documents', 'Downloads');
      await moveDownloads(Directory(p.join(tmp.path, 'old')), to);
      expect(File(p.join(to, '1_a', '3', 'video.mp4')).readAsStringSync(), 'v');
      expect(Directory(p.join(tmp.path, 'old')).existsSync(), isFalse);
    });

    test('merges into an existing folder without overwriting', () async {
      write(p.join('old', '1_a', '3', 'video.mp4'), 'old-3');
      write(p.join('old', '1_a', '4', 'video.mp4'), 'old-4');
      write(p.join('old', '2_b', '1', 'video.mp4'), 'old-b');
      write(p.join('new', '1_a', '3', 'video.mp4'), 'new-3');
      final to = p.join(tmp.path, 'new');
      await moveDownloads(Directory(p.join(tmp.path, 'old')), to);
      String read(String r) => File(p.join(to, r)).readAsStringSync();
      expect(read(p.join('1_a', '3', 'video.mp4')), 'new-3');
      expect(read(p.join('1_a', '4', 'video.mp4')), 'old-4');
      expect(read(p.join('2_b', '1', 'video.mp4')), 'old-b');
      expect(
        File(p.join(tmp.path, 'old', '1_a', '3', 'video.mp4')).existsSync(),
        isTrue,
        reason: 'a clash keeps the old copy rather than deleting anything',
      );
    });
  });

  group('sweepOrphanedDownloads', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('kazumi_sweep_test');
    });
    tearDown(() => tmp.delete(recursive: true));

    void write(String relative) => File(p.join(tmp.path, relative))
      ..createSync(recursive: true)
      ..writeAsStringSync('v');
    bool exists(String relative) =>
        FileSystemEntity.typeSync(p.join(tmp.path, relative)) !=
        FileSystemEntityType.notFound;
    DownloadRecord record(int id, String plugin, List<int> episodes) =>
        DownloadRecord(id, '', '', plugin, {
          for (final n in episodes) n: _episode(),
        }, DateTime(2026));

    test('frees episodes and imports no record owns', () async {
      write(p.join('10639_aafun', '3', 'video.mp4'));
      write(p.join('10639_aafun', '4', 'video.mp4'));
      write(p.join('10639_aafun', '5.importing', 'video.mp4'));
      write(p.join('2_b', '1', 'seg_0.ts'));
      await sweepOrphanedDownloads(tmp.path, [
        record(10639, 'aafun', [3]),
      ]);
      expect(exists(p.join('10639_aafun', '3', 'video.mp4')), isTrue);
      expect(exists(p.join('10639_aafun', '4')), isFalse);
      expect(exists(p.join('10639_aafun', '5.importing')), isFalse);
      expect(exists('2_b'), isFalse);
    });

    test('leaves files the app did not name alone', () async {
      write(p.join('my notes', 'a.txt'));
      write(p.join('2_b', 'cover.jpg'));
      write(p.join('2_b', 'extras', 'a.mp4'));
      await sweepOrphanedDownloads(tmp.path, [
        record(1, 'a', [1]),
      ]);
      expect(exists(p.join('my notes', 'a.txt')), isTrue);
      expect(exists(p.join('2_b', 'cover.jpg')), isTrue);
      expect(exists(p.join('2_b', 'extras', 'a.mp4')), isTrue);
    });

    test('does nothing when no records loaded', () async {
      write(p.join('10639_aafun', '3', 'video.mp4'));
      await sweepOrphanedDownloads(tmp.path, const []);
      expect(exists(p.join('10639_aafun', '3', 'video.mp4')), isTrue);
    });

    test('a missing download folder is fine', () async {
      await sweepOrphanedDownloads(p.join(tmp.path, 'none'), [
        record(1, 'a', [1]),
      ]);
    });
  });
}

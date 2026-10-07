import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/services/download/offline_launch.dart';

DownloadEpisode done(int n, {bool up = false}) => DownloadEpisode(
  n,
  'ep$n',
  0,
  DownloadStatus.completed,
  100,
  1,
  1,
  '/p/$n.m3u8',
  '/p',
  '',
  null,
  '',
  0,
  'u$n',
  preUpscaled: up,
);

void main() {
  test('resumes the last watched episode when it is downloaded', () {
    expect(pickStartEpisode([done(1), done(2), done(3)], 2), 2);
  });

  test('otherwise the lowest downloaded episode', () {
    expect(pickStartEpisode([done(5), done(3), done(4)], 9), 3);
    expect(pickStartEpisode([done(5), done(3)], null), 3);
  });

  test('args carry every completed episode', () {
    final record = DownloadRecord(7, 'X', '', 'p', {
      1: done(1, up: true),
      2: done(2, up: true),
    }, DateTime(2026));
    final args = buildOfflineArgs(
      record: record,
      episodeNumber: 2,
      road: 0,
      completed: record.episodes.values.toList(),
    );
    expect(args.episodeNumber, 2);
    expect(args.downloadedEpisodes, hasLength(2));
    expect(
      LocalSource(record, record.episodes.values.toList()).preUpscaled,
      isTrue,
    );
  });
}

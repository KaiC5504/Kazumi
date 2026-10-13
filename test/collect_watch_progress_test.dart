import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_tag.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/pages/collect/collect_watch_progress.dart';

void main() {
  test('keeps source episode names only when they carry a number', () {
    final progress = collectWatchProgress([
      _history(1, episode: 3, name: '第03集', at: 1),
      _history(2, episode: 7, name: '07', at: 1),
      _history(3, episode: 2, name: '', at: 1),
      _history(4, episode: 4, name: 'もう一度、君に会うために', at: 1),
    ]);

    expect(progress, {
      1: '看到 第03集',
      2: '看到 第 7 话',
      3: '看到 第 2 话',
      4: '看到 第 4 话',
    });
  });

  test('the most recently watched source wins', () {
    final progress = collectWatchProgress([
      _history(1, episode: 5, name: '', at: 2, adapter: 'a'),
      _history(1, episode: 9, name: '', at: 3, adapter: 'b'),
      _history(1, episode: 1, name: '', at: 1, adapter: 'c'),
    ]);

    expect(progress, {1: '看到 第 9 话'});
  });
}

History _history(
  int id, {
  required int episode,
  required String name,
  required int at,
  String adapter = 'source',
}) {
  return History(
    _item(id),
    episode,
    adapter,
    DateTime.fromMillisecondsSinceEpoch(at * 1000),
    '',
    name,
  );
}

BangumiItem _item(int id) {
  return BangumiItem(
    id: id,
    type: 2,
    name: 'subject $id',
    nameCn: '条目 $id',
    summary: '',
    airDate: '2026-01-01',
    airWeekday: 4,
    rank: 0,
    images: const {'large': '', 'common': ''},
    tags: const <BangumiTag>[],
    alias: const [],
    ratingScore: 0,
    votes: 0,
    votesCount: const [],
    info: '',
  );
}

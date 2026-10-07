import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/services/bangumi_progress/bangumi_episode_matcher.dart';
import 'package:kazumi/services/bangumi_progress/bangumi_progress_service.dart';

EpisodeInfo ep(int id, num sort, num epNo, {int type = 0}) => EpisodeInfo(
  id: id,
  episode: sort,
  ep: epNo,
  type: type,
  name: '',
  nameCn: '',
  airdate: '',
);

void main() {
  group('matcher', () {
    final season1 = [for (var i = 1; i <= 12; i++) ep(100 + i, i, i)];
    final season2 = [
      ep(900, 0, 0, type: 1),
      for (var i = 1; i <= 12; i++) ep(200 + i, 12 + i, i),
    ];

    test(
      'same numbering',
      () => expect(matchBangumiEpisodeId(season1, 5), 105),
    );
    test(
      'season 2: source says 3, Bangumi sort 15, ep 3',
      () => expect(matchBangumiEpisodeId(season2, 3), 203),
    );
    test(
      'source uses the overall number',
      () => expect(matchBangumiEpisodeId(season2, 15), 203),
    );
    test(
      'specials are ignored',
      () => expect(matchBangumiEpisodeId(season2, 0), isNull),
    );
    test('no match', () => expect(matchBangumiEpisodeId(season1, 40), isNull));
  });

  group('service', () {
    late List<int> marked;
    late List<int> collected;
    late String queue;
    late MarkResult next;
    late BangumiProgressService s;

    setUp(() {
      marked = [];
      collected = [];
      queue = '[]';
      next = MarkResult.ok;
      s = BangumiProgressService(
        fetchEpisodes: (id) async => [
          for (var i = 1; i <= 12; i++) ep(500 + i, i, i),
        ],
        mark: (id) async {
          final r = next;
          if (r == MarkResult.ok) marked.add(id);
          return r;
        },
        collectAsWatching: (id) async {
          collected.add(id);
          next = MarkResult.ok;
          return true;
        },
        enabled: () => true,
        readQueue: () => queue,
        writeQueue: (v) async => queue = v,
      );
    });

    Future<void> watch(int epNo, double fraction) async {
      s.onPosition(
        subjectId: 9,
        episodeNumber: epNo,
        position: Duration(seconds: (1440 * fraction).round()),
        duration: const Duration(minutes: 24),
      );
      await s.idle;
    }

    test('marks once at 90%', () async {
      await watch(4, 0.5);
      expect(marked, isEmpty);
      await watch(4, 0.91);
      await watch(4, 0.95);
      expect(marked, [504]);
    });

    test('not collected: collect as 在看 then retry once', () async {
      next = MarkResult.notCollected;
      await watch(2, 0.92);
      expect(collected, [9]);
      expect(marked, [502]);
    });

    test('offline: queued, flushed later', () async {
      next = MarkResult.failed;
      await watch(6, 0.95);
      expect(marked, isEmpty);
      expect(jsonDecode(queue), hasLength(1));
      next = MarkResult.ok;
      await s.flush();
      expect(marked, [506]);
      expect(jsonDecode(queue), isEmpty);
    });

    test('revoked token: dropped, not requeued forever', () async {
      next = MarkResult.unauthorized;
      await watch(7, 0.95);
      expect(jsonDecode(queue), isEmpty);
      await s.flush();
      expect(marked, isEmpty);
    });

    test('400 is dropped and never collects', () async {
      next = MarkResult.rejected;
      await watch(3, 0.95);
      expect(collected, isEmpty);
      expect(jsonDecode(queue), isEmpty);
    });

    test('only 404 means not collected', () {
      expect(markResultForStatus(404), MarkResult.notCollected);
      expect(markResultForStatus(400), MarkResult.rejected);
      expect(markResultForStatus(401), MarkResult.unauthorized);
      expect(markResultForStatus(500), MarkResult.failed);
      expect(markResultForStatus(null), MarkResult.failed);
    });

    test('flush keeps unsent marks queued while it works', () async {
      queue = jsonEncode([
        {'s': 9, 'e': 1},
        {'s': 9, 'e': 2},
        {'s': 9, 'e': 3},
      ]);
      final seen = <String>[];
      final flushing = BangumiProgressService(
        fetchEpisodes: (id) async => [
          for (var i = 1; i <= 12; i++) ep(500 + i, i, i),
        ],
        mark: (id) async {
          seen.add(queue);
          return id == 502 ? MarkResult.failed : MarkResult.ok;
        },
        collectAsWatching: (id) async => fail('must not collect'),
        enabled: () => true,
        readQueue: () => queue,
        writeQueue: (v) async => queue = v,
      );
      await flushing.flush();
      // Killed during the second mark, the queue would still hold 2 and 3.
      expect(jsonDecode(seen[1]), [
        {'s': 9, 'e': 2},
        {'s': 9, 'e': 3},
      ]);
      expect(jsonDecode(queue), [
        {'s': 9, 'e': 2},
      ]);
    });

    test('short clips are ignored', () async {
      s.onPosition(
        subjectId: 9,
        episodeNumber: 1,
        position: const Duration(seconds: 100),
        duration: const Duration(seconds: 110),
      );
      await s.idle;
      expect(marked, isEmpty);
    });

    test('disabled: does nothing', () async {
      final off = BangumiProgressService(
        fetchEpisodes: (id) async => fail('must not fetch'),
        mark: (id) async => fail('must not mark'),
        collectAsWatching: (id) async => fail('must not collect'),
        enabled: () => false,
        readQueue: () => queue,
        writeQueue: (v) async => queue = v,
      );
      off.onPosition(
        subjectId: 9,
        episodeNumber: 1,
        position: const Duration(minutes: 23),
        duration: const Duration(minutes: 24),
      );
      await off.flush();
      expect(queue, '[]');
    });
  });
}

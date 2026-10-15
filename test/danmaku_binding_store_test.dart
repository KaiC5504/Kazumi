import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/services/player/danmaku_binding_store.dart';
import 'package:kazumi/services/storage/storage.dart';

import 'support/syncplay_sim.dart' show setUpSyncplayStorage;

DanmakuEntry entry(String message) => DanmakuEntry(
  message: message,
  time: 1,
  type: 1,
  color: Colors.white,
  source: '',
);

void main() {
  setUpSyncplayStorage();

  setUp(() async {
    await GStorage.putSetting<String>(DanmakuBindingStore.setting, '{}');
  });

  group('fromPick', () {
    test('same numbering gives offset 0', () {
      final b = DanmakuBinding.fromPick(
        animeId: 17756,
        animeTitle: 'A',
        episodeId: 177560003,
        currentEpisode: 3,
      )!;
      expect(b.offset, 0);
      expect(b.episodeIdFor(4), 177560004);
    });
    test('second half of a split cour gives offset 12', () {
      final b = DanmakuBinding.fromPick(
        animeId: 17756,
        animeTitle: 'A',
        episodeId: 177560013,
        currentEpisode: 1,
      )!;
      expect(b.offset, 12);
      expect(b.episodeIdFor(2), 177560014);
    });
    test('an id from another anime is not remembered', () {
      expect(
        DanmakuBinding.fromPick(
          animeId: 17756,
          animeTitle: 'A',
          episodeId: 99990001,
          currentEpisode: 1,
        ),
        isNull,
      );
    });
    test('suffix 0000 is not remembered', () {
      expect(
        DanmakuBinding.fromPick(
          animeId: 17756,
          animeTitle: 'A',
          episodeId: 177560000,
          currentEpisode: 1,
        ),
        isNull,
      );
    });
  });

  group('episodeIdFor bounds', () {
    test('below 1 has no id', () {
      const b = DanmakuBinding(animeId: 17756, animeTitle: 'A', offset: -2);
      expect(b.episodeIdFor(2), isNull);
      expect(b.episodeIdFor(3), 177560001);
    });
    test('past 9999 has no id', () {
      const b = DanmakuBinding(animeId: 17756, animeTitle: 'A', offset: 9999);
      expect(b.episodeIdFor(1), isNull);
    });
  });

  group('numbering basis', () {
    test('the title number wins', () {
      expect(danmakuBindingEpisode('第13集', 1), 13);
    });
    test('no number in the title falls back to the position', () {
      expect(danmakuBindingEpisode('OVA', 4), 4);
      expect(danmakuBindingEpisode('', 4), 4);
    });
  });

  group('store', () {
    test('nothing remembered by default', () {
      expect(DanmakuBindingStore.bindingFor(42), isNull);
    });
    test('remember and forget per anime', () async {
      await DanmakuBindingStore.remember(
        42,
        const DanmakuBinding(animeId: 1, animeTitle: '甲', offset: 12),
      );
      await DanmakuBindingStore.remember(
        7,
        const DanmakuBinding(animeId: 2, animeTitle: '乙', offset: 0),
      );
      final b = DanmakuBindingStore.bindingFor(42)!;
      expect((b.animeId, b.animeTitle, b.offset), (1, '甲', 12));
      await DanmakuBindingStore.forget(42);
      expect(DanmakuBindingStore.bindingFor(42), isNull);
      expect(DanmakuBindingStore.bindingFor(7)?.animeId, 2);
    });
    test('corrupt storage reads as nothing remembered', () async {
      await GStorage.putSetting<String>(DanmakuBindingStore.setting, '{oops');
      expect(DanmakuBindingStore.bindingFor(42), isNull);
    });
    test('a malformed entry reads as nothing remembered', () async {
      await GStorage.putSetting<String>(
        DanmakuBindingStore.setting,
        '{"42": {"animeId": "x"}}',
      );
      expect(DanmakuBindingStore.bindingFor(42), isNull);
    });
  });

  group('loadBoundDanmaku', () {
    const binding = DanmakuBinding(animeId: 17756, animeTitle: 'A', offset: 0);
    final picked = [entry('picked')];
    final online = [entry('online')];
    final auto = [entry('auto')];

    Future<({List<DanmakuEntry> danmakus, bool failed})> run({
      bool local = true,
      CachedDanmaku? cache,
      Object? fetchError,
      List<DanmakuEntry>? fetched,
      int episode = 3,
      List<int>? fetchedIds,
      List<List<DanmakuEntry>>? written,
    }) => loadBoundDanmaku(
      binding: binding,
      episode: episode,
      local: local,
      readCache: () async => cache,
      fetch: (id) async {
        fetchedIds?.add(id);
        if (fetchError != null) throw fetchError;
        return fetched ?? online;
      },
      writeCache: (d) async => written?.add(d),
    );

    test(
      'offline cache from the same DanDan anime is used without fetching',
      () async {
        final ids = <int>[];
        final r = await run(
          cache: (danmakus: picked, danDanBangumiID: 17756),
          fetchedIds: ids,
        );
        expect(r.danmakus, picked);
        expect(ids, isEmpty);
      },
    );

    test(
      'a cache from another anime is replaced by the bound episode',
      () async {
        final ids = <int>[];
        final written = <List<DanmakuEntry>>[];
        final r = await run(
          cache: (danmakus: auto, danDanBangumiID: 999),
          fetchedIds: ids,
          written: written,
        );
        expect(ids, [177560003]);
        expect(r.danmakus, online);
        expect(written, [online]);
      },
    );

    test('no network falls back to whatever is cached', () async {
      final r = await run(
        cache: (danmakus: auto, danDanBangumiID: 999),
        fetchError: Exception('offline'),
      );
      expect((r.danmakus, r.failed), (auto, false));
    });

    test('an empty fetch falls back to the cache', () async {
      final r = await run(
        cache: (danmakus: auto, danDanBangumiID: 999),
        fetched: const [],
      );
      expect(r.danmakus, auto);
    });

    test('no network and no cache is a failure', () async {
      final r = await run(cache: null, fetchError: Exception('offline'));
      expect(r.danmakus, isEmpty);
      expect(r.failed, isTrue);
    });

    test('online: fetch, never touch the cache', () async {
      final written = <List<DanmakuEntry>>[];
      final r = await run(local: false, written: written);
      expect(r.danmakus, online);
      expect(written, isEmpty);
    });

    test('online failure is a failure', () async {
      final r = await run(local: false, fetchError: Exception('x'));
      expect(r.failed, isTrue);
    });

    test('out of range: no request, cache if any', () async {
      final ids = <int>[];
      final r = await run(
        episode: -5,
        cache: (danmakus: auto, danDanBangumiID: 999),
        fetchedIds: ids,
      );
      expect(ids, isEmpty);
      expect(r.danmakus, auto);
    });
  });
}

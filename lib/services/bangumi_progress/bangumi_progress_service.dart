import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/bangumi_progress/bangumi_episode_matcher.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';

enum MarkResult { ok, notCollected, unauthorized, rejected, failed }

/// Only 404 means the subject isn't collected. A 400 can be any validation
/// error, and collecting on it would overwrite 看过 or 抛弃 with 在看.
MarkResult markResultForStatus(int? status) => switch (status) {
  404 => MarkResult.notCollected,
  401 || 403 => MarkResult.unauthorized,
  400 => MarkResult.rejected,
  _ => MarkResult.failed,
};

/// Marks an episode 看过 on Bangumi once it's 90% watched. Marks made
/// offline (downloads on the iPad) wait in a queue until the next flush.
class BangumiProgressService {
  BangumiProgressService({
    required this.fetchEpisodes,
    required this.mark,
    required this.collectAsWatching,
    required this.enabled,
    required this.readQueue,
    required this.writeQueue,
  });

  static final BangumiProgressService instance = BangumiProgressService(
    fetchEpisodes: BangumiApi.getBangumiEpisodesByID,
    mark: BangumiApi.markEpisodeWatched,
    collectAsWatching: (id) => BangumiApi.updateBangumiById(id, {'type': 3}),
    enabled: () =>
        GStorage.getSetting(SettingsKeys.bangumiAutoMarkWatched) &&
        GStorage.getSetting(SettingsKeys.bangumiAccessToken).trim().isNotEmpty,
    readQueue: () => GStorage.getSetting(SettingsKeys.bangumiProgressQueue),
    writeQueue: (v) =>
        GStorage.putSetting<String>(SettingsKeys.bangumiProgressQueue, v),
  );

  static AppLifecycleListener? _lifecycle;

  static void attachLifecycle() {
    _lifecycle ??= AppLifecycleListener(
      onResume: () => unawaited(instance.flush()),
    );
  }

  final Future<List<EpisodeInfo>> Function(int subjectId) fetchEpisodes;
  final Future<MarkResult> Function(int episodeId) mark;
  final Future<bool> Function(int subjectId) collectAsWatching;
  final bool Function() enabled;
  final String Function() readQueue;
  final Future<void> Function(String) writeQueue;

  final Set<String> _done = {};
  final Map<int, List<EpisodeInfo>> _episodes = {};
  Future<void> _chain = Future.value();

  /// Completes when queued work has finished; for tests.
  Future<void> get idle => _chain;

  void onPosition({
    required int subjectId,
    required int episodeNumber,
    required Duration position,
    required Duration duration,
  }) {
    try {
      if (duration < const Duration(minutes: 2)) return;
      if (position.inMilliseconds < duration.inMilliseconds * 0.9) return;
      if (!enabled()) return;
      if (!_done.add('$subjectId:$episodeNumber')) return;
      _chain = _chain.then((_) => _markOrQueue(subjectId, episodeNumber));
    } catch (e) {
      KazumiLogger().w('BangumiProgress: onPosition failed', error: e);
    }
  }

  Future<void> flush() {
    try {
      if (!enabled()) return _chain;
    } catch (_) {
      return _chain;
    }
    return _chain = _chain.then((_) async {
      try {
        // Items leave the queue one at a time, so a kill mid-flush (it runs
        // on resume) loses nothing.
        for (final (s, e) in _readItems()) {
          if (!await _markOrQueue(s, e)) await _dequeue(s, e);
        }
      } catch (e) {
        KazumiLogger().w('BangumiProgress: flush failed', error: e);
      }
    });
  }

  List<(int, int)> _readItems() {
    try {
      return [
        for (final i in jsonDecode(readQueue()) as List)
          ((i as Map)['s'] as int, i['e'] as int),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _enqueue(int subjectId, int episodeNumber) async {
    final items = _readItems()..add((subjectId, episodeNumber));
    await writeQueue(
      jsonEncode([
        for (final (s, e) in items.toSet()) {'s': s, 'e': e},
      ]),
    );
  }

  Future<void> _dequeue(int subjectId, int episodeNumber) async {
    final items = _readItems()..remove((subjectId, episodeNumber));
    await writeQueue(
      jsonEncode([
        for (final (s, e) in items) {'s': s, 'e': e},
      ]),
    );
  }

  /// Returns whether the mark is (still) queued.
  Future<bool> _markOrQueue(int subjectId, int episodeNumber) async {
    try {
      final eps = _episodes[subjectId] ??= await fetchEpisodes(subjectId);
      if (eps.isEmpty) {
        _episodes.remove(subjectId);
        await _enqueue(subjectId, episodeNumber);
        return true;
      }
      final id = matchBangumiEpisodeId(eps, episodeNumber);
      if (id == null) {
        KazumiLogger().i(
          'BangumiProgress: no episode $episodeNumber in $subjectId',
        );
        return false;
      }
      var result = await mark(id);
      if (result == MarkResult.notCollected &&
          await collectAsWatching(subjectId)) {
        result = await mark(id);
      }
      switch (result) {
        case MarkResult.ok:
          return false;
        case MarkResult.unauthorized:
          KazumiLogger().w('BangumiProgress: token rejected, dropping mark');
          return false;
        case MarkResult.rejected:
          KazumiLogger().w('BangumiProgress: mark rejected, dropping it');
          return false;
        case MarkResult.notCollected:
        case MarkResult.failed:
          await _enqueue(subjectId, episodeNumber);
          return true;
      }
    } catch (e) {
      KazumiLogger().w('BangumiProgress: mark failed, queued', error: e);
      try {
        await _enqueue(subjectId, episodeNumber);
      } catch (_) {}
      return true;
    }
  }
}

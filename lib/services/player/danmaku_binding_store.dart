import 'dart:convert';

import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/media.dart';

/// A DanDan anime the user picked by hand for one Bangumi anime. Episode ids
/// follow DanDan's `animeId * 10000 + episode` convention, the same one the
/// automatic lookup relies on.
class DanmakuBinding {
  const DanmakuBinding({
    required this.animeId,
    required this.animeTitle,
    required this.offset,
  });

  final int animeId;
  final String animeTitle;

  /// DanDan episode number minus the source's, e.g. 12 when the source's
  /// episode 1 is the second cour's DanDan episode 13.
  final int offset;

  static DanmakuBinding? fromPick({
    required int animeId,
    required String animeTitle,
    required int episodeId,
    required int currentEpisode,
  }) {
    if (episodeId ~/ 10000 != animeId) return null;
    final number = episodeId % 10000;
    if (number < 1) return null;
    return DanmakuBinding(
      animeId: animeId,
      animeTitle: animeTitle,
      offset: number - currentEpisode,
    );
  }

  int? episodeIdFor(int episode) {
    final number = episode + offset;
    if (number < 1 || number > 9999) return null;
    return animeId * 10000 + number;
  }

  Map<String, dynamic> toJson() => {
    'animeId': animeId,
    'animeTitle': animeTitle,
    'offset': offset,
  };

  static DanmakuBinding? fromJson(Object? json) {
    if (json is! Map) return null;
    final animeId = json['animeId'];
    final animeTitle = json['animeTitle'];
    final offset = json['offset'];
    if (animeId is! int || animeTitle is! String || offset is! int) {
      return null;
    }
    return DanmakuBinding(
      animeId: animeId,
      animeTitle: animeTitle,
      offset: offset,
    );
  }
}

/// One numbering for online, offline and download time: download records
/// number episodes by list position, titles carry the real number.
int danmakuBindingEpisode(String title, int fallback) {
  final parsed = extractEpisodeNumber(title);
  return parsed > 0 ? parsed : fallback;
}

class DanmakuBindingStore {
  // Not in SettingsKeys.all: that list belongs to upstream's settings file.
  static const setting = SettingKey<String>(
    'danmakuBindings',
    '{}',
    group: SettingGroup.misc,
  );

  static Map<String, dynamic> _read() {
    try {
      return jsonDecode(GStorage.getSetting(setting)) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static Future<void> _write(Map<String, dynamic> map) =>
      GStorage.putSetting<String>(setting, jsonEncode(map));

  static DanmakuBinding? bindingFor(int bangumiId) =>
      DanmakuBinding.fromJson(_read()['$bangumiId']);

  static Future<void> remember(int bangumiId, DanmakuBinding binding) =>
      _write(_read()..['$bangumiId'] = binding.toJson());

  static Future<void> forget(int bangumiId) =>
      _write(_read()..remove('$bangumiId'));
}

/// `danDanEpisodeID` is 0 for caches without a stamp (automatic lookups, older
/// bindings), which never match a bound episode.
typedef CachedDanmaku = ({
  List<DanmakuEntry> danmakus,
  int danDanBangumiID,
  int danDanEpisodeID,
});

/// Downloaded playback keeps working offline: a cache is trusted only when it
/// is stamped with the bound episode's id, and is used as is then. Anything
/// else is replaced when the network allows and kept when it doesn't.
Future<({List<DanmakuEntry> danmakus, bool failed})> loadBoundDanmaku({
  required DanmakuBinding binding,
  required int episode,
  required bool local,
  required Future<CachedDanmaku?> Function() readCache,
  required Future<List<DanmakuEntry>> Function(int episodeId) fetch,
  required Future<void> Function(List<DanmakuEntry>, int episodeId) writeCache,
}) async {
  final id = binding.episodeIdFor(episode);
  CachedDanmaku? cached;
  if (local) {
    try {
      cached = await readCache();
    } catch (_) {}
  }
  final hasCache = cached != null && cached.danmakus.isNotEmpty;
  if (hasCache && id != null && cached.danDanEpisodeID == id) {
    return (danmakus: cached.danmakus, failed: false);
  }

  var threw = false;
  if (id != null) {
    try {
      final res = await fetch(id);
      if (res.isNotEmpty || !local) {
        if (local) {
          try {
            await writeCache(res, id);
          } catch (_) {}
        }
        return (danmakus: res, failed: false);
      }
    } catch (_) {
      threw = true;
      if (!local) return (danmakus: const <DanmakuEntry>[], failed: true);
    }
  }
  if (hasCache) return (danmakus: cached.danmakus, failed: false);
  return (danmakus: const <DanmakuEntry>[], failed: threw);
}

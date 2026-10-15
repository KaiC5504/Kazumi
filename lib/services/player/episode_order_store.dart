import 'dart:convert';

import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/media.dart';

enum TitleOrder { ascending, descending, unknown }

/// Positions are 1-based places in the source's list. Flipping changes only
/// how the list is shown and, outside 一起看 rooms, which way "next" goes.
class EpisodeOrder {
  static TitleOrder titleOrder(List<String> titles) {
    var firstIndex = -1;
    var first = 0;
    for (var i = 0; i < titles.length; i++) {
      final n = extractEpisodeNumber(titles[i]);
      if (n > 0) {
        firstIndex = i;
        first = n;
        break;
      }
    }
    if (firstIndex < 0) return TitleOrder.unknown;

    var last = 0;
    for (var i = titles.length - 1; i > firstIndex; i--) {
      final n = extractEpisodeNumber(titles[i]);
      if (n > 0) {
        last = n;
        break;
      }
    }
    if (last == 0 || first == last) return TitleOrder.unknown;
    return first < last ? TitleOrder.ascending : TitleOrder.descending;
  }

  /// Rooms always step +1 so both devices agree on the next episode.
  static int nextDirection({
    required bool flipped,
    required bool inRoom,
    required TitleOrder Function() titles,
  }) {
    if (!flipped || inRoom) return 1;
    return titles() == TitleOrder.ascending ? 1 : -1;
  }

  static int? step(
    int position, {
    required bool next,
    required int length,
    required int direction,
  }) {
    final target = position + (next ? direction : -direction);
    return target >= 1 && target <= length ? target : null;
  }

  static ({int? next, bool roomWantsNext}) endOfEpisode({
    required int position,
    required int length,
    required int direction,
    required int? followEpisode,
  }) => (
    next: step(position, next: true, length: length, direction: direction),
    roomWantsNext: followEpisode == position + 1,
  );

  static int positionAt(
    int displayIndex, {
    required int length,
    required bool reversed,
  }) => reversed ? length - displayIndex : displayIndex + 1;

  static int displayIndexOf(
    int position, {
    required int length,
    required bool reversed,
  }) => reversed ? length - position : position - 1;
}

class EpisodeOrderStore {
  // Not in SettingsKeys.all: that list belongs to upstream's settings file.
  static const setting = SettingKey<String>(
    'reversedEpisodeLists',
    '[]',
    group: SettingGroup.misc,
  );

  static String _key(int bangumiId, String pluginName) =>
      '$bangumiId|$pluginName';

  static Set<String> _read() {
    try {
      return (jsonDecode(GStorage.getSetting(setting)) as List)
          .whereType<String>()
          .toSet();
    } catch (_) {
      return {};
    }
  }

  static bool isReversed(int bangumiId, String pluginName) =>
      _read().contains(_key(bangumiId, pluginName));

  static Future<void> setReversed(
    int bangumiId,
    String pluginName,
    bool reversed,
  ) {
    final set = _read();
    final key = _key(bangumiId, pluginName);
    reversed ? set.add(key) : set.remove(key);
    return GStorage.putSetting<String>(setting, jsonEncode(set.toList()));
  }
}

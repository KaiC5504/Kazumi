import 'dart:convert';

import 'package:kazumi/services/storage/storage.dart';

/// Speed per anime. 一起看 rooms are always 1.0×: SyncPlay doesn't share
/// speed, so a faster side would drift ~15 s a minute.
class AnimeSpeedStore {
  static Map<String, dynamic> _read() {
    try {
      return jsonDecode(GStorage.getSetting(SettingsKeys.animeSpeeds))
          as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static double speedFor(int bangumiId, {required bool inRoom}) {
    if (inRoom) return 1.0;
    final saved = (_read()['$bangumiId'] as num?)?.toDouble();
    return saved ?? GStorage.getSetting(SettingsKeys.defaultPlaySpeed);
  }

  static Future<void> remember(
    int bangumiId,
    double speed, {
    required bool inRoom,
  }) async {
    if (inRoom) return;
    final map = _read()..['$bangumiId'] = speed;
    await GStorage.putSetting<String>(
      SettingsKeys.animeSpeeds,
      jsonEncode(map),
    );
  }
}

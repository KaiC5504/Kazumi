import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/services/storage/storage.dart';

enum DanmakuSourceKind {
  bilibili('BiliBili', SettingsKeys.danmakuBiliBiliSource),
  gamer('Gamer', SettingsKeys.danmakuGamerSource),
  dandan('弹弹play', SettingsKeys.danmakuDanDanSource);

  const DanmakuSourceKind(this.label, this.settingKey);

  final String label;
  final SettingKey<bool> settingKey;

  static DanmakuSourceKind of(DanmakuEntry danmaku) =>
      danmaku.source.contains('BiliBili')
      ? bilibili
      : danmaku.source.contains('Gamer')
      ? gamer
      : dandan;

  static Map<DanmakuSourceKind, bool> enabledNow() => {
    for (final kind in values) kind: GStorage.getSetting(kind.settingKey),
  };
}

Map<DanmakuSourceKind, int> countDanmakuBySource(
  Iterable<DanmakuEntry> danmakus,
) {
  final counts = {for (final kind in DanmakuSourceKind.values) kind: 0};
  for (final danmaku in danmakus) {
    final kind = DanmakuSourceKind.of(danmaku);
    counts[kind] = counts[kind]! + 1;
  }
  return counts;
}

bool turnedOff(
  Map<DanmakuSourceKind, bool> before,
  Map<DanmakuSourceKind, bool> after,
) => DanmakuSourceKind.values.any(
  (kind) => (before[kind] ?? true) && !(after[kind] ?? true),
);

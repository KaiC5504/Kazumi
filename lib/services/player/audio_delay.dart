import 'package:kazumi/services/storage/storage.dart';

// Not in SettingsKeys.all: that list belongs to upstream's settings file.
const audioDelaySetting = SettingKey<int>(
  'audioDelayMs',
  0,
  group: SettingGroup.player,
);

const int audioDelayMinMs = -1000;
const int audioDelayMaxMs = 1000;
const int audioDelayStepMs = 10;

int normalizeAudioDelay(num ms) =>
    ((ms / audioDelayStepMs).round() * audioDelayStepMs)
        .clamp(audioDelayMinMs, audioDelayMaxMs)
        .toInt();

String formatAudioDelay(int ms) =>
    ms == 0 ? '无偏移' : '声音${ms < 0 ? '提前' : '延后'} ${ms.abs()} 毫秒';

String audioDelayMenuLabel(int ms) =>
    ms == 0 ? '音画同步' : '音画同步（${ms < 0 ? '提前' : '延后'} ${ms.abs()} 毫秒）';

/// mpv's `audio-delay` is in seconds; negative plays audio earlier, which is
/// what late Bluetooth audio needs.
String audioDelayMpvValue(int ms) => (ms / 1000).toStringAsFixed(3);

import 'package:flutter/foundation.dart';
import 'package:kazumi/modules/collect/collect_layout.dart';
import 'package:kazumi/pages/video/episode_layout.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 经典布局: denser screens, close to the layout before upstream's 2.3.1
/// redesign. Off by default, so nobody's app changes until they turn it on.
abstract final class ClassicLayout {
  // Not in SettingsKeys.all: that list belongs to upstream's settings file.
  static const setting = SettingKey<bool>(
    'classicLayout',
    false,
    group: SettingGroup.interface,
  );

  static ValueNotifier<bool>? _enabled;

  /// Tab pages stay mounted under the settings page, so they listen.
  static ValueListenable<bool> get listenable =>
      _enabled ??= ValueNotifier(GStorage.getSetting(setting));

  static bool get enabled => listenable.value;

  /// Screens with their own layout choice get the matching preset; the user
  /// can still change each one afterwards.
  static Future<void> set(bool enabled) async {
    await GStorage.putSetting(setting, enabled);
    await GStorage.putSetting(
      SettingsKeys.defaultCollectLayout,
      (enabled ? CollectLayout.cards : CollectLayout.list).name,
    );
    await EpisodeLayout.save(enabled ? EpisodeLayout.grid : EpisodeLayout.auto);
    (_enabled ??= ValueNotifier(enabled)).value = enabled;
  }

  @visibleForTesting
  static void debugReset() => _enabled = null;
}

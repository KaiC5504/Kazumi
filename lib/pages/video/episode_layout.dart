import 'package:flutter/material.dart';
import 'package:kazumi/services/storage/storage.dart';

/// How the video page lays out a road's episodes. One choice for every show.
enum EpisodeLayout {
  auto('自动', Icons.auto_awesome_mosaic_rounded),
  grid('网格', Icons.grid_view_rounded),
  list('列表', Icons.view_agenda_rounded),
  compact('紧凑', Icons.apps_rounded);

  const EpisodeLayout(this.label, this.icon);

  final String label;
  final IconData icon;

  // Not in SettingsKeys.all: that list belongs to upstream's settings file.
  static const setting = SettingKey<String>(
    'episodeLayout',
    'auto',
    group: SettingGroup.interface,
  );

  static EpisodeLayout fromValue(String value) =>
      values.firstWhere((layout) => layout.name == value, orElse: () => auto);

  static EpisodeLayout get saved => fromValue(GStorage.getSetting(setting));

  /// Widget tests replace the write: a Hive write started inside fake async
  /// never finishes and blocks the settings box for every later test.
  @visibleForTesting
  static Future<void> Function(EpisodeLayout layout)? debugOnSave;

  static Future<void> save(EpisodeLayout layout) =>
      debugOnSave?.call(layout) ?? GStorage.putSetting(setting, layout.name);
}

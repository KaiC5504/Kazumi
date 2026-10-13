import 'package:kazumi/modules/history/history_module.dart';

/// Labels like "看到 第3集" keyed by bangumi id.
///
/// History is stored per source, so the most recently watched record wins.
/// The episode keeps the source's own name so it matches the episode list.
Map<int, String> collectWatchProgress(Iterable<History> histories) {
  final latest = <int, History>{};
  for (final history in histories) {
    final id = history.bangumiItem.id;
    final existing = latest[id];
    if (existing == null ||
        existing.lastWatchTime.isBefore(history.lastWatchTime)) {
      latest[id] = history;
    }
  }
  return latest.map((id, history) {
    final name = history.lastWatchEpisodeName.trim();
    return MapEntry(
      id,
      '看到 ${name.isEmpty ? '第 ${history.lastWatchEpisode} 集' : name}',
    );
  });
}

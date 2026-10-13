import 'package:kazumi/modules/history/history_module.dart';

final _digitsOnly = RegExp(r'^\d+$');
final _hasDigit = RegExp(r'\d');

/// Labels like "看到 第 3 话" keyed by bangumi id.
///
/// History is stored per source, so the most recently watched record wins.
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
  return latest.map((id, history) => MapEntry(id, '看到 ${_episodeOf(history)}'));
}

String _episodeOf(History history) {
  final name = history.lastWatchEpisodeName.trim();
  // Keep names like "第03集". A bare "07" reads badly on its own, and an
  // episode title doesn't say which episode it is.
  if (!_hasDigit.hasMatch(name) || _digitsOnly.hasMatch(name)) {
    return '第 ${history.lastWatchEpisode} 话';
  }
  return name;
}

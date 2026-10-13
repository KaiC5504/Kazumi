import 'package:kazumi/modules/history/history_module.dart';

final _numberAfterDi = RegExp(r'第\s*(\d{1,4}(?:\.\d+)?)');
final _leadingNumber = RegExp(
  r'^\s*(?:EP|E|#)?\s*(\d{1,4}(?:\.\d+)?)(?=$|[\s.:：、_-])',
  caseSensitive: false,
);

/// Labels like "看到 第 3 集" keyed by bangumi id.
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
  return latest.map(
    (id, history) => MapEntry(id, '看到 第 ${_episodeOf(history)} 集'),
  );
}

// Sources name episodes "第03话", "EP03", "03" or by title. Their number is
// preferred over lastWatchEpisode, which is only the position in the list.
String _episodeOf(History history) {
  final name = history.lastWatchEpisodeName;
  final number =
      _numberAfterDi.firstMatch(name)?.group(1) ??
      _leadingNumber.firstMatch(name)?.group(1);
  if (number == null) return '${history.lastWatchEpisode}';
  return number.contains('.')
      ? number.replaceFirst(RegExp(r'^0+(?=\d)'), '')
      : '${int.parse(number)}';
}

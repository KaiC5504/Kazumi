import 'package:kazumi/modules/bangumi/episode_item.dart';

class ReminderShow {
  const ReminderShow(this.bangumiId, this.name, this.episodes);
  final int bangumiId;
  final String name;
  final List<EpisodeInfo> episodes;
}

class PlannedReminder {
  const PlannedReminder({
    required this.id,
    required this.bangumiId,
    required this.title,
    required this.body,
    required this.fireAtLocal,
  });

  final int id;
  final int bangumiId;
  final String title;
  final String body;
  final DateTime fireAtLocal;
}

/// Reminder ids live above 1e9 so cancelling them never touches other
/// notifications.
int reminderId(int bangumiId, num ep) =>
    1000000000 + ((bangumiId * 2000 + ep.toInt()) % 1000000000);

/// Bangumi only has the Japanese air date, and Chinese sources usually
/// carry a late-night episode by the next morning.
List<PlannedReminder> planReminders({
  required List<ReminderShow> shows,
  required DateTime nowLocal,
  int cap = 60,
}) {
  final plan = <PlannedReminder>[];
  for (final show in shows) {
    for (final e in show.episodes) {
      if (e.type != 0) continue;
      final aired = DateTime.tryParse(e.airdate);
      if (aired == null) continue;
      final fireAt = DateTime(aired.year, aired.month, aired.day + 1, 10);
      if (!fireAt.isAfter(nowLocal)) continue;
      final number = e.ep == 0 ? e.episode : e.ep;
      plan.add(
        PlannedReminder(
          id: reminderId(show.bangumiId, number),
          bangumiId: show.bangumiId,
          title: '《${show.name}》第 $number 话 已更新',
          body: '点开去看',
          fireAtLocal: fireAt,
        ),
      );
    }
  }
  plan.sort((a, b) => a.fireAtLocal.compareTo(b.fireAtLocal));
  return plan.take(cap).toList();
}

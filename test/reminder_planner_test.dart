import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/services/reminder/reminder_planner.dart';

EpisodeInfo ep(num n, String airdate, {int type = 0}) => EpisodeInfo(
  id: n.toInt(),
  episode: n,
  ep: n,
  type: type,
  name: '',
  nameCn: '',
  airdate: airdate,
);

void main() {
  final now = DateTime(2026, 10, 7, 21);

  test('day after the JP air date at 10:00 local; past ones dropped', () {
    final plan = planReminders(
      shows: [
        ReminderShow(1, '葬送的芙莉莲', [
          ep(13, '2026-10-01'),
          ep(14, '2026-10-08'),
          ep(15, '2026-10-15'),
        ]),
      ],
      nowLocal: now,
    );
    expect(plan.map((p) => p.fireAtLocal), [
      DateTime(2026, 10, 9, 10),
      DateTime(2026, 10, 16, 10),
    ]);
    expect(plan.first.title, '《葬送的芙莉莲》第 14 话 已更新');
    expect(plan.first.body, '点开去看');
  });

  test('today\'s 10:00 already passed is dropped', () {
    final plan = planReminders(
      shows: [
        ReminderShow(1, 'A', [ep(1, '2026-10-06')]),
      ],
      nowLocal: now,
    );
    expect(plan, isEmpty);
  });

  test('specials, empty and bad dates are skipped', () {
    final plan = planReminders(
      shows: [
        ReminderShow(1, 'A', [
          ep(0, '2026-10-20', type: 1),
          ep(2, ''),
          ep(3, 'soon'),
          ep(4, '2026-10-20'),
        ]),
      ],
      nowLocal: now,
    );
    expect(plan.map((p) => p.title), ['《A》第 4 话 已更新']);
  });

  test('soonest 60 across shows, sorted', () {
    final shows = [
      for (var s = 0; s < 10; s++)
        ReminderShow(s, 'S$s', [
          for (var e = 1; e <= 12; e++)
            ep(
              e,
              DateTime(2026, 10, 8)
                  .add(Duration(days: 7 * e + s))
                  .toIso8601String()
                  .substring(0, 10),
            ),
        ]),
    ];
    final plan = planReminders(shows: shows, nowLocal: now);
    expect(plan, hasLength(60));
    for (var i = 1; i < plan.length; i++) {
      expect(plan[i].fireAtLocal.isBefore(plan[i - 1].fireAtLocal), isFalse);
    }
  });

  test('ids are stable and distinct', () {
    expect(reminderId(375817, 14), reminderId(375817, 14));
    expect(reminderId(375817, 14), isNot(reminderId(375817, 15)));
    expect(reminderId(375817, 14), greaterThanOrEqualTo(1000000000));
  });
}

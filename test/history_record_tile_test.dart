import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_tag.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/pages/history/history_record_tile.dart';

History _history() => History(
  BangumiItem(
    id: 1,
    type: 2,
    name: 'Fate/stay night',
    nameCn: '剧场版 Fate/stay night [Heaven\'s Feel] III.spring song',
    summary: '',
    airDate: '2020-08-15',
    airWeekday: 6,
    rank: 0,
    images: const {'large': ''},
    tags: const <BangumiTag>[],
    alias: const [],
    ratingScore: 0,
    votes: 0,
    votesCount: const [],
    info: '',
  ),
  1,
  'xfdmnext',
  DateTime(2026, 10, 8, 0, 43),
  '',
  '第1话',
);

Widget _host({double textScale = 1}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(
      size: const Size(440, 956),
      textScaler: TextScaler.linear(textScale),
    ),
    child: Scaffold(
      body: HistoryRecordTile(
        history: _history(),
        onPlay: () {},
        onDetails: () {},
        onDelete: () async {},
        collectType: CollectType.none,
        onChangeCollect: null,
      ),
    ),
  ),
);

int? _titleLines(WidgetTester tester) =>
    tester.widget<Text>(find.textContaining('Heaven\'s Feel')).maxLines;

void main() {
  testWidgets('a record is one title line plus one detail line', (
    tester,
  ) async {
    await tester.pumpWidget(_host());

    expect(_titleLines(tester), 1);
    expect(find.textContaining('xfdmnext', findRichText: true), findsOneWidget);
    expect(tester.getSize(find.byType(HistoryRecordTile)).height, lessThan(90));
  });

  testWidgets('large text keeps the roomy layout', (tester) async {
    await tester.pumpWidget(_host(textScale: 2));

    expect(_titleLines(tester), 2);
    expect(tester.takeException(), isNull);
  });
}

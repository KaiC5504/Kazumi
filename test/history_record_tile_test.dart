import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_tag.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/pages/history/history_record_tile.dart';

History _history({String episode = '第1话', String? title}) =>
    History(
        BangumiItem(
          id: 1,
          type: 2,
          name: 'Fate/stay night',
          nameCn:
              title ?? "剧场版 Fate/stay night [Heaven's Feel] III.spring song",
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
        episode,
      )
      ..progresses[1] = Progress(
        1,
        0,
        const Duration(hours: 1, minutes: 44, seconds: 41).inMilliseconds,
      );

Widget _host({double textScale = 1, String episode = '第1话', String? title}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(440, 956),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: HistoryRecordTile(
            history: _history(episode: episode, title: title),
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

bool _cut(WidgetTester tester, Finder text) =>
    tester.renderObject<RenderParagraph>(text).didExceedMaxLines;

void main() {
  testWidgets('a short record stays one row tall', (tester) async {
    await tester.pumpWidget(_host(title: 'Fate/Zero'));

    expect(find.textContaining('xfdmnext', findRichText: true), findsOneWidget);
    expect(tester.getSize(find.byType(HistoryRecordTile)).height, lessThan(90));
  });

  testWidgets('a long episode name never hides where she stopped', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(episode: "Fate/stay night [Heaven's Feel] III.spring song 完整版"),
    );

    final position = find.textContaining('看到 1:44:41', findRichText: true);
    expect(position, findsOneWidget);
    expect(_cut(tester, position), isFalse);
    expect(_cut(tester, find.textContaining('III.spring song 完整版')), isFalse);
  });

  testWidgets('large text keeps the roomy layout', (tester) async {
    await tester.pumpWidget(_host(textScale: 2));

    expect(_titleLines(tester), 2);
    expect(tester.takeException(), isNull);
  });
}

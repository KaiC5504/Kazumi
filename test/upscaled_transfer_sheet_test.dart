import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/download/upscaled_transfer_sheets.dart';
import 'package:kazumi/services/skip/skip_segments.dart';
import 'package:kazumi/services/upscale/upscaled_package.dart';

UpscaledTransferItem _item(
  int bangumiId,
  String name,
  int episode, {
  bool upToDate = false,
}) => UpscaledTransferItem(
  manifest: UpscaledEpisodeManifest(
    bangumiId: bangumiId,
    pluginName: 'aafun',
    bangumiName: name,
    bangumiCover: '',
    episodeNumber: episode,
    episodeName: '',
    road: 0,
    episodePageUrl: '',
    danDanBangumiID: 0,
    tier: 'quality',
    width: 0,
    height: 1440,
    sizeBytes: 1000,
    hasDanmaku: false,
    skipSegments: SkipSegments.empty,
  ),
  replaces: false,
  upToDate: upToDate,
);

Future<List<int>> _pump(
  WidgetTester tester,
  List<UpscaledTransferItem> items,
) async {
  final ran = <int>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: UpscaledTransferSheet(
          title: '从电脑拉取',
          actionLabel: '开始拉取',
          items: items,
          run: (index, _) async => ran.add(index),
          doneMessage: (count) => '$count',
        ),
      ),
    ),
  );
  return ran;
}

void main() {
  // Mixed order on purpose: shows group together, episodes sort by number.
  final items = [
    _item(1, '冰菓', 2),
    _item(2, 'Fate', 1),
    _item(1, '冰菓', 1, upToDate: true),
    _item(2, 'Fate', 2),
  ];

  testWidgets('one card per show, nothing selected at first', (tester) async {
    await _pump(tester, items);
    expect(find.text('冰菓'), findsOneWidget);
    expect(find.text('Fate'), findsOneWidget);
    expect(find.text('已选 0 集 · 0 B'), findsOneWidget);
    expect(find.text('0/2 已选'), findsNWidgets(2));
  });

  testWidgets('show checkbox picks that show only, skipping up-to-date', (
    tester,
  ) async {
    final ran = await _pump(tester, items);
    final fateCheckbox = find.descendant(
      of: find.ancestor(of: find.text('Fate'), matching: find.byType(Card)),
      matching: find.byType(Checkbox),
    );
    await tester.tap(fateCheckbox);
    await tester.pump();
    expect(find.textContaining('2/2 已选'), findsOneWidget);
    expect(find.text('0/2 已选'), findsOneWidget);

    await tester.tap(find.text('开始拉取'));
    await tester.pumpAndSettle();
    expect(ran, [1, 3]);
  });

  testWidgets('全选 leaves up-to-date episodes out, 全不选 clears', (tester) async {
    await _pump(tester, items);
    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(find.textContaining('已选 3 集'), findsOneWidget);
    // 冰菓 has one fresh and one up-to-date episode, so its box is partial.
    final iceCheckbox = tester.widget<Checkbox>(
      find.descendant(
        of: find.ancestor(of: find.text('冰菓'), matching: find.byType(Card)),
        matching: find.byType(Checkbox),
      ),
    );
    expect(iceCheckbox.value, isNull);

    await tester.tap(find.text('全不选'));
    await tester.pump();
    expect(find.textContaining('已选 0 集'), findsOneWidget);
  });

  testWidgets('expanding a show lists its episodes in order', (tester) async {
    await _pump(tester, items);
    await tester.tap(find.text('冰菓'));
    await tester.pumpAndSettle();
    final tiles = tester
        .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
        .map((t) => (t.title as Text).data)
        .toList();
    expect(tiles, [
      items[2].manifest.displayEpisodeName,
      items[0].manifest.displayEpisodeName,
    ]);
  });
}

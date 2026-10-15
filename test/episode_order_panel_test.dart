import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/pages/video/episode_selection_panel.dart';

import 'support/syncplay_sim.dart' show setUpSyncplayStorage;

Widget panel({
  required bool reversed,
  required void Function(int, int) onSelect,
  VoidCallback? onToggle,
  bool offline = false,
}) {
  final road = Road(
    name: '线路1',
    data: [for (var i = 1; i <= 3; i++) 'https://x/$i'],
    identifier: ['第3集', '第2集', '第1集'],
  );
  return MaterialApp(
    home: Scaffold(
      body: EpisodeSelectionPanel(
        title: 'T',
        roads: [road],
        selectedRoad: 0,
        selectedEpisode: 1,
        downloads: const {},
        onEpisodeSelected: onSelect,
        isOffline: offline,
        reversed: reversed,
        onToggleOrder: onToggle,
      ),
    ),
  );
}

// Compares the cells, not the texts: the selected cell's name sits higher
// because of its "当前选集" line.
bool before(WidgetTester tester, String a, String b) {
  Offset cell(String name) => tester.getTopLeft(
    find.ancestor(of: find.text(name), matching: find.byType(InkWell)).first,
  );
  final pa = cell(a);
  final pb = cell(b);
  return pa.dy < pb.dy || (pa.dy == pb.dy && pa.dx < pb.dx);
}

void main() {
  setUpSyncplayStorage();

  testWidgets('source order when not flipped', (tester) async {
    int? picked;
    await tester.pumpWidget(
      panel(reversed: false, onSelect: (e, _) => picked = e),
    );
    await tester.pumpAndSettle();
    expect(before(tester, '第3集', '第1集'), isTrue);
    await tester.tap(find.text('第1集'));
    expect(picked, 3);
    expect(find.textContaining('倒序'), findsNothing);
  });

  testWidgets('flipped: back to front, same positions, marked', (tester) async {
    int? picked;
    await tester.pumpWidget(
      panel(reversed: true, onSelect: (e, _) => picked = e),
    );
    await tester.pumpAndSettle();
    expect(before(tester, '第1集', '第3集'), isTrue);
    await tester.tap(find.text('第1集'));
    expect(picked, 3);
    expect(find.text('全部剧集 · 3 集 · 倒序'), findsOneWidget);
  });

  testWidgets('the order button calls back', (tester) async {
    var toggles = 0;
    await tester.pumpWidget(
      panel(reversed: false, onSelect: (_, _) {}, onToggle: () => toggles++),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('切换为倒序'));
    expect(toggles, 1);
  });

  testWidgets('offline lists can be flipped too', (tester) async {
    await tester.pumpWidget(
      panel(
        reversed: false,
        onSelect: (_, _) {},
        onToggle: () {},
        offline: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('切换为倒序'), findsOneWidget);
  });

  testWidgets('no button without a callback', (tester) async {
    await tester.pumpWidget(panel(reversed: false, onSelect: (_, _) {}));
    await tester.pumpAndSettle();
    expect(find.byTooltip('切换为倒序'), findsNothing);
  });
}

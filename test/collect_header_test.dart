import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_tag.dart';
import 'package:kazumi/modules/collect/collect_layout.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/pages/collect/collect_library_view.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const _statusBar = 47.0;

void main() {
  late Directory directory;

  // The title bar reads window settings.
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('kazumi_collect_test_');
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Future<void> pumpLibrary(
    WidgetTester tester, {
    required Size size,
    TargetPlatform platform = TargetPlatform.iOS,
    CollectLayout layout = CollectLayout.list,
    bool classic = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: _statusBar);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          body: CollectLibraryView(
            title: '追番',
            entries: [
              for (var i = 1; i <= 40; i++)
                CollectedBangumi(
                  _item(i),
                  DateTime(2026, 10, 1).subtract(Duration(minutes: i)),
                  CollectType.watching.value,
                ),
            ],
            showRating: false,
            layout: layout,
            classic: classic,
            onLayoutChanged: (_) {},
            canEdit: (_) => true,
            onOpen: (_) {},
            onChangeType: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder watchingList() => find.byKey(
    PageStorageKey('collect-results-${CollectType.watching.value}'),
  );

  double tabsTop(WidgetTester tester) => tester.getTopLeft(_tab('在看')).dy;

  group('追番 on a phone', () {
    testWidgets('the title bar scrolls away and the tabs stay pinned', (
      tester,
    ) async {
      await pumpLibrary(tester, size: const Size(390, 844));
      expect(find.text('追番').hitTestable(), findsOneWidget);
      final restingTabs = tabsTop(tester);

      await tester.drag(watchingList(), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(find.text('追番').hitTestable(), findsNothing);
      expect(tabsTop(tester), restingTabs - 72);
      expect(tabsTop(tester), greaterThan(_statusBar));
      expect(_tab('在看').hitTestable(), findsOneWidget);
    });

    testWidgets('a small scroll back up does not bring the title back', (
      tester,
    ) async {
      await pumpLibrary(tester, size: const Size(390, 844));
      await tester.drag(watchingList(), const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.drag(watchingList(), const Offset(0, 120));
      await tester.pumpAndSettle();
      expect(find.text('追番').hitTestable(), findsNothing);

      await tester.fling(watchingList(), const Offset(0, 3000), 4000);
      await tester.pumpAndSettle();
      expect(find.text('追番').hitTestable(), findsOneWidget);
    });

    testWidgets('sort and layout live in one menu next to search', (
      tester,
    ) async {
      await pumpLibrary(tester, size: const Size(390, 844));
      expect(find.byTooltip('搜索收藏'), findsOneWidget);
      await tester.tap(find.byTooltip('排序与布局'));
      await tester.pumpAndSettle();
      expect(find.text('番剧名称'), findsOneWidget);
      expect(find.text('列表布局'), findsOneWidget);
      expect(find.text('卡片布局'), findsOneWidget);
    });

    // SysAppBar centres titles on iOS; a title row that fills its slot stays
    // at the start there too.
    testWidgets('the title fills its slot so iOS cannot centre it', (
      tester,
    ) async {
      await pumpLibrary(tester, size: const Size(390, 844));
      final row = find
          .ancestor(of: find.text('追番'), matching: find.byType(Row))
          .first;
      expect(tester.getSize(row).width, greaterThan(200));
      expect(tester.getTopLeft(find.text('追番')).dx, lessThan(24));
    });

    testWidgets('the first show starts below the header', (tester) async {
      await pumpLibrary(tester, size: const Size(390, 844));
      final header = tester.getBottomLeft(_tab('在看')).dy;
      expect(tester.getTopLeft(find.text('条目 1')).dy, greaterThan(header));
    });
  });

  group('追番 on wider screens', () {
    for (final (name, size, platform) in [
      ('iPad portrait', const Size(820, 1180), TargetPlatform.iOS),
      ('iPad landscape', const Size(1180, 820), TargetPlatform.iOS),
      ('Windows', const Size(1280, 800), TargetPlatform.windows),
    ]) {
      testWidgets('$name: the title bar scrolls away, tabs stay pinned', (
        tester,
      ) async {
        await pumpLibrary(
          tester,
          size: size,
          platform: platform,
          layout: CollectLayout.cards,
        );
        expect(find.text('追番').hitTestable(), findsOneWidget);
        final restingTabs = tabsTop(tester);

        await tester.drag(watchingList(), const Offset(0, -400));
        await tester.pumpAndSettle();
        expect(find.text('追番').hitTestable(), findsNothing);
        expect(tabsTop(tester), restingTabs - 72);
        expect(_tab('在看').hitTestable(), findsOneWidget);
      });
    }
  });

  group('经典布局 card grid', () {
    int columns(WidgetTester tester) {
      final first = tester.getTopLeft(find.text('条目 1')).dy;
      var count = 0;
      for (var i = 1; i <= 12; i++) {
        final title = find.text('条目 $i');
        if (title.evaluate().isEmpty) break;
        if (tester.getTopLeft(title).dy != first) break;
        count++;
      }
      return count;
    }

    for (final (size, expected) in [
      (const Size(390, 844), 3),
      (const Size(800, 1280), 5),
      (const Size(1280, 800), 6),
    ]) {
      testWidgets('${size.width.toInt()} px wide shows $expected columns', (
        tester,
      ) async {
        await pumpLibrary(
          tester,
          size: size,
          layout: CollectLayout.cards,
          classic: true,
        );
        expect(columns(tester), expected);
      });
    }

    testWidgets('each poster keeps its status menu', (tester) async {
      await pumpLibrary(
        tester,
        size: const Size(390, 844),
        layout: CollectLayout.cards,
        classic: true,
      );
      await tester.tap(find.byTooltip('管理《条目 1》 · 在看'));
      await tester.pumpAndSettle();
      expect(find.text('取消收藏'), findsOneWidget);
    });
  });

  testWidgets('Ctrl+F opens search on Windows', (tester) async {
    await pumpLibrary(
      tester,
      size: const Size(1280, 800),
      platform: TargetPlatform.windows,
    );
    expect(find.byType(SearchBar), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byType(SearchBar), findsOneWidget);
    expect(find.byTooltip('排序与布局'), findsOneWidget);
  });
}

BangumiItem _item(int id) {
  return BangumiItem(
    id: id,
    type: 2,
    name: 'subject $id',
    nameCn: '条目 $id',
    summary: '',
    airDate: '2026-01-01',
    airWeekday: 4,
    rank: 0,
    images: const {'large': '', 'common': '', 'medium': '', 'small': ''},
    tags: const <BangumiTag>[],
    alias: const [],
    ratingScore: 0,
    votes: 0,
    votesCount: const [],
    info: '',
  );
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

Finder _tab(String label) =>
    find.descendant(of: find.byType(TabBar), matching: find.text(label));

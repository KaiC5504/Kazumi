// 经典布局 and the episode layouts only redraw 追番, 我的 and the episode
// picker; the fork's extras on those screens must work in every style.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_tag.dart';
import 'package:kazumi/modules/collect/collect_layout.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/modules/my/watch_stats.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/pages/collect/collect_library_view.dart';
import 'package:kazumi/pages/my/my_space_view.dart';
import 'package:kazumi/pages/video/episode_layout.dart';
import 'package:kazumi/pages/video/episode_selection_panel.dart';
import 'package:kazumi/services/layout/classic_layout.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('kazumi_layouts_test_');
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  void phone(WidgetTester tester, [Size size = const Size(390, 844)]) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  group('追番 in every layout', () {
    for (final (name, layout, classic) in [
      ('列表', CollectLayout.list, false),
      ('卡片', CollectLayout.cards, false),
      ('经典布局', CollectLayout.cards, true),
    ]) {
      testWidgets('$name shows where you stopped and changes the status', (
        tester,
      ) async {
        phone(tester);
        final changes = <(int, CollectType)>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.iOS),
            home: Scaffold(
              body: CollectLibraryView(
                title: '追番',
                entries: [
                  for (var i = 1; i <= 6; i++)
                    CollectedBangumi(
                      _item(i),
                      DateTime(2026, 10, 1).subtract(Duration(minutes: i)),
                      CollectType.watching.value,
                    ),
                ],
                watchProgress: const {1: '看到 第3集'},
                showRating: false,
                layout: layout,
                classic: classic,
                onLayoutChanged: (_) {},
                canEdit: (_) => true,
                onOpen: (_) {},
                onChangeType: (item, type) => changes.add((item.id, type)),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('看到 第3集'), findsOneWidget);

        await tester.tap(
          find
              .byWidgetPredicate(
                (w) => w is Tooltip && (w.message?.contains('《条目 1》') ?? false),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(MenuItemButton, '看过'));
        await tester.pumpAndSettle();
        expect(changes, [(1, CollectType.watched)]);
      });
    }
  });

  group('episode picker in every layout', () {
    setUp(() => GStorage.resetSettings([EpisodeLayout.setting]));
    tearDown(() => GStorage.resetSettings([EpisodeLayout.setting]));

    Future<List<(int, int)>> pumpPanel(
      WidgetTester tester,
      EpisodeLayout layout, {
      required int episodes,
      required int selected,
      Map<String, DownloadEpisode> downloads = const {},
    }) async {
      // Outside fake async, where a Hive write can finish.
      await tester.runAsync(
        () => GStorage.putSetting(EpisodeLayout.setting, layout.name),
      );
      phone(tester, const Size(440, 956));
      final picked = <(int, int)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EpisodeSelectionPanel(
              title: '测试番剧',
              roads: [
                Road(
                  name: '播放列表1',
                  data: [for (var i = 1; i <= episodes; i++) 'ep$i'],
                  identifier: const [],
                ),
              ],
              selectedRoad: 0,
              selectedEpisode: selected,
              onEpisodeSelected: (episode, road) => picked.add((episode, road)),
              downloads: downloads,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return picked;
    }

    for (final layout in EpisodeLayout.values) {
      testWidgets('${layout.label} marks the current and cached episodes', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        final picked = await pumpPanel(
          tester,
          layout,
          episodes: 12,
          selected: 2,
          downloads: {
            'ep3': _download(3, DownloadStatus.completed),
            'ep4': _download(4, DownloadStatus.failed),
          },
        );
        expect(find.byTooltip('选集布局：${layout.label}'), findsOneWidget);
        expect(find.bySemanticsLabel('第2集，当前选集'), findsOneWidget);
        expect(find.bySemanticsLabel('第3集，播放，已缓存'), findsOneWidget);
        expect(find.bySemanticsLabel('第4集，播放，缓存失败'), findsOneWidget);
        await tester.tap(find.text('第5集'));
        expect(picked, [(5, 0)]);
        semantics.dispose();
      });

      testWidgets('${layout.label} brings a far episode into view', (
        tester,
      ) async {
        await pumpPanel(tester, layout, episodes: 120, selected: 100);
        expect(find.text('第100集').hitTestable(), findsNothing);
        await tester.tap(find.byTooltip('定位当前集'));
        await tester.pumpAndSettle();
        expect(find.text('第100集').hitTestable(), findsOneWidget);
      });
    }
  });

  group('我的 in both styles', () {
    tearDown(() async {
      await GStorage.resetSettings([
        ClassicLayout.setting,
        EpisodeLayout.setting,
        SettingsKeys.defaultCollectLayout,
      ]);
      ClassicLayout.debugReset();
    });

    Future<Set<MyDestination>> pumpSpace(
      WidgetTester tester, {
      required bool classic,
      List<History> recent = const [],
    }) async {
      await tester.runAsync(() => ClassicLayout.set(classic));
      phone(tester, const Size(1200, 2400));
      final opened = <MyDestination>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MySpaceView(
              stats: const WatchStats(),
              recent: recent,
              onOpen: opened.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return opened;
    }

    for (final classic in [false, true]) {
      final style = classic ? '经典布局' : '新版';

      testWidgets('$style reaches every page at 1200 px', (tester) async {
        final opened = await pumpSpace(tester, classic: classic);
        for (final label in [
          '历史记录',
          '离线下载',
          '一起看',
          '规则设置',
          ...classic ? ['外观设置', '播放设置', '弹幕设置'] : ['外观', '播放', '弹幕'],
          '同步备份',
          '存储管理',
          '关于 Kazumi',
        ]) {
          await tester.tap(find.text(label));
          await tester.pump();
        }
        expect(opened, MyDestination.values.toSet());
      });

      testWidgets('$style keeps the 继续观看 row', (tester) async {
        final opened = await pumpSpace(
          tester,
          classic: classic,
          recent: [
            History(_item(7), 3, 'aafun', DateTime(2026, 10, 1), '', '第3集'),
          ],
        );
        expect(find.text('继续观看'), findsOneWidget);
        await tester.tap(find.text('全部历史'));
        expect(opened, {MyDestination.history});
      });
    }
  });
}

DownloadEpisode _download(int episode, int status) => DownloadEpisode(
  episode,
  'ep$episode',
  0,
  status,
  status == DownloadStatus.completed ? 1 : 0,
  1,
  status == DownloadStatus.completed ? 1 : 0,
  '',
  '',
  '',
  null,
  '',
  0,
  '',
);

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

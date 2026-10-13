import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/pages/video/episode_layout.dart';
import 'package:kazumi/services/layout/classic_layout.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('kazumi_classic_test_');
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });

  setUp(() async {
    ClassicLayout.debugReset();
    await GStorage.resetSettings([
      ClassicLayout.setting,
      EpisodeLayout.setting,
      SettingsKeys.defaultCollectLayout,
    ]);
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('off by default, so nobody gets it without asking', () {
    expect(ClassicLayout.enabled, isFalse);
    expect(EpisodeLayout.saved, EpisodeLayout.auto);
    expect(GStorage.getSetting(SettingsKeys.defaultCollectLayout), 'list');
  });

  test('turning it on sets the poster grid and the episode grid', () async {
    var notified = 0;
    ClassicLayout.listenable.addListener(() => notified++);

    await ClassicLayout.set(true);

    expect(ClassicLayout.enabled, isTrue);
    expect(notified, 1);
    expect(EpisodeLayout.saved, EpisodeLayout.grid);
    expect(GStorage.getSetting(SettingsKeys.defaultCollectLayout), 'cards');
  });

  test('turning it off goes back to the new defaults', () async {
    await ClassicLayout.set(true);
    await ClassicLayout.set(false);

    expect(ClassicLayout.enabled, isFalse);
    expect(EpisodeLayout.saved, EpisodeLayout.auto);
    expect(GStorage.getSetting(SettingsKeys.defaultCollectLayout), 'list');
  });

  test('the choice survives a restart', () async {
    await ClassicLayout.set(true);
    ClassicLayout.debugReset();
    expect(ClassicLayout.enabled, isTrue);
  });
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

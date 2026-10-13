import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/plugin/plugin_http_module.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/plugin/official_rules_sync.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  late Directory directory;
  late PathProviderPlatform originalPathProvider;
  late Map<String, String> catalog;
  late Set<String> failing;

  PluginHTTPItem item(String name, String version) => PluginHTTPItem(
    name: name,
    version: version,
    useNativePlayer: true,
    author: 'test',
    lastUpdate: 0,
  );

  Plugin plugin(String name, String version) => Plugin.fromTemplate()
    ..name = name
    ..version = version;

  PluginsController controller() => PluginsController(
    catalogLoader: () async => [
      for (final entry in catalog.entries) item(entry.key, entry.value),
    ],
    pluginLoader: (name) async {
      if (failing.contains(name)) throw const SocketException('offline');
      return plugin(name, catalog[name]!);
    },
    pluginJsonWriter: (_) async {},
    errorReporter: (_, __, ___) {},
  );

  List<String> names(PluginsController c) =>
      c.pluginList.map((p) => p.name).toList();

  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp('kazumi_rules_test_');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });

  setUp(() async {
    await GStorage.putSetting(SettingsKeys.officialRulesKnown, '');
    catalog = {'AGE': '1.5', 'DM84': '1.4', 'MXdm': '2.4'};
    failing = {};
  });

  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = originalPathProvider;
    await directory.delete(recursive: true);
  });

  test('installs every official rule that is missing', () async {
    final c = controller()..pluginList.add(plugin('dm84', '1.4'));

    final result = await syncOfficialRules(c, updateExisting: false);

    expect(result.installed, 2);
    expect(names(c), unorderedEquals(['dm84', 'AGE', 'MXdm']));
  });

  test('the first sync puts the best measured sources first', () async {
    catalog = {'akianime': '1.0', 'ezdmw': '1.0', 'AGE': '1.5'};
    final c = controller()..pluginList.add(plugin('baimao', '1.0'));

    await syncOfficialRules(c, updateExisting: false);

    // Measured first, untested next, blocked last.
    expect(names(c), ['AGE', 'ezdmw', 'baimao', 'akianime']);
  });

  test('the hand-picked sources lead, in their order', () async {
    catalog = {
      'akianime': '1.0',
      'MXdm': '2.4',
      'AGE': '1.5',
      'aafun': '1.2',
      'xfdmnext': '1.1',
      '7sefun': '1.3',
    };
    final c = controller();

    await syncOfficialRules(c, updateExisting: false);

    expect(names(c), [
      'xfdmnext',
      'aafun',
      '7sefun',
      'MXdm',
      'AGE',
      'akianime',
    ]);
  });

  test('later syncs keep the order the user chose', () async {
    final c = controller();
    await syncOfficialRules(c, updateExisting: false);
    await c.onReorder(c.pluginList.length - 1, 0);
    final chosen = names(c);
    catalog['akianime'] = '1.0';

    await syncOfficialRules(c, updateExisting: false);

    expect(names(c), [...chosen, 'akianime']);
  });

  test('does not bring back a rule the user deleted', () async {
    final c = controller();
    await syncOfficialRules(c, updateExisting: false);
    await c.removePlugin(c.pluginList.firstWhere((p) => p.name == 'AGE'));

    final result = await syncOfficialRules(c, updateExisting: false);

    expect(result.installed, 0);
    expect(names(c), ['DM84', 'MXdm']);
  });

  test('installs rules added to the catalog later', () async {
    final c = controller();
    await syncOfficialRules(c, updateExisting: false);
    catalog['sorani'] = '1.0';

    final result = await syncOfficialRules(c, updateExisting: false);

    expect(result.installed, 1);
    expect(names(c), contains('sorani'));
  });

  test('retries a rule whose download failed', () async {
    final c = controller();
    failing = {'MXdm'};
    await syncOfficialRules(c, updateExisting: false);
    expect(names(c), isNot(contains('MXdm')));

    failing = {};
    final result = await syncOfficialRules(c, updateExisting: false);

    expect(result.installed, 1);
    expect(names(c), contains('MXdm'));
  });

  test('updates outdated rules only when asked', () async {
    final c = controller()..pluginList.add(plugin('AGE', '1.0'));
    String age() => c.pluginList.firstWhere((p) => p.name == 'AGE').version;

    var result = await syncOfficialRules(c, updateExisting: false);
    expect(result.updated, 0);
    expect(age(), '1.0');

    result = await syncOfficialRules(c, updateExisting: true);
    expect(result.updated, 1);
    expect(age(), '1.5');
  });
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

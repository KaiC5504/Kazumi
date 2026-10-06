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
    expect(names(c), ['dm84', 'AGE', 'MXdm']);
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

    var result = await syncOfficialRules(c, updateExisting: false);
    expect(result.updated, 0);
    expect(c.pluginList.first.version, '1.0');

    result = await syncOfficialRules(c, updateExisting: true);
    expect(result.updated, 1);
    expect(c.pluginList.first.version, '1.5');
  });
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

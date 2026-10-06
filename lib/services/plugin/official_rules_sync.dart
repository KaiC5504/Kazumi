import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';

/// Installs every rule from the official catalog that this device hasn't been
/// given before, then updates outdated ones if startup updates are enabled.
///
/// Names already handed out are remembered, so a rule the user deletes stays
/// deleted; only rules newly added to the catalog get installed later.
Future<({int installed, int updated})> syncOfficialRules(
  PluginsController controller, {
  required bool updateExisting,
}) async {
  final catalog = await controller.refreshPluginCatalog();
  final known = _knownRuleKeys();
  final present = {
    for (final plugin in controller.pluginList) pluginNameKey(plugin.name),
  };

  var installed = 0;
  for (final item in catalog) {
    final key = pluginNameKey(item.name);
    if (present.contains(key) || known.contains(key)) continue;
    final result = await controller.tryUpdatePluginByName(item.name);
    if (result == PluginUpdateResult.updated) {
      installed++;
      present.add(key);
    }
  }

  // Failed installs stay unknown so the next launch retries them.
  final catalogKeys = {for (final item in catalog) pluginNameKey(item.name)};
  await GStorage.putSetting<String>(
    SettingsKeys.officialRulesKnown,
    {...known, ...catalogKeys.intersection(present)}.join('\n'),
  );

  var updated = 0;
  if (updateExisting) {
    final batch = await controller.tryUpdateAllPlugin(ensureCatalog: false);
    updated = batch.updated;
  }
  return (installed: installed, updated: updated);
}

Future<void> syncOfficialRulesWithFeedback(
  PluginsController controller, {
  required bool updateExisting,
}) async {
  try {
    final result = await syncOfficialRules(
      controller,
      updateExisting: updateExisting,
    );
    final parts = [
      if (result.installed > 0) '已自动添加 ${result.installed} 条官方规则',
      if (result.updated > 0) '已更新 ${result.updated} 条规则',
    ];
    if (parts.isNotEmpty) {
      KazumiDialog.showToast(message: parts.join('，'));
    }
  } catch (error, stackTrace) {
    KazumiLogger().w(
      'Plugin: official rule sync failed',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

Set<String> _knownRuleKeys() {
  final raw = GStorage.getSetting(SettingsKeys.officialRulesKnown);
  return raw.split('\n').where((name) => name.isNotEmpty).toSet();
}

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/bean/card/rule_card.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/upscale/lan_share.dart';
import 'package:kazumi/services/upscale/upscale_controller.dart';
import 'package:kazumi/services/upscale/upscaled_import_service.dart';
import 'package:kazumi/services/upscale/upscaled_package.dart';
import 'package:kazumi/utils/format.dart';

/// Asks for the export folder the first time it is needed.
Future<bool> ensureUpscaleExportDirectory() async {
  if (GStorage.getSetting(SettingsKeys.upscaleExportDirectory).isNotEmpty) {
    return true;
  }
  final selected = await FilePicker.platform.getDirectoryPath(
    dialogTitle: '选择导出位置 (建议选 iCloud Drive 或 OneDrive 文件夹)',
  );
  if (selected == null || selected.isEmpty) return false;
  await GStorage.putSetting<String>(
    SettingsKeys.upscaleExportDirectory,
    selected,
  );
  return true;
}

Future<void> showUpscaledImportFlow(
  BuildContext context,
  UpscaleController controller,
) async {
  final service = controller.importService;
  String? folder;
  try {
    folder = await service.pickFolder();
  } catch (e) {
    KazumiDialog.showToast(message: '无法打开文件夹: $e');
    return;
  }
  if (folder == null || !context.mounted) {
    await service.releaseFolder();
    return;
  }

  List<UpscaledImportCandidate> candidates;
  try {
    candidates = await service.scan(folder);
  } catch (e) {
    KazumiLogger().w('UpscaledImport: scan failed', error: e);
    KazumiDialog.showToast(message: '读取文件夹失败: $e');
    await service.releaseFolder();
    return;
  }
  if (candidates.isEmpty) {
    KazumiDialog.showToast(message: '这个文件夹里没有找到超分剧集');
    await service.releaseFolder();
    return;
  }
  if (!context.mounted) {
    await service.releaseFolder();
    return;
  }

  await showAdaptiveBottomSheet<void>(
    context: context,
    builder: (context) => UpscaledTransferSheet(
      title: '导入超分剧集',
      actionLabel: '导入',
      items: [
        for (final c in candidates)
          UpscaledTransferItem.of(controller, c.manifest),
      ],
      run: (index, onProgress) =>
          controller.importCandidate(candidates[index], onProgress: onProgress),
      doneMessage: (count) => '已导入 $count 集，可在下载管理中离线播放',
    ),
  );
  await service.releaseFolder();
}

Future<void> showLanPullFlow(
  BuildContext context,
  UpscaleController controller,
) async {
  final connection =
      await KazumiDialog.show<(LanShareClient, List<UpscaledEpisodeManifest>)>(
        builder: (context) => const _LanConnectDialog(),
      );
  if (connection == null || !context.mounted) return;
  final (client, manifests) = connection;
  if (manifests.isEmpty) {
    KazumiDialog.showToast(message: '电脑上还没有烘焙好的超分剧集');
    return;
  }

  await showAdaptiveBottomSheet<void>(
    context: context,
    builder: (context) => UpscaledTransferSheet(
      title: '从电脑拉取',
      actionLabel: '开始拉取',
      items: [
        for (final m in manifests) UpscaledTransferItem.of(controller, m),
      ],
      run: (index, _) => controller.pullFromLan(client, manifests[index]),
      // Pulls continue in the download manager, so the sheet only queues them.
      doneMessage: (count) => '已加入 $count 集，进度可在下载管理中查看',
    ),
  );
}

@visibleForTesting
class UpscaledTransferItem {
  const UpscaledTransferItem({
    required this.manifest,
    required this.replaces,
    this.skipTimesOnly = false,
    this.upToDate = false,
  });

  factory UpscaledTransferItem.of(
    UpscaleController controller,
    UpscaledEpisodeManifest manifest,
  ) {
    final upToDate = controller.isUpToDate(manifest);
    final skipTimesOnly = controller.onlySkipTimesChanged(manifest);
    return UpscaledTransferItem(
      manifest: manifest,
      replaces:
          !upToDate &&
          !skipTimesOnly &&
          controller.isAlreadyDownloaded(manifest),
      skipTimesOnly: skipTimesOnly,
      upToDate: upToDate,
    );
  }

  final UpscaledEpisodeManifest manifest;
  final bool replaces;

  /// Same video already on the device; only the opening/ending times moved.
  final bool skipTimesOnly;
  final bool upToDate;

  int get transferBytes => skipTimesOnly ? 0 : manifest.sizeBytes;
}

@visibleForTesting
class UpscaledTransferSheet extends StatefulWidget {
  const UpscaledTransferSheet({
    super.key,
    required this.title,
    required this.actionLabel,
    required this.items,
    required this.run,
    required this.doneMessage,
  });

  final String title;
  final String actionLabel;
  final List<UpscaledTransferItem> items;
  final Future<void> Function(int index, void Function(double) onProgress) run;
  final String Function(int count) doneMessage;

  @override
  State<UpscaledTransferSheet> createState() => _TransferSheetState();
}

class _TransferSheetState extends State<UpscaledTransferSheet> {
  late final List<bool> _selected = List.filled(widget.items.length, false);
  late final List<_ShowGroup> _groups = _ShowGroup.of(widget.items);
  final Set<String> _expanded = {};
  final Map<int, double> _progress = {};
  final Set<int> _done = {};
  final Map<int, String> _errors = {};
  bool _running = false;

  int get _selectedCount => _selected.where((s) => s).length;

  int get _selectedBytes {
    var total = 0;
    for (var i = 0; i < widget.items.length; i++) {
      if (_selected[i]) total += widget.items[i].transferBytes;
    }
    return total;
  }

  // Up-to-date episodes stay unticked by bulk selection; they can still be
  // ticked one by one to force a re-transfer.
  void _selectAll(bool value) {
    setState(() {
      for (var i = 0; i < widget.items.length; i++) {
        _selected[i] = value && !widget.items[i].upToDate;
      }
    });
  }

  void _selectGroup(_ShowGroup group, bool value) {
    final fresh = group.indices.where((i) => !widget.items[i].upToDate);
    final targets = fresh.isEmpty ? group.indices : fresh;
    setState(() {
      for (final i in group.indices) {
        _selected[i] = false;
      }
      if (!value) return;
      for (final i in targets) {
        _selected[i] = true;
      }
    });
  }

  bool? _groupState(_ShowGroup group) {
    final picked = group.indices.where((i) => _selected[i]).length;
    if (picked == 0) return false;
    if (picked == group.indices.length) return true;
    return null;
  }

  Future<void> _start() async {
    setState(() => _running = true);
    var succeeded = 0;
    for (var i = 0; i < widget.items.length; i++) {
      if (!_selected[i]) continue;
      if (!mounted) return;
      setState(() => _progress[i] = 0);
      try {
        await widget.run(i, (p) {
          if (mounted) setState(() => _progress[i] = p);
        });
        succeeded++;
        if (mounted) setState(() => _done.add(i));
      } catch (e) {
        KazumiLogger().w('UpscaledTransfer: item $i failed', error: e);
        if (mounted) {
          setState(() {
            _errors[i] = e.toString();
            _expanded.add(widget.items[i].manifest.recordKey);
          });
        }
      }
    }
    if (succeeded > 0) {
      KazumiDialog.showToast(message: widget.doneMessage(succeeded));
    }
    if (mounted && _errors.isEmpty) {
      Navigator.of(context).pop();
    } else if (mounted) {
      setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
            child: Text(widget.title, style: textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '已选 $_selectedCount 集 · ${formatBytes(_selectedBytes)}',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _running ? null : () => _selectAll(true),
                  child: const Text('全选'),
                ),
                TextButton(
                  onPressed: _running || _selectedCount == 0
                      ? null
                      : () => _selectAll(false),
                  child: const Text('全不选'),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _groups.length,
              itemBuilder: (context, g) => _buildGroup(context, _groups[g]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: FilledButton(
              onPressed: _running || _selectedCount == 0 ? null : _start,
              child: _running
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: LoadingIndicator(),
                    )
                  : Text(widget.actionLabel),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroup(BuildContext context, _ShowGroup group) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final first = widget.items[group.indices.first].manifest;
    final expanded = _expanded.contains(group.key);
    final picked = group.indices.where((i) => _selected[i]);
    final pickedBytes = picked.fold<int>(
      0,
      (sum, i) => sum + widget.items[i].transferBytes,
    );
    var meta = '${picked.length}/${group.indices.length} 已选';
    if (picked.isNotEmpty) meta += ' · ${formatBytes(pickedBytes)}';

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() {
              if (!_expanded.remove(group.key)) _expanded.add(group.key);
            }),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NetworkImgLayer(
                    src: first.bangumiCover,
                    width: 56,
                    height: 75,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          first.bangumiName,
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            RuleTag(
                              label: first.pluginName,
                              background: colorScheme.secondaryContainer,
                              foreground: colorScheme.onSecondaryContainer,
                            ),
                            Text(
                              meta,
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Checkbox(
                    tristate: true,
                    value: _groupState(group),
                    onChanged: _running
                        ? null
                        : (_) =>
                              _selectGroup(group, _groupState(group) != true),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeInOutCubic,
                      child: Icon(
                        Icons.expand_more,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            child: expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                    child: Column(
                      children: [
                        for (final i in group.indices)
                          _buildEpisode(context, i),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _buildEpisode(BuildContext context, int i) {
    final colorScheme = Theme.of(context).colorScheme;
    final item = widget.items[i];
    final m = item.manifest;
    final progress = _progress[i];
    final error = _errors[i];
    String subtitle = '${formatBytes(m.sizeBytes)} · 超分版';
    if (item.replaces) subtitle += ' · 将替换已下载的版本';
    if (item.skipTimesOnly) subtitle = '已导入 · 更新片头片尾';
    if (item.upToDate) subtitle = '已导入 · 已是最新';
    if (error != null) subtitle = '失败: $error';
    return CheckboxListTile(
      dense: true,
      value: _selected[i],
      onChanged: _running
          ? null
          : (v) => setState(() => _selected[i] = v ?? false),
      title: Text(
        m.displayEpisodeName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            subtitle,
            style: TextStyle(
              color: error != null
                  ? colorScheme.error
                  : item.replaces || item.skipTimesOnly
                  ? colorScheme.tertiary
                  : null,
            ),
          ),
          if (progress != null && !_done.contains(i)) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: progress > 0 ? progress : null),
          ],
        ],
      ),
      secondary: _done.contains(i)
          ? Icon(Icons.check_circle_rounded, color: colorScheme.tertiary)
          : null,
    );
  }
}

/// One show's episodes in the sheet, keeping the order the shows arrived in.
class _ShowGroup {
  _ShowGroup(this.key);

  final String key;
  final List<int> indices = [];

  static List<_ShowGroup> of(List<UpscaledTransferItem> items) {
    final groups = <String, _ShowGroup>{};
    for (var i = 0; i < items.length; i++) {
      final key = items[i].manifest.recordKey;
      groups.putIfAbsent(key, () => _ShowGroup(key)).indices.add(i);
    }
    for (final group in groups.values) {
      group.indices.sort(
        (a, b) => items[a].manifest.episodeNumber.compareTo(
          items[b].manifest.episodeNumber,
        ),
      );
    }
    return groups.values.toList();
  }
}

class _LanConnectDialog extends StatefulWidget {
  const _LanConnectDialog();

  @override
  State<_LanConnectDialog> createState() => _LanConnectDialogState();
}

class _LanConnectDialogState extends State<_LanConnectDialog> {
  late final TextEditingController _address = TextEditingController(
    text: GStorage.getSetting(SettingsKeys.lanPullAddress),
  );
  late final TextEditingController _token = TextEditingController(
    text: GStorage.getSetting(SettingsKeys.lanPullToken),
  );
  bool _connecting = false;
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final address = _address.text.trim();
    final token = _token.text.trim();
    if (address.isEmpty || token.isEmpty) {
      setState(() => _error = '请填写电脑地址和连接码');
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final client = LanShareClient(address, token);
      final manifests = await client.listEpisodes();
      await GStorage.putSetting<String>(SettingsKeys.lanPullAddress, address);
      await GStorage.putSetting<String>(SettingsKeys.lanPullToken, token);
      KazumiDialog.dismiss(popWith: (client, manifests));
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('连接电脑'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '在电脑端 Kazumi 的「下载设置」中开启局域网共享，'
            '然后填写那里显示的地址和连接码。',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _address,
            enabled: !_connecting,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '电脑地址',
              hintText: '例如 192.168.1.20',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            enabled: !_connecting,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: '连接码',
              border: const OutlineInputBorder(),
              errorText: _error,
              errorMaxLines: 3,
            ),
            onSubmitted: (_) => _connect(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _connecting ? null : () => KazumiDialog.dismiss(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _connecting ? null : _connect,
          child: _connecting
              ? const SizedBox(width: 20, height: 20, child: LoadingIndicator())
              : const Text('连接'),
        ),
      ],
    );
  }
}

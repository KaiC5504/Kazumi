import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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
    builder: (context) => _TransferSheet(
      title: '导入超分剧集',
      actionLabel: '导入',
      items: [
        for (final c in candidates)
          _TransferItem.of(controller, c.manifest),
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
    builder: (context) => _TransferSheet(
      title: '从电脑拉取',
      actionLabel: '开始拉取',
      items: [
        for (final m in manifests)
          _TransferItem.of(controller, m),
      ],
      run: (index, _) => controller.pullFromLan(client, manifests[index]),
      // Pulls continue in the download manager, so the sheet only queues them.
      doneMessage: (count) => '已加入 $count 集，进度可在下载管理中查看',
    ),
  );
}

class _TransferItem {
  const _TransferItem({
    required this.manifest,
    required this.replaces,
    this.skipTimesOnly = false,
    this.upToDate = false,
  });

  factory _TransferItem.of(
    UpscaleController controller,
    UpscaledEpisodeManifest manifest,
  ) {
    final upToDate = controller.isUpToDate(manifest);
    final skipTimesOnly = controller.onlySkipTimesChanged(manifest);
    return _TransferItem(
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

class _TransferSheet extends StatefulWidget {
  const _TransferSheet({
    required this.title,
    required this.actionLabel,
    required this.items,
    required this.run,
    required this.doneMessage,
  });

  final String title;
  final String actionLabel;
  final List<_TransferItem> items;
  final Future<void> Function(int index, void Function(double) onProgress) run;
  final String Function(int count) doneMessage;

  @override
  State<_TransferSheet> createState() => _TransferSheetState();
}

class _TransferSheetState extends State<_TransferSheet> {
  late final List<bool> _selected = [
    for (final item in widget.items) !item.upToDate,
  ];
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
        if (mounted) setState(() => _errors[i] = e.toString());
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
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              '已选 $_selectedCount 集 · ${formatBytes(_selectedBytes)}',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: widget.items.length,
              itemBuilder: (context, i) {
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
                  value: _selected[i],
                  onChanged: _running
                      ? null
                      : (v) => setState(() => _selected[i] = v ?? false),
                  title: Text(
                    '${m.bangumiName} · ${m.displayEpisodeName}',
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
                        LinearProgressIndicator(
                          value: progress > 0 ? progress : null,
                        ),
                      ],
                    ],
                  ),
                  secondary: _done.contains(i)
                      ? Icon(
                          Icons.check_circle_rounded,
                          color: colorScheme.tertiary,
                        )
                      : null,
                );
              },
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

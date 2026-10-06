import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_session.dart';
import 'package:kazumi/services/upscale/cloud/runpod_api.dart';
import 'package:kazumi/services/upscale/upscale_controller.dart';
import 'package:url_launcher/url_launcher.dart';

String cloudStatusText(CloudEpisodePhase phase) {
  final percent = '${(phase.progress * 100).toStringAsFixed(0)}%';
  return switch (phase.stage) {
    CloudEpisodeStage.uploading => '☁ 上传中 $percent',
    CloudEpisodeStage.waiting => '☁ 等待 GPU',
    CloudEpisodeStage.baking => '☁ 烘焙中 $percent',
    CloudEpisodeStage.downloading => '☁ 下载中 $percent',
  };
}

String _money(double value) => '\$${value.toStringAsFixed(2)}';

Future<void> showCloudBakeFlow(
  BuildContext context,
  UpscaleController controller,
  DownloadRecord record, {
  required Future<void> Function() bakeAllLocally,
}) async {
  if (!controller.hasRunpodKey) {
    KazumiDialog.showToast(
      message: '请先在下载设置中填写 Runpod API Key',
      showActionButton: true,
      actionLabel: '去设置',
      onActionPressed: () => context.pushNamed('/settings/download/'),
    );
    return;
  }
  KazumiDialog.showToast(message: '正在查询悉尼 GPU…');
  final CloudBakeQuote quote;
  try {
    quote = await controller.quoteCloudBake(record.key);
  } on RunpodException catch (e) {
    if (e.noCapacity) {
      await _offerLocal(bakeAllLocally);
    } else {
      KazumiDialog.showToast(
        message: e.message,
        showActionButton: true,
        actionLabel: '打开 Runpod',
        onActionPressed: () => launchUrl(
          Uri.parse('https://console.runpod.io/user/settings'),
          mode: LaunchMode.externalApplication,
        ),
        duration: const Duration(seconds: 6),
      );
    }
    return;
  } on CloudBakeException catch (e) {
    KazumiDialog.showToast(message: e.message);
    return;
  }
  if (!quote.offer.available) {
    await _offerLocal(bakeAllLocally);
    return;
  }
  if (quote.estimate.cloudCount == 0) {
    KazumiDialog.showToast(message: '集数太少，本机烘焙更快');
    await bakeAllLocally();
    return;
  }
  if (!context.mounted) return;
  final go = await showAdaptiveBottomSheet<bool>(
    context: context,
    builder: (_) => CloudBakeConfirmSheet(quote: quote),
  );
  if (go != true) return;
  try {
    await controller.startCloudBake(quote);
  } on CloudBakeException catch (e) {
    KazumiDialog.showToast(message: e.message);
  }
}

Future<void> _offerLocal(Future<void> Function() bakeAllLocally) async {
  final local = await KazumiDialog.show<bool>(
    builder: (context) => AlertDialog(
      title: const Text('悉尼暂无可用 GPU'),
      content: const Text('现在租不到悉尼的 L40S。可以先用本机烘焙全部，或稍后再试。'),
      actions: [
        TextButton(
          onPressed: () => KazumiDialog.dismiss(popWith: false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => KazumiDialog.dismiss(popWith: true),
          child: const Text('本机烘焙全部'),
        ),
      ],
    ),
  );
  if (local == true) await bakeAllLocally();
}

class CloudBakeConfirmSheet extends StatelessWidget {
  const CloudBakeConfirmSheet({super.key, required this.quote});

  final CloudBakeQuote quote;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final estimate = quote.estimate;
    final price = quote.offer.pricePerHour;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: colorScheme.tertiaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.cloud_rounded,
                    color: colorScheme.onTertiaryContainer,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(child: Text('云端烘焙', style: textTheme.titleLarge)),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                _Stat(
                  label: '云端',
                  value: '${estimate.cloudCount} 集',
                  note: estimate.localCount > 0
                      ? '本机 ${estimate.localCount} 集'
                      : null,
                ),
                const SizedBox(width: 12),
                _Stat(
                  label: '预计',
                  value: '${(estimate.finishSec / 60).ceil()} 分钟',
                ),
                const SizedBox(width: 12),
                _Stat(
                  label: '费用',
                  value: _money(estimate.cost(price)),
                  note: '最多 ${_money(estimate.maxCost(price))}',
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'L40S 悉尼 ${_money(price)}/小时 · 按秒计费，做完自动删除 GPU',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (!quote.includeLocal)
              Text(
                '本机不参与烘焙 (可在下载设置中开启)',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(context).pop(true),
                    icon: const Icon(Icons.rocket_launch_rounded),
                    label: const Text('开始'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.note});

  final String label;
  final String value;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: textTheme.labelMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (note != null)
              Text(
                note!,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shown above the download list while a cloud bake runs.
class CloudBakeBanner extends StatefulWidget {
  const CloudBakeBanner({super.key, required this.controller});

  final UpscaleController controller;

  @override
  State<CloudBakeBanner> createState() => _CloudBakeBannerState();
}

class _CloudBakeBannerState extends State<CloudBakeBanner> {
  Timer? _ticker;
  bool _stopping = false;

  @override
  void initState() {
    super.initState();
    // Elapsed time and cost move every second without a state change.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.controller.cloudSession.value != null) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _stop() async {
    final confirmed = await KazumiDialog.show<bool>(
      builder: (context) => AlertDialog(
        title: const Text('停止云端烘焙？'),
        content: const Text('会立即删除云端 GPU。云端正在处理的剧集回到未烘焙，本机正在烘焙的那一集会继续。'),
        actions: [
          TextButton(
            onPressed: () => KazumiDialog.dismiss(popWith: false),
            child: const Text('继续烘焙'),
          ),
          FilledButton(
            onPressed: () => KazumiDialog.dismiss(popWith: true),
            child: const Text('停止'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _stopping = true);
    await widget.controller.stopCloudBake();
    if (mounted) setState(() => _stopping = false);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Observer(
      builder: (context) {
        final view = widget.controller.cloudSession.value;
        return AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: view == null
              ? const SizedBox(width: double.infinity)
              : _buildCard(view, colorScheme, textTheme),
        );
      },
    );
  }

  Widget _buildCard(
    CloudBakeSessionView view,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final now = DateTime.now();
    final elapsed = now.difference(view.startedAt);
    final clock =
        '${elapsed.inMinutes}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';
    final title = switch (view.phase) {
      CloudBakePhase.starting => '正在启动 GPU',
      CloudBakePhase.running => '云端烘焙中',
      CloudBakePhase.finishing => '正在收尾',
      CloudBakePhase.done => '已完成',
      CloudBakePhase.stopped => '已停止',
    };
    final busy =
        view.phase == CloudBakePhase.starting ||
        view.phase == CloudBakePhase.running;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Card(
            elevation: 0,
            margin: EdgeInsets.zero,
            color: colorScheme.tertiaryContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (busy)
                          CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colorScheme.onTertiaryContainer,
                          ),
                        Icon(
                          Icons.cloud_rounded,
                          size: 20,
                          color: colorScheme.onTertiaryContainer,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: colorScheme.onTertiaryContainer,
                          ),
                        ),
                        Text(
                          '☁ ${view.cloudDone} · 本机 ${view.localDone} · '
                          '共 ${view.total} 集 · $clock · '
                          '${_money(view.costAt(now))}',
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onTertiaryContainer,
                          ),
                        ),
                        if (view.message != null)
                          Text(
                            view.message!,
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.error,
                            ),
                          ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: _stopping || !busy ? null : _stop,
                    child: const Text('停止'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// After a crash or a killed app the pod may still be billing; it deletes
/// itself within about ten minutes, but offer to do it now.
Future<void> checkLeftoverCloudPods(UpscaleController controller) async {
  await Future.delayed(const Duration(seconds: 3));
  final List<CloudPodInfo> pods;
  try {
    pods = await controller.leftoverCloudPods();
  } catch (e) {
    KazumiLogger().w('CloudBake: leftover pod check failed', error: e);
    return;
  }
  for (final pod in pods) {
    final created = pod.createdAt;
    final age = created == null
        ? ''
        : '已运行 ${DateTime.now().difference(created).inMinutes} 分钟，';
    final delete = await KazumiDialog.show<bool>(
      builder: (context) => AlertDialog(
        title: const Text('发现仍在运行的云端 GPU'),
        content: Text(
          '${pod.name} $age按 ${_money(pod.costPerHour)}/小时计费。是否删除？',
        ),
        actions: [
          TextButton(
            onPressed: () => KazumiDialog.dismiss(popWith: false),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => KazumiDialog.dismiss(popWith: true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (delete != true) continue;
    try {
      await controller.deleteCloudPod(pod.id);
      KazumiDialog.showToast(message: '已删除云端 GPU');
    } on RunpodException catch (e) {
      KazumiDialog.showToast(message: e.message);
    }
  }
}

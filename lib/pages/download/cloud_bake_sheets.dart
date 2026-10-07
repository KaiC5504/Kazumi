import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:mobx/mobx.dart';
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
    CloudEpisodeStage.queued => phase.laptop ? '本机排队中' : '☁ 排队中',
    CloudEpisodeStage.uploading => '☁ 上传中 $percent',
    CloudEpisodeStage.waiting => '☁ 等待 GPU',
    CloudEpisodeStage.baking => '☁ 烘焙中 $percent',
    CloudEpisodeStage.downloading => '☁ 下载中 $percent',
  };
}

String _money(double value) => '\$${value.toStringAsFixed(2)}';

String _minutes(int seconds) => '${(seconds / 60).ceil()} 分钟';

bool _checkKey(BuildContext context, UpscaleController controller) {
  if (controller.hasRunpodKey) return true;
  KazumiDialog.showToast(
    message: '请先在下载设置中填写 Runpod API Key',
    showActionButton: true,
    actionLabel: '去设置',
    onActionPressed: () => context.pushNamed('/settings/download/'),
  );
  return false;
}

/// Joins the running session if there is one. True when the episodes were
/// handled, either queued or refused with a toast.
Future<bool> _joinRunning(
  UpscaleController controller,
  String recordKey, {
  int? episodeNumber,
}) async {
  if (!controller.cloudRunning) return false;
  try {
    final added = await controller.addToCloud(
      recordKey,
      episodeNumber: episodeNumber,
    );
    if (added == null) return false;
    final projected = controller.cloudSession.value?.projectedCost(
      DateTime.now(),
    );
    final count = episodeNumber == null ? ' · $added 集' : '';
    final total = projected == null ? '' : ' · 预计共 ${_money(projected)}';
    KazumiDialog.showToast(message: '已加入云端队列$count$total');
  } on CloudBakeException catch (e) {
    KazumiDialog.showToast(message: e.message);
  }
  return true;
}

Future<CloudBakeQuote?> _quote(
  UpscaleController controller,
  String recordKey, {
  int? episodeNumber,
}) async {
  KazumiDialog.showToast(message: '正在查询悉尼 GPU…');
  try {
    return await controller.quoteCloudBake(
      recordKey,
      episodeNumber: episodeNumber,
    );
  } on RunpodException catch (e) {
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
  } on CloudBakeException catch (e) {
    KazumiDialog.showToast(message: e.message);
  }
  return null;
}

Future<void> _confirmAndStart(
  BuildContext context,
  UpscaleController controller,
  CloudBakeQuote quote, {
  Future<void> Function()? bakeAllLocally,
}) async {
  if (!context.mounted) return;
  final choice = await showAdaptiveBottomSheet<CloudBakeChoice>(
    context: context,
    builder: (_) => CloudBakeConfirmSheet(
      quote: quote,
      canBakeLocally: bakeAllLocally != null,
    ),
  );
  if (choice == CloudBakeChoice.local) {
    await bakeAllLocally?.call();
    return;
  }
  if (choice != CloudBakeChoice.cloud) return;
  try {
    await controller.startCloudBake(quote);
  } on CloudBakeException catch (e) {
    KazumiDialog.showToast(message: e.message);
  }
}

/// ☁ 云端烘焙全部 on a show's card.
Future<void> showCloudBakeFlow(
  BuildContext context,
  UpscaleController controller,
  DownloadRecord record, {
  required Future<void> Function() bakeAllLocally,
}) async {
  if (!_checkKey(context, controller)) return;
  if (await _joinRunning(controller, record.key)) return;
  var quote = await _quote(controller, record.key);
  if (quote == null) return;
  if (quote.estimate.cloudCount == 0) {
    final choice = await _askLocalFaster(quote);
    if (choice == CloudBakeChoice.local) {
      await bakeAllLocally();
      return;
    }
    if (choice != CloudBakeChoice.cloud) return;
    quote = quote.allCloud();
  }
  if (!context.mounted) return;
  await _confirmAndStart(
    context,
    controller,
    quote,
    bakeAllLocally: bakeAllLocally,
  );
}

/// The ☁ button on one episode: queues it for the pod, starting a session
/// if none is running.
Future<void> showCloudEpisodeFlow(
  BuildContext context,
  UpscaleController controller,
  DownloadRecord record,
  int episodeNumber,
) async {
  if (!_checkKey(context, controller)) return;
  if (await _joinRunning(
    controller,
    record.key,
    episodeNumber: episodeNumber,
  )) {
    return;
  }
  final quote = await _quote(
    controller,
    record.key,
    episodeNumber: episodeNumber,
  );
  if (quote == null || !context.mounted) return;
  await _confirmAndStart(context, controller, quote);
}

enum CloudBakeChoice { cloud, local }

Future<CloudBakeChoice?> _askLocalFaster(CloudBakeQuote quote) {
  final cloud = quote.allCloud().estimate.finishSec;
  return KazumiDialog.show<CloudBakeChoice>(
    builder: (context) => AlertDialog(
      title: const Text('本机烘焙更快'),
      content: Text(
        '本机约 ${_minutes(quote.estimate.localOnlySec)} 烘焙完，'
        '云端约 ${_minutes(cloud)} (含启动 GPU)。',
      ),
      actions: [
        TextButton(
          onPressed: () => KazumiDialog.dismiss(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => KazumiDialog.dismiss(popWith: CloudBakeChoice.cloud),
          child: const Text('仍用云端'),
        ),
        FilledButton(
          onPressed: () => KazumiDialog.dismiss(popWith: CloudBakeChoice.local),
          child: const Text('本机烘焙'),
        ),
      ],
    ),
  );
}

class CloudBakeConfirmSheet extends StatelessWidget {
  const CloudBakeConfirmSheet({
    super.key,
    required this.quote,
    this.canBakeLocally = false,
  });

  final CloudBakeQuote quote;
  final bool canBakeLocally;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final estimate = quote.estimate;
    final price = quote.offer.pricePerHour;
    final waiting = !quote.offer.available;
    final note = textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
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
            if (waiting) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.hourglass_top_rounded,
                      color: colorScheme.onSecondaryContainer,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '悉尼暂时没有空闲的 L40S。开始后自动排队等待，'
                        '一有空位就启动，等待期间不收费。',
                        style: textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
                  label: waiting ? '启动后约' : '预计',
                  value: _minutes(estimate.finishSec),
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
            Text('L40S 悉尼 ${_money(price)}/小时 · 按秒计费，做完自动删除 GPU', style: note),
            Text('运行中可在每集旁点 ☁ 继续加入云端队列', style: note),
            if (!quote.includeLocal)
              Text('本机不参与烘焙 (全部烘焙时可在下载设置中开启)', style: note),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                ),
                if (waiting && canBakeLocally) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () =>
                          Navigator.of(context).pop(CloudBakeChoice.local),
                      child: const Text('本机烘焙全部'),
                    ),
                  ),
                ],
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () =>
                        Navigator.of(context).pop(CloudBakeChoice.cloud),
                    icon: Icon(
                      waiting
                          ? Icons.hourglass_top_rounded
                          : Icons.rocket_launch_rounded,
                    ),
                    label: Text(waiting ? '排队等待' : '开始'),
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

/// The banner's look-ahead: time left on the pod and what it will cost.
String? projection(CloudBakeSessionView view, DateTime now) {
  final remaining = view.remainingAt(now);
  final cost = view.projectedCost(now);
  if (remaining == null || cost == null) return null;
  final when = view.phase == CloudBakePhase.waiting ? '启动后约' : '预计还需';
  return '$when ${_minutes(remaining)} · 共约 ${_money(cost)}';
}

/// Shown above the download list while a cloud bake runs.
class CloudBakeBanner extends StatefulWidget {
  const CloudBakeBanner({
    super.key,
    required this.session,
    required this.onStop,
  });

  final Observable<CloudBakeSessionView?> session;
  final Future<void> Function() onStop;

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
      if (mounted && widget.session.value != null) {
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
    await widget.onStop();
    if (mounted) setState(() => _stopping = false);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Observer(
      builder: (context) {
        final view = widget.session.value;
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
      CloudBakePhase.waiting => '等待悉尼 GPU · 有空位自动启动',
      CloudBakePhase.starting => '正在启动 GPU',
      CloudBakePhase.running => '云端烘焙中',
      CloudBakePhase.finishing => '正在收尾',
      CloudBakePhase.done => '已完成',
      CloudBakePhase.stopped => '已停止',
    };
    final busy =
        view.phase == CloudBakePhase.waiting ||
        view.phase == CloudBakePhase.starting ||
        view.phase == CloudBakePhase.running;
    // After a cloud failure the laptop may still have the whole season to
    // go, so stopping must stay possible until the session ends.
    final canStop =
        view.phase != CloudBakePhase.done &&
        view.phase != CloudBakePhase.stopped;
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
                        if (projection(view, now) case final line?)
                          Text(
                            line,
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
                    onPressed: _stopping || !canStop ? null : _stop,
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

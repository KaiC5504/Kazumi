import 'dart:math';

import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_session.dart';

/// Show title and episode label for a job, resolved by the caller.
typedef CloudJobTitle = (String show, String episode) Function(CloudJob job);

String _money(double value) => '\$${value.toStringAsFixed(2)}';

String _duration(int seconds) {
  if (seconds < 60) return '$seconds 秒';
  final minutes = (seconds / 60).round();
  if (minutes < 60) return '$minutes 分钟';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '$h 小时' : '$h 小时 $m 分';
}

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _size(int bytes) => bytes >= 1e9
    ? '${(bytes / 1e9).toStringAsFixed(2)} GB'
    : '${(bytes / 1e6).toStringAsFixed(0)} MB';

/// Opens once the run is over: every cloud-baked episode is on this PC and
/// the pod is gone.
Future<void> showCloudBakeReport(
  CloudBakeReport report, {
  required CloudJobTitle titleOf,
}) => KazumiDialog.show<void>(
  // Stays up until the owner closes it; a stray click shouldn't lose it.
  clickMaskDismiss: false,
  builder: (context) => CloudBakeReportDialog(report: report, titleOf: titleOf),
);

class CloudBakeReportDialog extends StatelessWidget {
  const CloudBakeReportDialog({
    super.key,
    required this.report,
    required this.titleOf,
  });

  final CloudBakeReport report;
  final CloudJobTitle titleOf;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final cloud = report.where(CloudEpisodeOutcome.cloud).length;
    final failed = report.where(CloudEpisodeOutcome.failed).length;
    final allGood = failed == 0 && cloud > 0;
    final speed = report.podSec == 0
        ? null
        : report.cloudMediaSec / report.podSec;
    final saved = report.laptopSec - report.wall.inSeconds;
    final note = textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );

    return Dialog(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    colorScheme.tertiaryContainer,
                    colorScheme.surfaceContainerHigh,
                  ],
                ),
              ),
              child: Row(
                children: [
                  _Pop(
                    child: Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: allGood
                            ? colorScheme.tertiary
                            : colorScheme.errorContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        allGood
                            ? Icons.cloud_done_rounded
                            : Icons.cloud_off_rounded,
                        color: allGood
                            ? colorScheme.onTertiary
                            : colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          allGood ? '云端烘焙完成' : '云端烘焙结束',
                          style: textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: colorScheme.onTertiaryContainer,
                          ),
                        ),
                        Text(
                          '${_clock(report.startedAt)} – ${_clock(report.endedAt)}'
                          ' · $cloud 集已回到本机'
                          '${failed > 0 ? ' · $failed 集未完成' : ''}',
                          style: textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onTertiaryContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(
                children: [
                  _Tile(label: '总用时', value: _duration(report.wall.inSeconds)),
                  const SizedBox(width: 10),
                  _Tile(
                    label: '费用',
                    value: _money(report.cost),
                    note: 'GPU ${_duration(report.podSec)}',
                  ),
                  const SizedBox(width: 10),
                  _Tile(
                    label: '速度',
                    value: speed == null ? '—' : '${speed.toStringAsFixed(1)}×',
                    note: '实时',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
              child: Text(
                [
                  'L40S 悉尼 · ${_money(report.pricePerHour)}/小时',
                  ?report.encoder,
                  if (report.cloudMediaSec > 0)
                    saved > 60
                        ? '本机需约 ${_duration(report.laptopSec)}，省下 ${_duration(saved)}'
                        : '本机需约 ${_duration(report.laptopSec)}',
                ].join(' · '),
                style: note,
              ),
            ),
            if (report.message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
                child: Text(
                  report.message!,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.error,
                  ),
                ),
              ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                itemCount: report.episodes.length,
                itemBuilder: (context, i) => _Rise(
                  delay: Duration(milliseconds: 60 * min(i, 8)),
                  child: _EpisodeRow(
                    episode: report.episodes[i],
                    titleOf: titleOf,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              child: FilledButton(
                onPressed: () => KazumiDialog.dismiss(),
                child: const Text('关闭'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({required this.episode, required this.titleOf});

  final CloudEpisodeReport episode;
  final CloudJobTitle titleOf;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final (show, label) = titleOf(episode.job);
    final (icon, color, tag) = switch (episode.outcome) {
      CloudEpisodeOutcome.cloud => (
        Icons.cloud_done_rounded,
        colorScheme.tertiary,
        '云端',
      ),
      CloudEpisodeOutcome.local => (
        Icons.laptop_rounded,
        colorScheme.secondary,
        '本机',
      ),
      CloudEpisodeOutcome.failed => (
        Icons.error_outline_rounded,
        colorScheme.error,
        '未完成',
      ),
      CloudEpisodeOutcome.returned => (
        Icons.undo_rounded,
        colorScheme.onSurfaceVariant,
        '已退回',
      ),
    };
    final details = episode.outcome == CloudEpisodeOutcome.cloud
        ? [
            if (episode.uploadSec != null)
              '上传 ${_duration(episode.uploadSec!)}',
            if (episode.bakeSec != null) '烘焙 ${_duration(episode.bakeSec!)}',
            if (episode.downloadSec != null)
              '下载 ${_duration(episode.downloadSec!)}',
            if (episode.outBytes != null) _size(episode.outBytes!),
          ].join(' · ')
        : episode.error ?? '';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  show.isEmpty ? label : '$show · $label',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleSmall,
                ),
                if (details.isNotEmpty)
                  Text(
                    details,
                    style: textTheme.bodySmall?.copyWith(
                      color: episode.outcome == CloudEpisodeOutcome.failed
                          ? colorScheme.error
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(tag, style: textTheme.labelMedium?.copyWith(color: color)),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value, this.note});

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
          color: colorScheme.surfaceContainerHighest,
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
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
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

/// The header badge springs in.
class _Pop extends StatelessWidget {
  const _Pop({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0.6, end: 1),
    duration: const Duration(milliseconds: 520),
    curve: Curves.elasticOut,
    builder: (context, t, child) => Transform.scale(scale: t, child: child),
    child: child,
  );
}

/// Episode rows slide up one after another.
class _Rise extends StatefulWidget {
  const _Rise({required this.delay, required this.child});

  final Duration delay;
  final Widget child;

  @override
  State<_Rise> createState() => _RiseState();
}

class _RiseState extends State<_Rise> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  late final Animation<double> _t = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    Future.delayed(widget.delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _t,
    builder: (context, child) => Opacity(
      opacity: _t.value,
      child: Transform.translate(
        offset: Offset(0, 12 * (1 - _t.value)),
        child: child,
      ),
    ),
    child: widget.child,
  );
}

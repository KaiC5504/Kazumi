import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/bean/dialog/glass_notice.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/services/skip/skip_segments.dart';
import 'package:kazumi/services/storage/storage.dart';

/// "Skip opening / ending" button that floats over the video while a
/// detected segment plays, and optionally skips it on its own.
class SkipSegmentPill extends StatefulWidget {
  const SkipSegmentPill({
    super.key,
    required this.playerController,
    required this.onNextEpisode,
  });

  final PlayerController playerController;
  final VoidCallback onNextEpisode;

  @override
  State<SkipSegmentPill> createState() => _SkipSegmentPillState();
}

enum _PillMode { skip, undo }

class _SkipSegmentPillState extends State<SkipSegmentPill> {
  static const _tick = Duration(milliseconds: 250);
  static const _showFor = Duration(seconds: 8);
  static const _undoFor = Duration(seconds: 5);

  Timer? _timer;

  SkipSegments? _segments;
  final Set<SkipKind> _autoSkipped = {};
  SkipKind? _dismissed;

  SkipKind? _kind;
  SkipRange? _range;
  _PillMode _mode = _PillMode.skip;
  DateTime _shownAt = DateTime.now();
  double _progress = 0;

  PlayerController get _player => widget.playerController;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_tick, (_) => _update());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  double get _position => _player.playback.playerPosition.inMilliseconds / 1000;

  void _update() {
    if (!mounted) return;
    final segments = _player.skipSegments;
    if (!identical(segments, _segments)) {
      _segments = segments;
      _autoSkipped.clear();
      _dismissed = null;
      _setPill(null, null);
    }
    if (segments.isEmpty) return;

    if (_mode == _PillMode.undo) {
      if (DateTime.now().difference(_shownAt) > _undoFor) _setPill(null, null);
      return;
    }

    final position = _position;
    final active = segments.activeAt(position);
    // Nothing worth skipping in the last second of a segment.
    if (active == null || active.$2.end - position < 1) {
      _dismissed = null;
      _setPill(null, null);
      return;
    }
    final (kind, range) = active;

    if (_shouldAutoSkip(kind, range)) {
      _autoSkipped.add(kind);
      unawaited(_seekTo(range.end));
      _setPill(kind, range, mode: _PillMode.undo);
      return;
    }

    if (_kind != kind) {
      // A dismissed pill comes back with the controls.
      if (_dismissed == kind && !_player.panel.showVideoController) return;
      _setPill(kind, range);
    } else if (DateTime.now().difference(_shownAt) > _showFor &&
        !_player.panel.showVideoController) {
      _dismissed = kind;
      _setPill(null, null);
      return;
    }
    setState(() {
      _progress = ((position - range.start) / range.length).clamp(0.0, 1.0);
    });
  }

  bool _shouldAutoSkip(SkipKind kind, SkipRange range) {
    if (_autoSkipped.contains(kind)) return false;
    // AniSkip times come from strangers and other encodes; only offer them.
    if (range.source != SkipSource.fingerprint) return false;
    // Everyone in the room would seek at once.
    if (_player.syncplay.inRoom) return false;
    if (!_player.playback.playerPlaying) return false;
    return GStorage.getSetting(
      kind == SkipKind.opening
          ? SettingsKeys.autoSkipOpening
          : SettingsKeys.autoSkipEnding,
    );
  }

  void _setPill(
    SkipKind? kind,
    SkipRange? range, {
    _PillMode mode = _PillMode.skip,
  }) {
    if (_kind == kind && identical(_range, range) && _mode == mode) return;
    setState(() {
      _kind = kind;
      _range = range;
      _mode = mode;
      _shownAt = DateTime.now();
      _progress = 0;
    });
  }

  Future<void> _seekTo(double seconds) =>
      _player.seek(Duration(milliseconds: (seconds * 1000).round()));

  bool _endsEpisode(SkipRange range) {
    final duration = _player.playback.playerDuration.inMilliseconds / 1000;
    return duration > 0 && duration - range.end < 3;
  }

  void _onTap() {
    final kind = _kind;
    final range = _range;
    if (kind == null || range == null) return;
    if (_mode == _PillMode.undo) {
      unawaited(_seekTo(range.start));
      _dismissed = kind;
    } else if (kind == SkipKind.ending && _endsEpisode(range)) {
      widget.onNextEpisode();
    } else {
      unawaited(_seekTo(range.end));
    }
    _setPill(null, null);
  }

  String get _label {
    final kind = _kind;
    final range = _range;
    if (kind == null || range == null) return '';
    final name = kind == SkipKind.opening ? '片头' : '片尾';
    if (_mode == _PillMode.undo) return '已跳过$name · 撤销';
    if (kind == SkipKind.ending && _endsEpisode(range)) return '下一集';
    return '跳过$name';
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final visible = _kind != null;
    return Observer(
      builder: (context) {
        final controlsUp =
            _player.panel.showVideoController && !_player.panel.lockPanel;
        return Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              right: 20,
              bottom: safeBottom + (controlsUp ? 108 : 28),
              child: AnimatedSwitcher(
                duration: Duration(milliseconds: reduceMotion ? 0 : 420),
                reverseDuration: Duration(milliseconds: reduceMotion ? 0 : 220),
                switchInCurve: Curves.easeOutBack,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation.drive(CurveTween(curve: Curves.easeOut)),
                  child: SlideTransition(
                    position: animation.drive(
                      Tween(begin: const Offset(0.35, 0), end: Offset.zero),
                    ),
                    child: ScaleTransition(
                      scale: animation.drive(Tween(begin: 0.9, end: 1.0)),
                      alignment: Alignment.centerRight,
                      child: child,
                    ),
                  ),
                ),
                child: visible
                    ? _SkipButton(
                        key: ValueKey(_label),
                        label: _label,
                        progress: _mode == _PillMode.skip ? _progress : null,
                        undo: _mode == _PillMode.undo,
                        onTap: _onTap,
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SkipButton extends StatelessWidget {
  const _SkipButton({
    super.key,
    required this.label,
    required this.progress,
    required this.undo,
    required this.onTap,
  });

  final String label;

  /// How much of the segment has played; null hides the ring.
  final double? progress;
  final bool undo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const foreground = Color(0xF2FFFFFF);
    const accent = Color(0xFFA8D8FF);
    final textStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
      color: foreground,
      fontSize: 14,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.3,
    );
    final progress = this.progress;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: GlassPillSurface(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 16, 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: 20,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (progress != null)
                        TweenAnimationBuilder<double>(
                          tween: Tween(end: progress),
                          duration: const Duration(milliseconds: 250),
                          builder: (context, value, _) =>
                              CircularProgressIndicator(
                                value: value,
                                strokeWidth: 2,
                                color: accent,
                                backgroundColor: Colors.white.withValues(
                                  alpha: 0.18,
                                ),
                              ),
                        ),
                      Icon(
                        undo ? Icons.undo_rounded : Icons.fast_forward_rounded,
                        size: progress != null ? 12 : 17,
                        color: progress != null ? foreground : accent,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(label, style: textStyle),
                if (!undo) ...[
                  const SizedBox(width: 2),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: foreground,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

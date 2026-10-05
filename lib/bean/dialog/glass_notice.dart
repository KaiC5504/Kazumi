import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:kazumi/navigation.dart';

/// A short frosted-glass pill for watch-together events. Room events sit at
/// the top so they don't cover subtitles; ones with a button go at the
/// bottom, within thumb reach.
class GlassNotice {
  GlassNotice._();

  static OverlayEntry? _entry;

  static void show(
    String message, {
    IconData? icon,
    bool bottom = false,
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
  }) {
    final overlay = rootNavigatorKey.currentState?.overlay;
    if (overlay == null) return;
    _remove();
    final hasAction = actionLabel != null && onAction != null;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _GlassNoticeView(
        message: message,
        icon: icon,
        bottom: bottom,
        actionLabel: hasAction ? actionLabel : null,
        onAction: hasAction ? onAction : null,
        duration:
            duration ??
            (hasAction
                ? const Duration(seconds: 6)
                : const Duration(milliseconds: 2600)),
        onDone: () {
          if (identical(_entry, entry)) _remove();
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  static bool get isShowing => _entry != null;

  static void hide() => _remove();

  static void _remove() {
    _entry?.remove();
    _entry = null;
  }
}

class _GlassNoticeView extends StatefulWidget {
  const _GlassNoticeView({
    required this.message,
    required this.icon,
    required this.bottom,
    required this.actionLabel,
    required this.onAction,
    required this.duration,
    required this.onDone,
  });

  final String message;
  final IconData? icon;
  final bool bottom;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Duration duration;
  final VoidCallback onDone;

  @override
  State<_GlassNoticeView> createState() => _GlassNoticeViewState();
}

class _GlassNoticeViewState extends State<_GlassNoticeView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    reverseDuration: const Duration(milliseconds: 260),
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutBack,
    reverseCurve: Curves.easeInCubic,
  );
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    _timer = Timer(widget.duration, _hide);
  }

  Future<void> _hide() async {
    _timer?.cancel();
    if (!mounted) return;
    await _controller.reverse();
    if (mounted) widget.onDone();
  }

  void _act() {
    final action = widget.onAction;
    unawaited(_hide());
    if (action != null) scheduleMicrotask(action);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final slideFrom = widget.bottom ? 24.0 : -24.0;
    final pill = AnimatedBuilder(
      animation: _curve,
      builder: (context, child) {
        final t = _curve.value;
        return Opacity(
          opacity: _controller.value,
          child: Transform.translate(
            offset: Offset(0, reduceMotion ? 0 : (1 - t) * slideFrom),
            child: Transform.scale(
              scale: reduceMotion ? 1 : 0.9 + 0.1 * t,
              child: child,
            ),
          ),
        );
      },
      child: _GlassPill(
        message: widget.message,
        icon: widget.icon,
        actionLabel: widget.actionLabel,
        onAction: widget.actionLabel == null ? null : _act,
      ),
    );

    return Positioned(
      top: widget.bottom ? null : padding.top + 10,
      bottom: widget.bottom ? padding.bottom + 24 : null,
      left: 16,
      right: 16,
      child: Center(
        child: widget.actionLabel == null ? IgnorePointer(child: pill) : pill,
      ),
    );
  }
}

class _GlassPill extends StatelessWidget {
  const _GlassPill({
    required this.message,
    required this.icon,
    required this.actionLabel,
    required this.onAction,
  });

  final String message;
  final IconData? icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    // Always light-on-dark: it usually floats over video.
    const foreground = Color(0xF2FFFFFF);
    // The overlay sits outside any Material, so take the app's font from the
    // theme rather than the bare default text style.
    final textStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
      color: foreground,
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
      decoration: TextDecoration.none,
    );
    final action = actionLabel;
    return GlassPillSurface(
      child: IntrinsicHeight(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  9,
                  action == null ? 16 : 12,
                  9,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 17, color: foreground),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textStyle,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (action != null) ...[
              VerticalDivider(
                width: 1,
                thickness: 0.8,
                indent: 8,
                endIndent: 8,
                color: Colors.white.withValues(alpha: 0.28),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onAction,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 9, 16, 9),
                  child: Center(
                    widthFactor: 1,
                    child: Text(
                      action,
                      style: textStyle?.copyWith(
                        color: const Color(0xFFA8D8FF),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The frosted capsule behind [GlassNotice], also used for in-player pills.
class GlassPillSurface extends StatelessWidget {
  const GlassPillSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(999));
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: 0.20),
                  Colors.black.withValues(alpha: 0.14),
                ],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.28),
                width: 0.8,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

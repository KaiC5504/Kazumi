import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:kazumi/navigation.dart';

/// A short frosted-glass pill at the top of the screen, for room events that
/// shouldn't cover the subtitles the way a bottom toast does.
class GlassNotice {
  GlassNotice._();

  static OverlayEntry? _entry;

  static void show(
    String message, {
    IconData? icon,
    Duration duration = const Duration(milliseconds: 2600),
  }) {
    final overlay = rootNavigatorKey.currentState?.overlay;
    if (overlay == null) return;
    _remove();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _GlassNoticeView(
        message: message,
        icon: icon,
        duration: duration,
        onDone: () {
          if (identical(_entry, entry)) _remove();
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  static void _remove() {
    _entry?.remove();
    _entry = null;
  }
}

class _GlassNoticeView extends StatefulWidget {
  const _GlassNoticeView({
    required this.message,
    required this.icon,
    required this.duration,
    required this.onDone,
  });

  final String message;
  final IconData? icon;
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

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top + 10;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeInCubic,
    );

    return Positioned(
      top: top,
      left: 16,
      right: 16,
      child: IgnorePointer(
        child: Center(
          child: AnimatedBuilder(
            animation: curve,
            builder: (context, child) {
              final t = curve.value;
              return Opacity(
                opacity: _controller.value,
                child: Transform.translate(
                  offset: Offset(0, reduceMotion ? 0 : (1 - t) * -24),
                  child: Transform.scale(
                    scale: reduceMotion ? 1 : 0.9 + 0.1 * t,
                    child: child,
                  ),
                ),
              );
            },
            child: _GlassPill(message: widget.message, icon: widget.icon),
          ),
        ),
      ),
    );
  }
}

class _GlassPill extends StatelessWidget {
  const _GlassPill({required this.message, required this.icon});

  final String message;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(999));
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
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
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
        ),
      ),
    );
  }
}

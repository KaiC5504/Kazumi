import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/bean/dialog/glass_notice.dart';
import 'package:kazumi/services/library/host_router.dart';
import 'package:kazumi/services/library/library_controller.dart';

String routeLabel(LibraryController c) {
  final first = c.router.order.first;
  final name = c.router.isRelay(first) ? '香港' : '新加坡';
  final m = c.storedRoute?.byHost[first.toString()];
  final ms = m?.rttMs == null ? '' : ' · ${m!.rttMs} ms';
  final auto = c.routeMode == RouteMode.auto ? '（自动）' : '';
  return '线路：$name$ms$auto';
}

Future<void> showRouteSheet(BuildContext context, LibraryController c) =>
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => _RouteSheet(controller: c),
    );

class _RouteSheet extends StatefulWidget {
  const _RouteSheet({required this.controller});
  final LibraryController controller;

  @override
  State<_RouteSheet> createState() => _RouteSheetState();
}

class _RouteSheetState extends State<_RouteSheet> {
  bool _checking = false;

  String _line(String name, HostMeasurement? m) {
    if (m == null) return '$name：未测';
    if (!m.ok) return '$name：连不上';
    final mbps = m.bytesPerSecond! * 8 / 1e6;
    return '$name：${m.rttMs} ms · ${mbps.toStringAsFixed(1)} Mbps';
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Observer(
      builder: (context) {
        c.routeVersion.value;
        final stored = c.storedRoute;
        final r = c.router;
        final hk = r.relays.isEmpty ? null : r.relays.first;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('一起看线路', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                SegmentedButton<RouteMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: RouteMode.auto,
                      label: Text('自动（优先香港）'),
                    ),
                    ButtonSegment(value: RouteMode.hk, label: Text('香港')),
                    ButtonSegment(value: RouteMode.sg, label: Text('新加坡')),
                  ],
                  selected: {c.routeMode},
                  onSelectionChanged: (s) => c.setRouteMode(s.first),
                ),
                const SizedBox(height: 12),
                if (hk != null)
                  Text(_line('香港', stored?.byHost[hk.toString()])),
                Text(_line('新加坡', stored?.byHost[r.server.toString()])),
                if (stored != null)
                  Text(
                    '测于 ${stored.at.toLocal().toString().substring(0, 16)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: _checking
                      ? null
                      : () async {
                          setState(() => _checking = true);
                          final result = await c.recheckRoute();
                          if (result == null) {
                            GlassNotice.show(
                              '测速失败，仍用原线路',
                              icon: Icons.wifi_off_rounded,
                            );
                          }
                          if (mounted) setState(() => _checking = false);
                        },
                  icon: _checking
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.speed_rounded),
                  label: Text(_checking ? '测速中…' : '重新测速'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

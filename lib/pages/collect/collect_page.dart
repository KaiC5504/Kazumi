import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/widget/state_presentation.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/sync_priority.dart';
import 'package:kazumi/modules/collect/collect_layout.dart';
import 'package:kazumi/modules/collect/collect_sync_plan.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/collect/collect_library_view.dart';
import 'package:kazumi/pages/collect/collect_sync_dialog.dart';
import 'package:kazumi/pages/collect/collect_watch_progress.dart';
import 'package:kazumi/repositories/history_repository.dart';
import 'package:kazumi/services/layout/classic_layout.dart';
import 'package:kazumi/services/storage/storage.dart';

class CollectPage extends StatefulWidget {
  const CollectPage({
    super.key,
    required this.controller,
  });

  final CollectController controller;

  @override
  State<CollectPage> createState() => _CollectPageState();
}

class _CollectPageState extends State<CollectPage> with KazumiDialogOwner {
  CollectController get collectController => widget.controller;
  bool get _syncDialogOpen => dialogs.isRunning;
  final Set<int> _pendingIds = {};
  late CollectLayout _layout;
  final _historyRepository = inject<IHistoryRepository>();
  Map<int, String> _watchProgress = const {};
  StreamSubscription<void>? _historyChanges;
  Timer? _historyRefresh;

  Future<bool> _syncStep(
    CollectSyncStep step, {
    required ValueChanged<String> onError,
    required void Function(String message, int current, int total) onProgress,
  }) =>
      switch (step) {
        CollectSyncStep.webDav => collectController.syncCollectibles(
            onError: onError,
          ),
        CollectSyncStep.bangumi => collectController.syncCollectiblesBangumi(
            onError: onError,
            onProgress: onProgress,
          ),
        CollectSyncStep.upload => collectController.uploadCollectiblesToWebDav(
            onError: onError,
          ),
      };

  @override
  void initState() {
    super.initState();
    // Read once; page switches never change the saved default.
    _layout = CollectLayout.fromValue(
      GStorage.getSetting(SettingsKeys.defaultCollectLayout),
    );
    ClassicLayout.listenable.addListener(_onClassicChanged);
    collectController.loadCollectibles();
    _loadWatchProgress();
    _historyChanges = _historyRepository.changes.listen((_) {
      // Playback writes history every few seconds.
      _historyRefresh?.cancel();
      _historyRefresh = Timer(const Duration(milliseconds: 300), () {
        if (mounted) setState(_loadWatchProgress);
      });
    });
  }

  // The tab stays mounted under settings, where 经典布局 also resets the
  // default layout.
  void _onClassicChanged() => setState(() {
        _layout = CollectLayout.fromValue(
          GStorage.getSetting(SettingsKeys.defaultCollectLayout),
        );
      });

  @override
  void dispose() {
    ClassicLayout.listenable.removeListener(_onClassicChanged);
    _historyRefresh?.cancel();
    _historyChanges?.cancel();
    super.dispose();
  }

  void _loadWatchProgress() {
    _watchProgress =
        collectWatchProgress(_historyRepository.getAllHistories());
  }

  void _changeLayout(CollectLayout layout) {
    if (_layout == layout) return;
    setState(() => _layout = layout);
  }

  Future<void> _changeType(BangumiItem item, CollectType type) async {
    if (_syncDialogOpen || _pendingIds.contains(item.id)) return;
    setState(() => _pendingIds.add(item.id));
    try {
      await collectController.addCollect(item, type: type.value);
    } catch (_) {
      KazumiDialog.showToast(message: '修改收藏状态失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _pendingIds.remove(item.id));
    }
  }

  Future<void> _sync() async {
    if (_syncDialogOpen || _pendingIds.isNotEmpty) return;
    final plan = CollectSyncPlan(
      webDavEnabled: GStorage.getSetting(SettingsKeys.webDavEnable),
      webDavCollectiblesEnabled:
          GStorage.getSetting(SettingsKeys.webDavEnableCollect),
      bangumiEnabled: GStorage.getSetting(SettingsKeys.bangumiSyncEnable),
    );
    await dialogs.run((task) async {
      final destination = await task.show<CollectSyncDestination>(
        builder: (_) => CollectSyncDialog(
          plan: plan,
          priority: BangumiSyncPriority.fromValue(
            GStorage.getSetting(SettingsKeys.bangumiSyncPriority),
          ),
          onSync: _syncStep,
        ),
      );
      task.withContext((context) => context.pushNamed(switch (destination) {
            CollectSyncDestination.webDavSettings => '/settings/webdav/',
            CollectSyncDestination.bangumiSettings => '/settings/bangumi/',
          }));
    }, errorMessage: '同步未完成，请稍后重试');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        top: false,
        bottom: false,
        child: Observer(
          builder: (context) => CollectLibraryView(
            title: '追番',
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Tooltip(
                  message: '同步收藏',
                  child: StateActionButton.tonal(
                    text: '同步',
                    onPressed: _syncDialogOpen || _pendingIds.isNotEmpty
                        ? null
                        : _sync,
                    icon: Icons.sync_rounded,
                  ),
                ),
              ),
            ],
            entries: collectController.collectibles.toList(),
            showRating: GStorage.getSetting(SettingsKeys.showRating),
            watchProgress: _watchProgress,
            layout: _layout,
            onLayoutChanged: _changeLayout,
            classic: ClassicLayout.enabled,
            canEdit: (item) =>
                !_syncDialogOpen && !_pendingIds.contains(item.id),
            onOpen: (item) => context.pushNamed('/info/', arguments: item),
            onChangeType: (item, type) => unawaited(_changeType(item, type)),
          ),
        ),
      ),
    );
  }
}

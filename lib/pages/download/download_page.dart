import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/download/cloud_bake_sheets.dart';
import 'package:kazumi/pages/download/download_widgets.dart';
import 'package:kazumi/bean/widget/kazumi_menu.dart';
import 'package:kazumi/pages/download/upscaled_transfer_sheets.dart';
import 'package:kazumi/services/download/offline_launch.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_session.dart';
import 'package:kazumi/services/upscale/upscale_controller.dart';
import 'package:kazumi/utils/device.dart';
import 'package:kazumi/utils/format.dart';

class DownloadPage extends StatefulWidget {
  const DownloadPage({
    super.key,
    required this.controller,
    required this.upscaleController,
  });

  final DownloadController controller;
  final UpscaleController upscaleController;

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  DownloadController get downloadController => widget.controller;
  UpscaleController get upscaleController => widget.upscaleController;

  // Keep expansion state across controller snapshot replacements.
  final Map<String, bool> _expanded = {};

  @override
  void initState() {
    super.initState();
    downloadController.refreshRecords();
    if (upscaleController.canBake) {
      unawaited(upscaleController.refreshLibrary());
    }
  }

  bool _isExpanded(String recordKey, DownloadRecord record) {
    return _expanded.putIfAbsent(
      recordKey,
      () => record.episodes.values
          .any((e) => e.status != DownloadStatus.completed),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SysAppBar(
        title: const Text('下载管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.drive_folder_upload_rounded),
            tooltip: '导入超分剧集',
            onPressed: () => showUpscaledImportFlow(context, upscaleController),
          ),
          if (!isDesktop())
            IconButton(
              icon: const Icon(Icons.wifi_rounded),
              tooltip: '从电脑拉取超分剧集',
              onPressed: () => showLanPullFlow(context, upscaleController),
            ),
          if (upscaleController.canBake &&
              upscaleController.canUploadToLibrary)
            IconButton(
              icon: const Icon(Icons.cloud_sync_outlined),
              tooltip: '刷新片库状态',
              onPressed: _refreshLibrary,
            ),
        ],
      ),
      body: _withCloudBanner(Observer(builder: (context) {
        final recordKeys = downloadController.recordKeys.toList();
        _expanded.removeWhere((key, _) => !recordKeys.contains(key));
        if (recordKeys.isEmpty) {
          return const GeneralEmptyState(
            icon: Icons.download_rounded,
            title: '还没有下载记录',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: recordKeys.length,
          itemBuilder: (context, index) {
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: _buildRecordCard(recordKeys[index]),
              ),
            );
          },
        );
      })),
    );
  }

  Widget _withCloudBanner(Widget list) {
    if (!upscaleController.canBake) return list;
    return Column(
      children: [
        CloudBakeBanner(
          session: upscaleController.cloudSession,
          onStop: upscaleController.stopCloudBake,
        ),
        Expanded(child: list),
      ],
    );
  }

  Widget _buildRecordCard(String recordKey) {
    return Observer(builder: (context) {
      final record = downloadController.getRecordSnapshot(recordKey);
      if (record == null) {
        return const SizedBox.shrink();
      }

      var totalSpeed = 0.0;
      for (final e in record.episodes.values) {
        if (e.status == DownloadStatus.downloading) {
          totalSpeed += downloadController.getSpeed(
            record.bangumiId,
            record.pluginName,
            e.episodeNumber,
          );
        }
      }
      final expanded = _isExpanded(recordKey, record);

      return DownloadRecordCard(
        record: record,
        expanded: expanded,
        onToggle: () {
          setState(() => _expanded[recordKey] = !expanded);
        },
        onResumeAll: () {
          downloadController.resumeAllDownloads(
            record.bangumiId,
            record.pluginName,
          );
          KazumiDialog.showToast(message: '已开始恢复下载');
        },
        onDeleteAll: () => _confirmDeleteRecord(record),
        extraMenuItems: [
          if (upscaleController.canBake)
            KazumiMenuItem(
              label: '全部烘焙超分',
              onPressed: () => _bakeAll(record),
            ),
          if (upscaleController.canBake)
            KazumiMenuItem(
              label: '☁ 云端烘焙全部',
              onPressed: () => showCloudBakeFlow(
                context,
                upscaleController,
                record,
                bakeAllLocally: () => _bakeAll(record),
              ),
            ),
          if (upscaleController.canBake)
            KazumiMenuItem(
              label: '全部上传到片库',
              onPressed: () => _uploadAll(record),
            ),
          if (upscaleController.canBake)
            KazumiMenuItem(
              label: '分析片头片尾',
              onPressed: () => _analyzeSkips(record),
            ),
        ],
        totalSpeed: totalSpeed,
        episodeTileBuilder: () {
          final episodes = record.episodes.values.toList()
            ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
          return episodes.map((ep) => _buildEpisodeTile(record, ep)).toList();
        },
      );
    });
  }

  Widget _buildEpisodeTile(DownloadRecord record, DownloadEpisode episode) {
    // Bake/export progress lives outside the record snapshot, so the tile
    // observes it on its own.
    return Observer(builder: (context) {
      final key =
          UpscaleController.progressKey(record.key, episode.episodeNumber);
      final bakeProgress = upscaleController.bakeProgress[key];
      final exportProgress = upscaleController.exportProgress[key];
      final uploadProgress = upscaleController.uploadProgress[key];
      final cloudPhase = upscaleController.cloudPhases[key];
      return DownloadEpisodeTile(
        episode: episode,
        statusText: _getStatusText(record, episode,
            bakeProgress: bakeProgress,
            exportProgress: exportProgress,
            uploadProgress: uploadProgress,
            cloudPhase: cloudPhase,
            uploadQueued: uploadProgress != null &&
                upscaleController.activeUpload.value != key,
            inLibrary: upscaleController.isInLibrary(
                record.key, episode.episodeNumber)),
        actions: _getActionButtons(record, episode),
        taskProgress: uploadProgress ??
            exportProgress ??
            cloudPhase?.progress ??
            bakeProgress ??
            (episode.upscaleStatus == UpscaleStatus.queued ? 0 : null),
        onPlay: episode.status == DownloadStatus.completed
            ? () => _playEpisode(record, episode)
            : null,
      );
    });
  }

  String _getStatusText(DownloadRecord record, DownloadEpisode episode,
      {double? bakeProgress,
      double? exportProgress,
      double? uploadProgress,
      CloudEpisodePhase? cloudPhase,
      bool uploadQueued = false,
      bool inLibrary = false}) {
    switch (episode.status) {
      case DownloadStatus.completed:
        final base = '已完成 · ${formatBytes(episode.totalBytes)}';
        if (episode.preUpscaled) return '$base · 超分版';
        if (uploadQueued) return '$base · 等待上传到片库';
        if (uploadProgress != null) {
          return '$base · 正在上传到片库 ${(uploadProgress * 100).toStringAsFixed(0)}%';
        }
        if (exportProgress != null) {
          return '$base · 正在导出 ${(exportProgress * 100).toStringAsFixed(0)}%';
        }
        if (cloudPhase != null) return '$base · ${cloudStatusText(cloudPhase)}';
        switch (episode.upscaleStatus) {
          case UpscaleStatus.queued:
            return '$base · 等待烘焙超分';
          case UpscaleStatus.baking:
            final percent = ((bakeProgress ?? 0) * 100).toStringAsFixed(0);
            return '$base · 正在烘焙超分 $percent%';
          case UpscaleStatus.done:
            return inLibrary ? '$base · 已烘焙超分 · 已在片库' : '$base · 已烘焙超分';
          case UpscaleStatus.failed:
            return episode.errorMessage.isNotEmpty
                ? episode.errorMessage
                : '$base · 超分失败';
        }
        return base;
      case DownloadStatus.downloading:
        final speed = downloadController.getSpeed(
          record.bangumiId,
          record.pluginName,
          episode.episodeNumber,
        );
        final speedText = speed > 0 ? ' · ${formatSpeed(speed)}' : '';
        return '${(episode.progressPercent * 100).toStringAsFixed(0)}% · '
            '${episode.downloadedSegments}/${episode.totalSegments} 分片$speedText';
      case DownloadStatus.failed:
        return episode.errorMessage.isNotEmpty ? episode.errorMessage : '下载失败';
      case DownloadStatus.paused:
        return '已暂停 · ${(episode.progressPercent * 100).toStringAsFixed(0)}%';
      case DownloadStatus.pending:
        return '排队中';
      case DownloadStatus.resolving:
        return '正在解析视频源';
      default:
        return '';
    }
  }

  List<Widget> _getActionButtons(
      DownloadRecord record, DownloadEpisode episode) {
    final colorScheme = Theme.of(context).colorScheme;
    final buttons = <Widget>[];

    switch (episode.status) {
      case DownloadStatus.completed:
        buttons.add(IconButton(
          icon: Icon(Icons.play_circle_outline,
              size: 20, color: colorScheme.primary),
          onPressed: () => _playEpisode(record, episode),
          tooltip: '播放',
          visualDensity: VisualDensity.compact,
        ));
        buttons.addAll(_upscaleActions(record, episode));
        break;
      case DownloadStatus.downloading:
        buttons.add(IconButton(
          icon: const Icon(Icons.pause_rounded, size: 20),
          onPressed: () => downloadController.pauseDownload(
            record.bangumiId,
            record.pluginName,
            episode.episodeNumber,
          ),
          tooltip: '暂停',
          visualDensity: VisualDensity.compact,
        ));
        break;
      case DownloadStatus.paused:
        buttons.add(IconButton(
          icon: const Icon(Icons.play_arrow_rounded, size: 20),
          onPressed: () => downloadController.retryDownload(
            bangumiId: record.bangumiId,
            pluginName: record.pluginName,
            episodeNumber: episode.episodeNumber,
          ),
          tooltip: '继续',
          visualDensity: VisualDensity.compact,
        ));
        break;
      case DownloadStatus.failed:
        buttons.add(IconButton(
          icon: const Icon(Icons.refresh_rounded, size: 20),
          onPressed: () => downloadController.retryDownload(
            bangumiId: record.bangumiId,
            pluginName: record.pluginName,
            episodeNumber: episode.episodeNumber,
          ),
          tooltip: '重试',
          visualDensity: VisualDensity.compact,
        ));
        break;
      case DownloadStatus.pending:
        buttons.add(IconButton(
          icon: Icon(Icons.priority_high, size: 20, color: colorScheme.primary),
          onPressed: () {
            downloadController.priorityDownload(
              bangumiId: record.bangumiId,
              pluginName: record.pluginName,
              episodeNumber: episode.episodeNumber,
            );
            KazumiDialog.showToast(message: '已插队优先下载');
          },
          tooltip: '优先下载',
          visualDensity: VisualDensity.compact,
        ));
        break;
      default:
        break;
    }

    buttons.add(IconButton(
      icon: Icon(Icons.delete_outline,
          size: 20, color: colorScheme.onSurfaceVariant),
      onPressed: () => _confirmDeleteEpisode(record, episode),
      tooltip: '删除',
      visualDensity: VisualDensity.compact,
    ));

    return buttons;
  }

  List<Widget> _upscaleActions(DownloadRecord record, DownloadEpisode episode) {
    if (!upscaleController.canBake || episode.preUpscaled) return const [];
    final colorScheme = Theme.of(context).colorScheme;
    final cloudButton = IconButton(
      icon: Icon(Icons.cloud_upload_outlined,
          size: 20, color: colorScheme.tertiary),
      onPressed: () => showCloudEpisodeFlow(
          context, upscaleController, record, episode.episodeNumber),
      tooltip: '云端烘焙 (加入云端队列)',
      visualDensity: VisualDensity.compact,
    );
    // Once uploading, cloud episodes are cancelled with the banner's stop
    // button.
    if (episode.upscaleStatus == UpscaleStatus.queued &&
        upscaleController.cloudHolds(record.key, episode.episodeNumber)) {
      if (!upscaleController.cloudQueued(record.key, episode.episodeNumber)) {
        return const [];
      }
      return [
        IconButton(
          icon: const Icon(Icons.cloud_off_outlined, size: 20),
          onPressed: () => upscaleController.removeFromCloud(
              record.key, episode.episodeNumber),
          tooltip: '移出云端队列',
          visualDensity: VisualDensity.compact,
        ),
      ];
    }
    switch (episode.upscaleStatus) {
      case UpscaleStatus.queued:
      case UpscaleStatus.baking:
        return [
          IconButton(
            icon: const Icon(Icons.stop_circle_outlined, size: 20),
            onPressed: () => upscaleController.cancelBake(
                record.key, episode.episodeNumber),
            tooltip: '取消烘焙',
            visualDensity: VisualDensity.compact,
          ),
          if (episode.upscaleStatus == UpscaleStatus.queued) cloudButton,
        ];
      case UpscaleStatus.done:
        return [
          IconButton(
            icon: Icon(Icons.ios_share_rounded,
                size: 20, color: colorScheme.tertiary),
            onPressed: () => _exportEpisode(record, episode),
            tooltip: '导出超分版本',
            visualDensity: VisualDensity.compact,
          ),
          _uploadAction(record, episode),
        ];
      default:
        return [
          IconButton(
            icon: Icon(Icons.auto_awesome_outlined,
                size: 20, color: colorScheme.tertiary),
            onPressed: () => _bakeEpisode(record, episode),
            tooltip: '烘焙超分 (质量档)',
            visualDensity: VisualDensity.compact,
          ),
          cloudButton,
        ];
    }
  }

  Future<void> _bakeEpisode(
      DownloadRecord record, DownloadEpisode episode) async {
    final error =
        await upscaleController.enqueueBake(record.key, episode.episodeNumber);
    KazumiDialog.showToast(message: error ?? '已加入超分烘焙队列');
  }

  Future<void> _bakeAll(DownloadRecord record) async {
    var queued = 0;
    String? lastError;
    final episodes = record.episodes.values.toList()
      ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
    for (final episode in episodes) {
      if (episode.status != DownloadStatus.completed ||
          episode.preUpscaled ||
          episode.upscaleStatus == UpscaleStatus.done) {
        continue;
      }
      final error = await upscaleController.enqueueBake(
          record.key, episode.episodeNumber);
      if (error == null) {
        queued++;
      } else {
        lastError = error;
      }
    }
    KazumiDialog.showToast(
        message: queued > 0
            ? '已加入 $queued 集到超分烘焙队列'
            : (lastError ?? '没有可烘焙的剧集'));
  }

  Future<void> _analyzeSkips(DownloadRecord record) async {
    if (upscaleController.analyzingSkips.contains(record.key)) {
      KazumiDialog.showToast(message: '正在分析中');
      return;
    }
    KazumiDialog.showToast(message: '开始分析片头片尾，每集约需几秒');
    final int? changed;
    try {
      changed = await upscaleController.analyzeSkips(record.key);
    } catch (e) {
      KazumiLogger().e('DownloadPage: skip analysis failed', error: e);
      KazumiDialog.showToast(message: '分析失败: $e');
      return;
    }
    KazumiDialog.showToast(
        message: changed == null
            ? 'ffmpeg 不支持 chromaprint，请使用 gyan.dev full 版本'
            : changed > 0
                ? '已更新 $changed 集的片头片尾，已导出的剧集请在 iPad 上重新导入'
                : '片头片尾没有变化');
  }

  Widget _uploadAction(DownloadRecord record, DownloadEpisode episode) {
    final colorScheme = Theme.of(context).colorScheme;
    final key =
        UpscaleController.progressKey(record.key, episode.episodeNumber);
    if (upscaleController.uploadProgress.containsKey(key)) {
      return IconButton(
        icon: const Icon(Icons.stop_circle_outlined, size: 20),
        onPressed: () =>
            upscaleController.cancelUpload(record.key, episode.episodeNumber),
        tooltip: '取消上传',
        visualDensity: VisualDensity.compact,
      );
    }
    if (upscaleController.isInLibrary(record.key, episode.episodeNumber)) {
      return IconButton(
        icon: Icon(Icons.cloud_done_rounded,
            size: 20, color: colorScheme.tertiary),
        onPressed: () => _confirmReupload(record, episode),
        tooltip: '已在片库，点击重新上传',
        visualDensity: VisualDensity.compact,
      );
    }
    return IconButton(
      icon: Icon(Icons.cloud_upload_outlined,
          size: 20, color: colorScheme.tertiary),
      onPressed: () => _uploadEpisode(record, episode),
      tooltip: '上传到片库',
      visualDensity: VisualDensity.compact,
    );
  }

  void _confirmReupload(DownloadRecord record, DownloadEpisode episode) {
    KazumiDialog.show(
      builder: (context) => AlertDialog(
        title: const Text('重新上传'),
        content: const Text('片库里已有这一集，要重新上传吗？'),
        actions: [
          TextButton(
            onPressed: () => KazumiDialog.dismiss(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              KazumiDialog.dismiss();
              _uploadEpisode(record, episode);
            },
            child: const Text('重新上传'),
          ),
        ],
      ),
    );
  }

  Future<void> _refreshLibrary() async {
    await upscaleController.refreshLibrary();
    KazumiDialog.showToast(
        message: '片库中有 ${upscaleController.libraryIds.length} 集');
  }

  void _uploadEpisode(DownloadRecord record, DownloadEpisode episode) {
    final error =
        upscaleController.enqueueUpload(record.key, episode.episodeNumber);
    KazumiDialog.showToast(message: error ?? '已加入片库上传队列');
  }

  void _uploadAll(DownloadRecord record) {
    var queued = 0;
    String? lastError;
    final episodes = record.episodes.values.toList()
      ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
    var skipped = 0;
    for (final episode in episodes) {
      if (episode.upscaleStatus != UpscaleStatus.done) continue;
      if (upscaleController.isInLibrary(record.key, episode.episodeNumber)) {
        skipped++;
        continue;
      }
      final error =
          upscaleController.enqueueUpload(record.key, episode.episodeNumber);
      if (error == null) {
        queued++;
      } else {
        lastError = error;
      }
    }
    KazumiDialog.showToast(
        message: queued > 0
            ? '已加入 $queued 集到片库上传队列'
            : skipped > 0
                ? '已烘焙的剧集都在片库里了'
                : (lastError ?? '没有已烘焙的剧集，请先烘焙超分'));
  }

  Future<void> _exportEpisode(
      DownloadRecord record, DownloadEpisode episode) async {
    if (!await ensureUpscaleExportDirectory()) return;
    final error =
        await upscaleController.export(record.key, episode.episodeNumber);
    KazumiDialog.showToast(message: error ?? '已导出，可在 iPad 上导入');
  }

  void _playEpisode(DownloadRecord record, DownloadEpisode episode) {
    final localPath = downloadController.getLocalVideoPath(
      record.bangumiId,
      record.pluginName,
      episode.episodeNumber,
    );
    if (localPath == null) {
      KazumiDialog.showToast(message: '本地文件不存在');
      return;
    }

    context.pushNamed(
      '/video/',
      arguments: buildOfflineArgs(
        record: record,
        episodeNumber: episode.episodeNumber,
        road: episode.road,
        completed: downloadController.getCompletedEpisodes(
            record.bangumiId, record.pluginName),
      ),
    );
  }

  void _confirmDeleteEpisode(DownloadRecord record, DownloadEpisode episode) {
    KazumiDialog.show(
      builder: (context) => AlertDialog(
        title: const Text('删除下载'),
        content: Text(
            '确定要删除「${episode.episodeName.isNotEmpty ? episode.episodeName : '第${episode.episodeNumber}集'}」的下载文件吗？'),
        actions: [
          TextButton(
            onPressed: () => KazumiDialog.dismiss(),
            child: Text(
              '取消',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ),
          TextButton(
            onPressed: () {
              downloadController.deleteEpisode(
                record.bangumiId,
                record.pluginName,
                episode.episodeNumber,
              );
              KazumiDialog.dismiss();
            },
            child: Text(
              '删除',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteRecord(DownloadRecord record) {
    KazumiDialog.show(
      builder: (context) => AlertDialog(
        title: const Text('删除全部下载'),
        content: Text('确定要删除「${record.bangumiName}」的所有下载文件吗？'),
        actions: [
          TextButton(
            onPressed: () => KazumiDialog.dismiss(),
            child: Text(
              '取消',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ),
          TextButton(
            onPressed: () {
              downloadController.deleteRecord(
                record.bangumiId,
                record.pluginName,
              );
              KazumiDialog.dismiss();
            },
            child: Text(
              '删除',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }
}

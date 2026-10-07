import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';

import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/pages/library/route_sheet.dart';
import 'package:kazumi/services/library/library_api.dart';
import 'package:kazumi/services/library/library_controller.dart';
import 'package:kazumi/services/library/library_invite.dart';

/// The watch-together lobby. Being on this page means being in the room:
/// whoever taps an episode opens it on both devices.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.controller});

  final LibraryController controller;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  LibraryController get controller => widget.controller;
  StreamSubscription<LibraryEpisode>? _picks;
  bool _inLobby = false;

  @override
  void initState() {
    super.initState();
    _picks = controller.remotePicks.listen(_onRemotePick);
    _syncLobby();
  }

  @override
  void dispose() {
    _picks?.cancel();
    if (_inLobby) unawaited(controller.leaveLobby());
    super.dispose();
  }

  void _syncLobby() {
    if (controller.isConfigured && !_inLobby) {
      _inLobby = true;
      unawaited(controller.enterLobby());
    }
  }

  void _onRemotePick(LibraryEpisode episode) {
    if (!mounted) return;
    final who = controller.room.value.selection?.by ?? '对方';
    KazumiDialog.showToast(
      message: '$who 选了 ${episode.manifest.displayEpisodeName}，正在打开',
    );
    controller.openEpisode(context, episode, announce: false);
  }

  Future<void> _pasteInvite() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final invite = LibraryInvite.parse(data?.text ?? '');
    if (invite == null) {
      KazumiDialog.showToast(message: '剪贴板里没有邀请链接，请先复制对方发来的链接');
      return;
    }
    controller.showInvite(invite);
  }

  Future<void> _rename() async {
    final name = await _askName(context, initial: controller.displayName);
    if (name != null && name.isNotEmpty) {
      await controller.setDisplayName(name);
    }
  }

  Future<void> _confirmLeave() async {
    final leave = await KazumiDialog.show<bool>(
      builder: (context) => AlertDialog(
        title: const Text('退出片库'),
        content: const Text('退出后需要重新打开邀请链接才能加入。已下载的剧集会保留。'),
        actions: [
          TextButton(
            onPressed: () => KazumiDialog.dismiss(popWith: false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => KazumiDialog.dismiss(popWith: true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (leave == true) {
      _inLobby = false;
      await controller.leaveLibrary();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SysAppBar(
        title: const Text('一起看'),
        actions: [
          Observer(
            builder: (context) {
              controller.configVersion.value;
              if (!controller.isConfigured) return const SizedBox.shrink();
              return PopupMenuButton<String>(
                onSelected: (value) {
                  switch (value) {
                    case 'rename':
                      _rename();
                    case 'wifi':
                      controller.setWifiOnly(!controller.wifiOnly);
                    case 'leave':
                      _confirmLeave();
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'rename',
                    child: Text('修改名字（${controller.displayName}）'),
                  ),
                  CheckedPopupMenuItem(
                    value: 'wifi',
                    checked: controller.wifiOnly,
                    child: const Text('仅在 Wi-Fi 下自动下载'),
                  ),
                  const PopupMenuItem(value: 'leave', child: Text('退出片库')),
                ],
              );
            },
          ),
        ],
      ),
      body: Observer(
        builder: (context) {
          controller.configVersion.value;
          final invite = controller.pendingInvite.value;
          if (invite != null) {
            return _InviteView(controller: controller, invite: invite);
          }
          if (!controller.isConfigured) {
            return _NotJoinedView(
              controller: controller,
              onPaste: _pasteInvite,
            );
          }
          WidgetsBinding.instance.addPostFrameCallback((_) => _syncLobby());
          return _LobbyView(controller: controller);
        },
      ),
    );
  }
}

Future<String?> _askName(BuildContext context, {String initial = ''}) {
  final textController = TextEditingController(text: initial);
  return KazumiDialog.show<String>(
    builder: (context) => AlertDialog(
      title: const Text('你的名字'),
      content: TextField(
        controller: textController,
        autofocus: true,
        maxLength: 16,
        decoration: const InputDecoration(
          hintText: '对方会看到这个名字',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => KazumiDialog.dismiss(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () =>
              KazumiDialog.dismiss(popWith: textController.text.trim()),
          child: const Text('保存'),
        ),
      ],
    ),
  ).whenComplete(textController.dispose);
}

class _InviteView extends StatefulWidget {
  const _InviteView({required this.controller, required this.invite});

  final LibraryController controller;
  final LibraryInvite invite;

  @override
  State<_InviteView> createState() => _InviteViewState();
}

class _InviteViewState extends State<_InviteView> {
  late final TextEditingController _name = TextEditingController(
    text: widget.controller.displayName,
  );
  bool _joining = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '先写一个名字吧');
      return;
    }
    setState(() {
      _joining = true;
      _error = null;
    });
    final error = await widget.controller.acceptInvite(widget.invite, name);
    if (!mounted) return;
    setState(() {
      _joining = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: _Entrance(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: _GlowingHeart(size: 88)),
                const SizedBox(height: 28),
                Text(
                  '有人邀请你一起看番',
                  textAlign: TextAlign.center,
                  style: text.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '加入后，你们任何一个人点开一集，两边会同时开始播放',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _name,
                  maxLength: 16,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _join(),
                  decoration: const InputDecoration(
                    labelText: '你的名字',
                    hintText: '对方会看到这个名字',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 4),
                  Text(_error!, style: TextStyle(color: colors.error)),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _joining ? null : _join,
                  icon: _joining
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.favorite_rounded),
                  label: Text(_joining ? '正在加入…' : '加入一起看'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                    textStyle: text.titleMedium,
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _joining ? null : widget.controller.dismissInvite,
                  child: const Text('暂不加入'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NotJoinedView extends StatefulWidget {
  const _NotJoinedView({required this.controller, required this.onPaste});

  final LibraryController controller;
  final VoidCallback onPaste;

  @override
  State<_NotJoinedView> createState() => _NotJoinedViewState();
}

class _NotJoinedViewState extends State<_NotJoinedView> {
  final _code = TextEditingController();
  bool _checking = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    final error = await widget.controller.redeemCode(_code.text);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: _Entrance(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: _GlowingHeart(size: 72)),
                const SizedBox(height: 24),
                Text(
                  '输入邀请码',
                  textAlign: TextAlign.center,
                  style: text.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '对方发给你的 8 位邀请码，例如 KZ7M-4QPA',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _code,
                  textAlign: TextAlign.center,
                  textCapitalization: TextCapitalization.characters,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 9,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _submit(),
                  style: text.headlineSmall?.copyWith(
                    letterSpacing: 6,
                    fontWeight: FontWeight.w700,
                  ),
                  decoration: InputDecoration(
                    hintText: 'XXXX-XXXX',
                    counterText: '',
                    errorText: _error,
                    errorMaxLines: 3,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _checking ? null : _submit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                    textStyle: text.titleMedium,
                  ),
                  child: Text(_checking ? '正在验证…' : '下一步'),
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: widget.onPaste,
                  icon: const Icon(Icons.link_rounded),
                  label: const Text('收到的是链接？复制后点这里'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LobbyView extends StatelessWidget {
  const _LobbyView({required this.controller});

  final LibraryController controller;

  @override
  Widget build(BuildContext context) {
    return Observer(
      builder: (context) {
        final episodes = controller.episodes.toList();
        final error = controller.error.value;
        final notice = controller.notice.value;
        final seriesKeys = <String>[];
        for (final e in episodes) {
          if (!seriesKeys.contains(e.manifest.recordKey)) {
            seriesKeys.add(e.manifest.recordKey);
          }
        }

        return RefreshIndicator(
          onRefresh: controller.refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Entrance(child: _RoomCard(controller: controller)),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Observer(
                          builder: (context) {
                            controller.routeVersion.value;
                            return TextButton.icon(
                              onPressed: () =>
                                  showRouteSheet(context, controller),
                              icon: const Icon(
                                Icons.alt_route_rounded,
                                size: 18,
                              ),
                              label: Text(routeLabel(controller)),
                            );
                          },
                        ),
                      ),
                      if (notice != null) ...[
                        const SizedBox(height: 12),
                        _Banner(icon: Icons.wifi_off_rounded, text: notice),
                      ],
                      if (error != null) ...[
                        const SizedBox(height: 12),
                        _Banner(
                          icon: Icons.cloud_off_rounded,
                          text: error,
                          isError: true,
                        ),
                      ],
                      const SizedBox(height: 20),
                      if (episodes.isEmpty && !controller.loading.value)
                        const _EmptyLibrary()
                      else
                        for (final (index, key) in seriesKeys.indexed)
                          _Entrance(
                            key: ValueKey(key),
                            delay: Duration(milliseconds: 80 * (index + 1)),
                            child: _SeriesSection(
                              controller: controller,
                              initiallyExpanded: seriesKeys.length == 1,
                              episodes: controller.seriesOf(
                                episodes.firstWhere(
                                  (e) => e.manifest.recordKey == key,
                                ),
                              ),
                            ),
                          ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RoomCard extends StatelessWidget {
  const _RoomCard({required this.controller});

  final LibraryController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Observer(
      builder: (context) {
        final members = controller.room.value.members;
        final me = controller.deviceId;
        final others = members.where((m) => m.deviceId != me).toList();

        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [colors.primaryContainer, colors.tertiaryContainer],
            ),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const _GlowingHeart(size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      others.isEmpty ? '等对方进来…' : '你们都在',
                      style: text.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colors.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                others.isEmpty
                    ? '对方打开「一起看」后会出现在这里。谁先点一集，两边就一起开始。'
                    : '点任意一集，对方那边会同时打开',
                style: text.bodyMedium?.copyWith(
                  color: colors.onPrimaryContainer.withValues(alpha: 0.8),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _MemberChip(
                    name: controller.displayName,
                    status: '我',
                    online: true,
                  ),
                  for (final member in others)
                    _MemberChip(
                      name: member.name,
                      status: _statusOf(member),
                      online: true,
                      onJoin: member.watching && member.episodeId != null
                          ? () => _joinMember(context, member)
                          : null,
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  String _statusOf(LibraryMember member) {
    if (!member.watching) return '在大厅';
    final episode = controller.episodes
        .where((e) => e.id == member.episodeId)
        .firstOrNull;
    if (episode == null) return '正在看';
    return '正在看 ${episode.manifest.displayEpisodeName}';
  }

  void _joinMember(BuildContext context, LibraryMember member) {
    final episode = controller.episodes
        .where((e) => e.id == member.episodeId)
        .firstOrNull;
    if (episode == null) {
      controller.refresh();
      return;
    }
    controller.openEpisode(context, episode, announce: false);
  }
}

class _MemberChip extends StatelessWidget {
  const _MemberChip({
    required this.name,
    required this.status,
    required this.online,
    this.onJoin,
  });

  final String name;
  final String status;
  final bool online;
  final VoidCallback? onJoin;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final initial = name.isEmpty ? '?' : name.characters.first;
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(40),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: colors.primary,
                foregroundColor: colors.onPrimary,
                child: Text(initial),
              ),
              if (online)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: _PulseDot(color: Colors.greenAccent.shade400),
                ),
            ],
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name.isEmpty ? '未命名' : name,
                style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
              Text(status, style: text.bodySmall),
            ],
          ),
          if (onJoin != null) ...[
            const SizedBox(width: 12),
            FilledButton(
              onPressed: onJoin,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('加入'),
            ),
          ],
        ],
      ),
    );
  }
}

class _SeriesSection extends StatefulWidget {
  const _SeriesSection({
    required this.controller,
    required this.episodes,
    required this.initiallyExpanded,
  });

  final LibraryController controller;
  final List<LibraryEpisode> episodes;
  final bool initiallyExpanded;

  @override
  State<_SeriesSection> createState() => _SeriesSectionState();
}

class _SeriesSectionState extends State<_SeriesSection> {
  static const _expandDuration = Duration(milliseconds: 250);
  static const _expandCurve = Curves.easeInOutCubic;

  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final episodes = widget.episodes;
    final manifest = episodes.first.manifest;
    final watched = episodes.where(widget.controller.isWatchedByMe).length;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
              child: Row(
                children: [
                  NetworkImgLayer(
                    src: manifest.bangumiCover,
                    width: 48,
                    height: 66,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          manifest.bangumiName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            '${episodes.length} 集',
                            if (watched > 0) '已看 $watched',
                            '${manifest.height}p 超分',
                          ].join(' · '),
                          style: text.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: _expandDuration,
                      curve: _expandCurve,
                      child: Icon(
                        Icons.expand_more,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: _expandDuration,
            curve: _expandCurve,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 2),
                    child: Column(
                      children: [
                        for (final episode in episodes)
                          _EpisodeRow(
                            controller: widget.controller,
                            episode: episode,
                          ),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({required this.controller, required this.episode});

  final LibraryController controller;
  final LibraryEpisode episode;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Observer(
      builder: (context) {
        final local = controller.observedLocal(episode);
        final watched = controller.isWatchedByMe(episode);
        final (icon, label, progress) = _status(local);
        final watchers = episode.watchedBy;

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Opacity(
            opacity: watched ? 0.55 : 1,
            child: Material(
              color: colors.surfaceContainer,
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => controller.openEpisode(context, episode),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: colors.secondaryContainer,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          '${episode.manifest.episodeNumber}',
                          style: text.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: colors.onSecondaryContainer,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              episode.manifest.displayEpisodeName,
                              style: text.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(icon, size: 14, color: colors.primary),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    watchers.isEmpty
                                        ? label
                                        : '$label · ${watchers.join('、')} 看过',
                                    overflow: TextOverflow.ellipsis,
                                    style: text.bodySmall?.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (progress != null) ...[
                              const SizedBox(height: 6),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: progress,
                                  minHeight: 4,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.play_circle_fill_rounded,
                        size: 32,
                        color: colors.primary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  (IconData, String, double?) _status(DownloadEpisode? local) {
    if (local == null || !local.preUpscaled) {
      return (Icons.cloud_outlined, '在线播放', null);
    }
    switch (local.status) {
      case DownloadStatus.completed:
        return (Icons.offline_pin_rounded, '已下载', null);
      case DownloadStatus.downloading:
        final percent = (local.progressPercent * 100).toStringAsFixed(0);
        return (
          Icons.downloading_rounded,
          '下载中 $percent%',
          local.progressPercent,
        );
      case DownloadStatus.paused:
        return (Icons.pause_circle_outline_rounded, '下载已暂停', null);
      case DownloadStatus.failed:
        return (Icons.error_outline_rounded, '下载失败，将在线播放', null);
      default:
        return (Icons.schedule_rounded, '排队下载', null);
    }
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(Icons.movie_filter_outlined, size: 56, color: colors.outline),
          const SizedBox(height: 12),
          Text(
            '片库还是空的\n电脑上烘焙好的剧集上传后会出现在这里',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, this.isError = false});

  final IconData icon;
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isError ? colors.errorContainer : colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: isError ? colors.onErrorContainer : colors.onSurface,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: isError ? colors.onErrorContainer : colors.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Entrance extends StatelessWidget {
  const _Entrance({super.key, required this.child, this.delay = Duration.zero});

  final Widget child;
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) return child;
    final total = const Duration(milliseconds: 420) + delay;
    final start = delay.inMilliseconds / total.inMilliseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: Interval(start, 1, curve: Curves.easeOutCubic),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 24 * (1 - t)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

class _GlowingHeart extends StatefulWidget {
  const _GlowingHeart({required this.size});

  final double size;

  @override
  State<_GlowingHeart> createState() => _GlowingHeartState();
}

class _GlowingHeartState extends State<_GlowingHeart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _beat = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _beat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (MediaQuery.of(context).disableAnimations) {
      return Icon(
        Icons.favorite_rounded,
        size: widget.size,
        color: colors.primary,
      );
    }
    return AnimatedBuilder(
      animation: _beat,
      builder: (context, _) {
        // Two quick beats, then a rest, like a heartbeat.
        final t = _beat.value;
        final pulse = t < 0.15
            ? Curves.easeOut.transform(t / 0.15)
            : t < 0.3
            ? 1 - Curves.easeIn.transform((t - 0.15) / 0.15) * 0.6
            : t < 0.45
            ? 0.4 + Curves.easeOut.transform((t - 0.3) / 0.15) * 0.6
            : 1 - Curves.easeInOut.transform((t - 0.45) / 0.55);
        return Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: colors.primary.withValues(alpha: 0.35 * pulse),
                blurRadius: widget.size * 0.6 * pulse,
                spreadRadius: widget.size * 0.05 * pulse,
              ),
            ],
          ),
          child: Transform.scale(
            scale: 1 + 0.08 * pulse,
            child: Icon(
              Icons.favorite_rounded,
              size: widget.size,
              color: colors.primary,
            ),
          ),
        );
      },
    );
  }
}

class _PulseDot extends StatefulWidget {
  const _PulseDot({required this.color});

  final Color color;

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final border = Theme.of(context).colorScheme.surface;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) => Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
          border: Border.all(color: border, width: 2),
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(alpha: 0.6 * (1 - _pulse.value)),
              blurRadius: 2,
              spreadRadius: 6 * _pulse.value,
            ),
          ],
        ),
      ),
    );
  }
}

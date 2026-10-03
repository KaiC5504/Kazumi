import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/services/platform/secure_bookmark_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/upscale/lan_share.dart';
import 'package:kazumi/services/upscale/upscale_controller.dart';
import 'package:kazumi/utils/file_system.dart';

class DownloadSettingsPage extends StatefulWidget {
  const DownloadSettingsPage({super.key});

  @override
  State<DownloadSettingsPage> createState() => _DownloadSettingsPageState();
}

class _DownloadSettingsPageState extends State<DownloadSettingsPage> {
  late int parallelEpisodes;
  late int parallelSegments;
  late bool downloadDanmaku;
  String downloadDirectory = '';
  String defaultDownloadDirectory = '';
  bool isSelectingDirectory = false;

  final UpscaleController upscaleController = inject<UpscaleController>();
  String ffmpegStatus = '';
  bool detectingFfmpeg = false;
  late int bakeHeight;
  late String exportDirectory;
  late bool autoExport;
  late bool libraryAutoUpload;
  List<String> lanAddresses = [];

  @override
  void initState() {
    super.initState();
    bakeHeight = GStorage.getSetting(SettingsKeys.upscaleBakeHeight);
    exportDirectory = GStorage.getSetting(SettingsKeys.upscaleExportDirectory);
    autoExport = GStorage.getSetting(SettingsKeys.upscaleAutoExport);
    libraryAutoUpload = GStorage.getSetting(SettingsKeys.libraryAutoUpload);
    if (upscaleController.canBake) {
      _detectFfmpeg();
      _loadLanAddresses();
    }
    parallelEpisodes =
        GStorage.getSetting(SettingsKeys.downloadParallelEpisodes);
    parallelSegments =
        GStorage.getSetting(SettingsKeys.downloadParallelSegments);
    downloadDanmaku = GStorage.getSetting(SettingsKeys.downloadDanmaku);
    downloadDirectory =
        GStorage.getSetting(SettingsKeys.downloadDirectory).trim();
    _loadDefaultDownloadDirectory();
  }

  bool get _canPickDirectory => supportsCustomDownloadDirectory;

  bool get _hasCustomDirectory =>
      _canPickDirectory && downloadDirectory.isNotEmpty;

  String get _effectiveDownloadDirectory =>
      _hasCustomDirectory ? downloadDirectory : defaultDownloadDirectory;

  Future<void> _loadDefaultDownloadDirectory() async {
    final directory = await getDefaultDownloadDirectory();
    if (!mounted) return;
    setState(() {
      defaultDownloadDirectory = directory;
    });
  }

  Future<void> _selectDownloadDirectory() async {
    if (!_canPickDirectory) {
      KazumiDialog.showToast(message: '当前平台不支持手动选择目录');
      return;
    }
    if (isSelectingDirectory) return;

    setState(() => isSelectingDirectory = true);
    try {
      final effectiveDirectory = _effectiveDownloadDirectory;
      final initialDirectory = effectiveDirectory.isNotEmpty &&
              await Directory(effectiveDirectory).exists()
          ? effectiveDirectory
          : null;
      final selectedPath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择下载位置',
        initialDirectory: initialDirectory,
      );
      if (selectedPath == null || selectedPath.isEmpty) return;

      await ensureDirectoryWritable(selectedPath);
      if (!await SecureBookmarkService.persist(selectedPath)) {
        KazumiDialog.showToast(message: '无法获得该目录的持久访问权限，请更换目录');
        return;
      }
      await GStorage.putSetting(
        SettingsKeys.downloadDirectory,
        selectedPath,
      );
      if (mounted) {
        setState(() => downloadDirectory = selectedPath);
      }
      KazumiDialog.showToast(message: '下载位置已更新，仅对新下载生效');
    } on FileSystemException catch (e) {
      KazumiDialog.showToast(message: '无法写入该目录: ${e.message}');
    } catch (e) {
      KazumiDialog.showToast(message: '选择下载位置失败: $e');
    } finally {
      if (mounted) {
        setState(() => isSelectingDirectory = false);
      }
    }
  }

  Future<void> _detectFfmpeg() async {
    setState(() => detectingFfmpeg = true);
    final (info, error) = await upscaleController.detectFfmpeg();
    if (!mounted) return;
    setState(() {
      detectingFfmpeg = false;
      ffmpegStatus = info == null
          ? (error ?? '未找到可用的 ffmpeg')
          : '${info.version}\n编码器: ${info.hardwareEncoder ? 'NVIDIA NVENC (快)' : 'libx265 (CPU, 较慢)'}';
    });
  }

  Future<void> _editFfmpegPath() async {
    final controller = TextEditingController(
        text: GStorage.getSetting(SettingsKeys.upscaleFfmpegPath));
    final result = await KazumiDialog.show<String>(
      builder: (context) => AlertDialog(
        title: const Text('ffmpeg 路径'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: r'例如 D:\Tools\ffmpeg\bin\ffmpeg.exe，留空则使用 PATH',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => KazumiDialog.dismiss(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => KazumiDialog.dismiss(popWith: controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    await GStorage.putSetting<String>(
        SettingsKeys.upscaleFfmpegPath, result.trim());
    await _detectFfmpeg();
  }

  Future<void> _selectExportDirectory() async {
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择导出位置 (建议选 iCloud Drive 或 OneDrive 文件夹)',
    );
    if (selected == null || selected.isEmpty) return;
    await GStorage.putSetting<String>(
        SettingsKeys.upscaleExportDirectory, selected);
    if (mounted) setState(() => exportDirectory = selected);
  }

  Future<void> _editLibrarySetting(
    SettingKey<String> key, {
    required String title,
    required String hint,
  }) async {
    final controller = TextEditingController(text: GStorage.getSetting(key));
    final result = await KazumiDialog.show<String>(
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: hint,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => KazumiDialog.dismiss(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => KazumiDialog.dismiss(popWith: controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    await GStorage.putSetting<String>(key, result.trim());
    if (mounted) setState(() {});
  }

  Future<void> _loadLanAddresses() async {
    try {
      final addresses = await LanShareServer.localAddresses();
      if (mounted) setState(() => lanAddresses = addresses);
    } catch (_) {}
  }

  Future<void> _toggleLanShare(bool enable) async {
    try {
      if (enable) {
        await upscaleController.startLanShare();
      } else {
        await upscaleController.stopLanShare();
      }
      await GStorage.putSetting<bool>(SettingsKeys.lanShareEnabled, enable);
    } catch (e) {
      KazumiDialog.showToast(message: '无法开启局域网共享: $e');
    }
  }

  Future<void> _resetDownloadDirectory() async {
    await SecureBookmarkService.clear();
    await GStorage.putSetting(SettingsKeys.downloadDirectory, '');
    if (mounted) {
      setState(() => downloadDirectory = '');
    }
    KazumiDialog.showToast(message: '已恢复默认下载位置，仅对新下载生效');
  }

  List<SettingsSection> _upscaleSections(BuildContext context) {
    final hintStyle =
        TextStyle(color: Theme.of(context).textTheme.bodySmall?.color);
    return [
      SettingsSection(
        title: Text('超分烘焙 (将质量档超分写入视频，供 iPad 等设备直接播放)'),
        tiles: [
          SettingsTile(
            leading: Icons.movie_filter_rounded,
            title: Text('ffmpeg'),
            description: Text(detectingFfmpeg ? '正在检测...' : ffmpegStatus),
            trailing: IconButton(
              tooltip: '重新检测',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: detectingFfmpeg ? null : _detectFfmpeg,
            ),
            onPressed: (_) => _editFfmpegPath(),
          ),
          SettingsTile(
            leading: Icons.high_quality_rounded,
            title: Text('输出分辨率'),
            description: Text(bakeHeight >= 2160
                ? '2160p · 画质更细，每集约 1-2 GB'
                : '1440p · 接近 iPad 屏幕分辨率，每集约 0.5-1 GB'),
            trailing: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1440, label: Text('1440p')),
                ButtonSegment(value: 2160, label: Text('2160p')),
              ],
              selected: {bakeHeight},
              showSelectedIcon: false,
              onSelectionChanged: (value) {
                setState(() => bakeHeight = value.first);
                GStorage.putSetting<int>(
                    SettingsKeys.upscaleBakeHeight, bakeHeight);
              },
            ),
          ),
          SettingsTile(
            leading: Icons.drive_folder_upload_rounded,
            title: Text('导出位置'),
            description: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(exportDirectory.isEmpty ? '未设置' : exportDirectory),
                const SizedBox(height: 8),
                Text(
                  '选 iCloud Drive / OneDrive 同步文件夹，iPad 关机状态下也能从「文件」导入',
                  style: hintStyle,
                ),
              ],
            ),
            onPressed: (_) => _selectExportDirectory(),
          ),
          SettingsTile.switchTile(
            leading: Icons.sync_rounded,
            title: Text('烘焙后自动导出'),
            description: Text('烘焙完成后自动复制到导出位置'),
            initialValue: autoExport,
            onToggle: (value) {
              setState(() => autoExport = value ?? !autoExport);
              GStorage.putSetting<bool>(
                  SettingsKeys.upscaleAutoExport, autoExport);
            },
          ),
        ],
      ),
      SettingsSection(
        title: Text('局域网共享'),
        tiles: [
          SettingsTile(
            leading: Icons.wifi_tethering_rounded,
            title: Text('共享已烘焙的剧集'),
            description: Observer(builder: (context) {
              if (!upscaleController.lanShareRunning.value) {
                return Text('开启后，同一 Wi-Fi 下的 iPad 可在下载管理中点击 Wi-Fi 图标拉取');
              }
              final address = lanAddresses.isEmpty
                  ? '无法获取本机 IP'
                  : lanAddresses.join(' / ');
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('电脑地址: $address'),
                  Text('连接码: ${upscaleController.lanShareToken()}'),
                  const SizedBox(height: 8),
                  Text('首次开启时 Windows 会询问防火墙，请允许「专用网络」',
                      style: hintStyle),
                ],
              );
            }),
            trailing: Observer(
              builder: (context) => Switch(
                value: upscaleController.lanShareRunning.value,
                onChanged: _toggleLanShare,
              ),
            ),
            onPressed: (_) => Clipboard.setData(ClipboardData(
              text: lanAddresses.isEmpty ? '' : lanAddresses.first,
            )),
          ),
        ],
      ),
      SettingsSection(
        title: Text('一起看片库 (上传到服务器，异地一起看)'),
        tiles: [
          SettingsTile(
            leading: Icons.dns_rounded,
            title: Text('片库服务器'),
            description: Text(_orUnset(
                GStorage.getSetting(SettingsKeys.libraryServer))),
            onPressed: (_) => _editLibrarySetting(
              SettingsKeys.libraryServer,
              title: '片库服务器',
              hint: '例如 https://kazumi.example.com',
            ),
          ),
          SettingsTile(
            leading: Icons.key_rounded,
            title: Text('上传密钥'),
            description: Text(
                GStorage.getSetting(SettingsKeys.libraryAdminKey).isEmpty
                    ? '未设置'
                    : '已设置'),
            onPressed: (_) => _editLibrarySetting(
              SettingsKeys.libraryAdminKey,
              title: '上传密钥',
              hint: '服务器的管理密钥',
            ),
          ),
          SettingsTile.switchTile(
            leading: Icons.cloud_upload_rounded,
            title: Text('烘焙后自动上传'),
            description: Text('烘焙完成后自动上传到片库，断线会自动续传'),
            initialValue: libraryAutoUpload,
            onToggle: (value) {
              setState(() => libraryAutoUpload = value ?? !libraryAutoUpload);
              GStorage.putSetting<bool>(
                  SettingsKeys.libraryAutoUpload, libraryAutoUpload);
            },
          ),
        ],
      ),
    ];
  }

  static String _orUnset(String value) => value.isEmpty ? '未设置' : value;

  @override
  Widget build(BuildContext context) {
    return SettingsDetailScaffold(
      title: const Text('下载设置'),
      body: SettingsList(
        sections: [
          SettingsSection(
            title: Text('并发设置'),
            tiles: [
              SettingsSliderTile(
                leading: Icons.video_library_rounded,
                title: Text('同时下载集数'),
                description: Text('并行下载的剧集数量'),
                value: parallelEpisodes.toDouble(),
                min: 1,
                max: 5,
                divisions: 4,
                valueLabel: '$parallelEpisodes 集',
                onChanged: (value) {
                  setState(() => parallelEpisodes = value.toInt());
                  GStorage.putSetting(
                    SettingsKeys.downloadParallelEpisodes,
                    parallelEpisodes,
                  );
                },
              ),
              SettingsSliderTile(
                leading: Icons.call_split_rounded,
                title: Text('分片并发数'),
                description: Text('每集同时下载的分片数量'),
                value: parallelSegments.toDouble(),
                min: 1,
                max: 10,
                divisions: 9,
                valueLabel: '$parallelSegments 个',
                onChanged: (value) {
                  setState(() => parallelSegments = value.toInt());
                  GStorage.putSetting(
                    SettingsKeys.downloadParallelSegments,
                    parallelSegments,
                  );
                },
              ),
            ],
          ),
          SettingsSection(
            title: Text('缓存设置'),
            tiles: [
              SettingsTile(
                leading: Icons.folder_rounded,
                title: Text('下载位置'),
                description: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _effectiveDownloadDirectory.isEmpty
                          ? '正在读取默认位置...'
                          : _effectiveDownloadDirectory,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _hasCustomDirectory
                          ? '当前使用自定义下载位置，修改后仅对新下载生效'
                          : '当前使用默认下载位置，修改后仅对新下载生效',
                      style: TextStyle(
                        color: Theme.of(context).textTheme.bodySmall?.color,
                      ),
                    ),
                  ],
                ),
                trailing: isSelectingDirectory
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: LoadingIndicator(),
                      )
                    : _hasCustomDirectory
                        ? IconButton(
                            tooltip: '恢复默认',
                            icon: const Icon(Icons.restore_rounded),
                            onPressed: _resetDownloadDirectory,
                          )
                        : null,
                onPressed: (_) => _selectDownloadDirectory(),
              ),
              SettingsTile.switchTile(
                leading: Icons.subtitles_rounded,
                onToggle: (value) {
                  setState(() => downloadDanmaku = value ?? !downloadDanmaku);
                  GStorage.putSetting(
                      SettingsKeys.downloadDanmaku, downloadDanmaku);
                },
                title: Text('缓存弹幕'),
                description: Text(
                  '下载视频时同时缓存弹幕数据',
                ),
                initialValue: downloadDanmaku,
              ),
            ],
          ),
          if (upscaleController.canBake) ..._upscaleSections(context),
          SettingsSection(
            title: Text('说明'),
            tiles: [
              SettingsTile(
                leading: Icons.info_outline_rounded,
                title: Text('关于并发设置'),
                description: Text(
                  '• 集数并发：同时下载多少集视频\n'
                  '• 分片并发：每集内同时下载多少个视频片段\n'
                  '• 较高的并发可提升速度，但可能被服务器限制\n'
                  '• 修改后对新开始的下载生效',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

import 'dart:convert';

import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/services/skip/skip_segments.dart';

const String upscaledManifestFileName = 'kazumi_episode.json';
const String upscaledVideoFileName = 'video.mp4';
const String upscaledDanmakuFileName = 'danmaku.json';
const String upscaledExportFolderName = 'Kazumi Upscaled';
const String lanShareTokenHeader = 'X-Kazumi-Token';
const int lanSharePort = 38520;

/// Describes one baked episode so another Kazumi install can rebuild its
/// download record without access to the original plugin or source.
class UpscaledEpisodeManifest {
  static const int currentVersion = 1;

  final int version;
  final int bangumiId;
  final String pluginName;
  final String bangumiName;
  final String bangumiCover;
  final int episodeNumber;
  final String episodeName;
  final int road;
  final String episodePageUrl;
  final int danDanBangumiID;
  final String tier;
  final int width;
  final int height;
  final int sizeBytes;
  final bool hasDanmaku;

  /// Optional, so manifests stay at version 1 and older builds still import.
  final SkipSegments skipSegments;

  const UpscaledEpisodeManifest({
    this.version = currentVersion,
    required this.bangumiId,
    required this.pluginName,
    required this.bangumiName,
    required this.bangumiCover,
    required this.episodeNumber,
    required this.episodeName,
    required this.road,
    required this.episodePageUrl,
    required this.danDanBangumiID,
    required this.tier,
    required this.width,
    required this.height,
    required this.sizeBytes,
    required this.hasDanmaku,
    this.skipSegments = SkipSegments.empty,
  });

  factory UpscaledEpisodeManifest.fromEpisode(
    DownloadRecord record,
    DownloadEpisode episode, {
    required int width,
    required int height,
    required int sizeBytes,
    required bool hasDanmaku,
  }) {
    return UpscaledEpisodeManifest(
      bangumiId: record.bangumiId,
      pluginName: record.pluginName,
      bangumiName: record.bangumiName,
      bangumiCover: record.bangumiCover,
      episodeNumber: episode.episodeNumber,
      episodeName: episode.episodeName,
      road: episode.road,
      episodePageUrl: episode.episodePageUrl,
      danDanBangumiID: episode.danDanBangumiID,
      tier: 'quality',
      width: width,
      height: height,
      sizeBytes: sizeBytes,
      hasDanmaku: hasDanmaku,
      skipSegments: SkipSegments.decode(episode.skipSegments),
    );
  }

  factory UpscaledEpisodeManifest.fromJson(Map<String, dynamic> json) {
    final version = json['version'] as int? ?? 0;
    if (version < 1 || version > currentVersion) {
      throw FormatException('不支持的超分剧集版本: $version');
    }
    return UpscaledEpisodeManifest(
      version: version,
      bangumiId: json['bangumiId'] as int,
      pluginName: json['pluginName'] as String,
      bangumiName: json['bangumiName'] as String? ?? '',
      bangumiCover: json['bangumiCover'] as String? ?? '',
      episodeNumber: json['episodeNumber'] as int,
      episodeName: json['episodeName'] as String? ?? '',
      road: json['road'] as int? ?? 0,
      episodePageUrl: json['episodePageUrl'] as String? ?? '',
      danDanBangumiID: json['danDanBangumiID'] as int? ?? 0,
      tier: json['tier'] as String? ?? 'quality',
      width: json['width'] as int? ?? 0,
      height: json['height'] as int? ?? 0,
      sizeBytes: json['sizeBytes'] as int? ?? 0,
      hasDanmaku: json['hasDanmaku'] as bool? ?? false,
      skipSegments: json['skip'] is Map
          ? SkipSegments.fromJson((json['skip'] as Map).cast<String, dynamic>())
          : SkipSegments.empty,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'bangumiId': bangumiId,
    'pluginName': pluginName,
    'bangumiName': bangumiName,
    'bangumiCover': bangumiCover,
    'episodeNumber': episodeNumber,
    'episodeName': episodeName,
    'road': road,
    'episodePageUrl': episodePageUrl,
    'danDanBangumiID': danDanBangumiID,
    'tier': tier,
    'width': width,
    'height': height,
    'sizeBytes': sizeBytes,
    'hasDanmaku': hasDanmaku,
    if (!skipSegments.isEmpty) 'skip': skipSegments.toJson(),
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  static UpscaledEpisodeManifest decode(String source) =>
      UpscaledEpisodeManifest.fromJson(
        jsonDecode(source) as Map<String, dynamic>,
      );

  String get recordKey => '${pluginName}_$bangumiId';

  /// Stable id used in LAN share URLs.
  String get shareId => base64Url
      .encode(utf8.encode('$recordKey|$episodeNumber'))
      .replaceAll('=', '');

  String get displayEpisodeName =>
      episodeName.isNotEmpty ? episodeName : '第$episodeNumber集';

  /// Builds the record and episode an importing device stores. The caller
  /// fills in paths and status.
  (DownloadRecord, DownloadEpisode) toDownloadEntities() {
    final record = DownloadRecord(
      bangumiId,
      bangumiName,
      bangumiCover,
      pluginName,
      {},
      DateTime.now(),
    );
    final episode = DownloadEpisode(
      episodeNumber,
      episodeName,
      road,
      DownloadStatus.pending,
      0.0,
      1,
      0,
      '',
      '',
      '',
      null,
      '',
      0,
      episodePageUrl,
      danDanBangumiID: danDanBangumiID,
      preUpscaled: true,
      skipSegments: skipSegments.encode(),
    );
    return (record, episode);
  }
}

/// Folder-safe name for an exported episode.
String upscaledExportDirName(UpscaledEpisodeManifest manifest) {
  final raw = '${manifest.bangumiName} - 第${manifest.episodeNumber}集';
  return raw.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
}

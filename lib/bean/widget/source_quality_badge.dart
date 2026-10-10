import 'package:flutter/material.dart';
import 'package:kazumi/plugins/plugins.dart';

enum SourceAvailability { measured, blocked, unknown }

class SourceQuality {
  const SourceQuality({
    required this.height,
    required this.video,
    required this.audio,
    required this.detail,
    this.road,
  }) : availability = SourceAvailability.measured;

  const SourceQuality.blocked(this.detail)
    : availability = SourceAvailability.blocked,
      height = 0,
      video = 0,
      audio = 0,
      road = null;

  const SourceQuality.unknown(this.detail)
    : availability = SourceAvailability.unknown,
      height = 0,
      video = 0,
      audio = 0,
      road = null;

  final SourceAvailability availability;
  final int height;

  /// 1–3, picture detail with bitrate weighed by codec (HEVC counts ~1.5x).
  final int video;

  /// 1–3: 3 is full-range ~200 kbps AAC, 2 a dull re-encode, 1 muffled 64 kbps.
  final int audio;

  /// The only road that played, when the others are dead or geo-blocked.
  final int? road;
  final String detail;
}

// Measured 2026-10-09/10 on 葬送的芙莉莲 ep 1 from the owner's PC (Australia):
// 30 s clip at 7:00, ffprobe for codec/bitrate, FFT for the audio lowpass.
// "blocked" CDNs (ffzy, yzzy, lz, dytt) answer 403 outside mainland China.
const _measured = <String, SourceQuality>{
  'xfdmnext': SourceQuality(
    height: 1080,
    video: 3,
    audio: 3,
    detail: '1080p HEVC 2.1 Mbps · 音频 194 kbps',
  ),
  'xfdmneo': SourceQuality(
    height: 1080,
    video: 3,
    audio: 3,
    detail: '1080p HEVC 2.1 Mbps · 音频 194 kbps',
  ),
  '欧乐影院': SourceQuality(
    height: 1080,
    video: 3,
    audio: 3,
    detail: '1080p H.264 3.1 Mbps · 音频 225 kbps',
  ),
  'moonci': SourceQuality(
    height: 1080,
    video: 3,
    audio: 3,
    detail: '1080p HEVC 2.1 Mbps · 音频 194 kbps（线路 2）',
  ),
  'aafun': SourceQuality(
    height: 1080,
    video: 3,
    audio: 3,
    detail: '1080p HEVC 2.1 Mbps · 音频 194 kbps（线路 2）',
  ),
  'dmghg1': SourceQuality(
    height: 1080,
    video: 3,
    audio: 3,
    road: 4,
    detail: '1080p H.264 3.7 Mbps · 音频 268 kbps · 仅线路 4 可用',
  ),
  '7sefun': SourceQuality(
    height: 1080,
    video: 3,
    audio: 2,
    detail: '1080p H.264 3.3 Mbps · 音频 137 kbps，高频截止 15.6 kHz',
  ),
  'dm84': SourceQuality(
    height: 1080,
    video: 3,
    audio: 2,
    detail: '1080p H.264 3.2 Mbps · 音频 130 kbps，高频截止 15.6 kHz',
  ),
  'milimili': SourceQuality(
    height: 1080,
    video: 3,
    audio: 2,
    detail: '与 DM84 同源（推断）',
  ),
  'lmm': SourceQuality(
    height: 1080,
    video: 3,
    audio: 2,
    detail: '1080p H.264 3.5 Mbps · 音频 149 kbps，高频截止 15.6 kHz',
  ),
  'girigirilove': SourceQuality(
    height: 1080,
    video: 2,
    audio: 3,
    detail: '1080p H.264 1.2 Mbps · 音频 211 kbps',
  ),
  'mutefun': SourceQuality(
    height: 1080,
    video: 2,
    audio: 2,
    detail: '1080p H.264 2.2 Mbps · 音频 132 kbps，高频截止 18 kHz',
  ),
  'cyfz': SourceQuality(
    height: 1080,
    video: 2,
    audio: 2,
    detail: '1080p H.264 1.2 Mbps · 音频 128 kbps，高频截止 18 kHz',
  ),
  'sorani': SourceQuality(
    height: 1080,
    video: 2,
    audio: 2,
    detail: '1080p H.264 1.3 Mbps · 音频 131 kbps',
  ),
  'mxdm': SourceQuality(
    height: 1080,
    video: 2,
    audio: 1,
    road: 2,
    detail: '1080p H.264 1.7 Mbps · 音频 64 kbps · 仅线路 2 可用',
  ),
  'tsdm': SourceQuality(
    height: 1080,
    video: 2,
    audio: 2,
    detail: '1080p H.264 1.1 Mbps · 音频 132 kbps',
  ),
  'age': SourceQuality(
    height: 1080,
    video: 1,
    audio: 2,
    road: 4,
    detail: '1080p H.264 0.9 Mbps · 音频 129 kbps · 仅线路 4 可用',
  ),
  '淘片动漫': SourceQuality(
    height: 720,
    video: 1,
    audio: 1,
    detail: '720p H.264 1.0 Mbps · 音频 64 kbps',
  ),
  'baimao': SourceQuality.blocked('视频服务器拒绝访问（403）'),
  'blbl': SourceQuality.blocked('视频服务器拒绝访问（403）'),
  'lblb': SourceQuality.blocked('视频服务器拒绝访问（403）'),
  'akianime': SourceQuality.blocked('线路失效或加密'),
  '蘑菇网影视': SourceQuality.blocked('仅爱奇艺解析链接'),
  'qkan9': SourceQuality.blocked('Cloudflare 拦截'),
  'mgnacg': SourceQuality.blocked('本地线路已下线，其余线路加载失败'),
  'dalvdm': SourceQuality.blocked('Cloudflare 拦截'),
  'ee': SourceQuality.unknown('未能获取视频，未测'),
  'ezdmw': SourceQuality.unknown('未能获取视频，未测'),
};

SourceQuality? sourceQualityFor(String pluginName) =>
    _measured[pluginNameKey(pluginName)];

/// Best measured sources first (resolution, then video, then audio), then the
/// untested ones, blocked last. Ties keep their current order.
List<T> sortByQuality<T>(List<T> items, String Function(T) nameOf) {
  int tier(SourceQuality? q) => switch (q?.availability) {
    SourceAvailability.measured => 0,
    SourceAvailability.blocked => 2,
    _ => 1,
  };
  final indexed = items.indexed.toList();
  indexed.sort((a, b) {
    final qa = sourceQualityFor(nameOf(a.$2));
    final qb = sourceQualityFor(nameOf(b.$2));
    var c = tier(qa).compareTo(tier(qb));
    if (c == 0 && qa != null && qb != null) {
      c = qb.height.compareTo(qa.height);
      if (c == 0) c = qb.video.compareTo(qa.video);
      if (c == 0) c = qb.audio.compareTo(qa.audio);
    }
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final (_, item) in indexed) item];
}

/// Language-free quality glance: resolution, video bars, audio bars, road.
class SourceQualityBadge extends StatelessWidget {
  const SourceQualityBadge({super.key, required this.pluginName});

  final String pluginName;

  @override
  Widget build(BuildContext context) {
    final quality = sourceQualityFor(pluginName);
    if (quality == null) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final palette = _QualityPalette.of(context);

    final Widget content = switch (quality.availability) {
      SourceAvailability.blocked => Icon(
        Icons.block_rounded,
        size: 16,
        color: palette.poor,
      ),
      SourceAvailability.unknown => Icon(
        Icons.help_outline_rounded,
        size: 16,
        color: colors.onSurfaceVariant.withValues(alpha: 0.7),
      ),
      SourceAvailability.measured => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ResolutionChip(height: quality.height, palette: palette),
          const SizedBox(width: 8),
          Icon(Icons.movie_rounded, size: 14, color: colors.onSurfaceVariant),
          const SizedBox(width: 3),
          _LevelBars(level: quality.video, palette: palette),
          const SizedBox(width: 8),
          Icon(
            Icons.volume_up_rounded,
            size: 14,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(width: 3),
          _LevelBars(level: quality.audio, palette: palette),
          if (quality.road != null) ...[
            const SizedBox(width: 8),
            Icon(
              Icons.alt_route_rounded,
              size: 14,
              color: colors.onSurfaceVariant,
            ),
            Text(
              '${quality.road}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    };

    return Tooltip(
      message: quality.detail,
      triggerMode: TooltipTriggerMode.longPress,
      child: Semantics(label: quality.detail, child: content),
    );
  }
}

class _QualityPalette {
  const _QualityPalette(this.good, this.fair, this.poor);

  final Color good;
  final Color fair;
  final Color poor;

  static _QualityPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const _QualityPalette(
          Color(0xFF6DD58C),
          Color(0xFFF2C14E),
          Color(0xFFFF8A80),
        )
      : const _QualityPalette(
          Color(0xFF1E8E3E),
          Color(0xFFB06000),
          Color(0xFFC5221F),
        );

  Color forLevel(int level) => switch (level) {
    >= 3 => good,
    2 => fair,
    _ => poor,
  };
}

class _ResolutionChip extends StatelessWidget {
  const _ResolutionChip({required this.height, required this.palette});

  final int height;
  final _QualityPalette palette;

  @override
  Widget build(BuildContext context) {
    final color = palette.forLevel(height >= 1080 ? 3 : 1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        '${height}p',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w800,
          height: 1.2,
        ),
      ),
    );
  }
}

class _LevelBars extends StatelessWidget {
  const _LevelBars({required this.level, required this.palette});

  final int level;
  final _QualityPalette palette;

  @override
  Widget build(BuildContext context) {
    final fill = palette.forLevel(level);
    final empty = Theme.of(
      context,
    ).colorScheme.onSurfaceVariant.withValues(alpha: 0.22);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < 3; i++)
          Container(
            width: 4,
            height: 6.0 + i * 4,
            margin: EdgeInsets.only(left: i == 0 ? 0 : 2),
            decoration: BoxDecoration(
              color: i < level ? fill : empty,
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
      ],
    );
  }
}

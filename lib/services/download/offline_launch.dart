import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';

class LocalSource {
  LocalSource(this.record, this.completed);

  final DownloadRecord record;
  final List<DownloadEpisode> completed;

  bool get preUpscaled => completed.any((e) => e.preUpscaled);
}

/// Resumes the last watched episode if it is downloaded, else the lowest one.
int pickStartEpisode(List<DownloadEpisode> completed, int? lastWatchedEpisode) {
  final numbers = completed.map((e) => e.episodeNumber).toList()..sort();
  if (lastWatchedEpisode != null && numbers.contains(lastWatchedEpisode)) {
    return lastWatchedEpisode;
  }
  return numbers.first;
}

OfflineVideoPlaybackArgs buildOfflineArgs({
  required DownloadRecord record,
  required int episodeNumber,
  required int road,
  required List<DownloadEpisode> completed,
}) {
  final bangumiItem = BangumiItem(
    id: record.bangumiId,
    type: 2,
    name: record.bangumiName,
    nameCn: record.bangumiName,
    summary: '',
    airDate: '',
    airWeekday: 0,
    rank: 0,
    images: {'large': record.bangumiCover},
    tags: [],
    alias: [],
    ratingScore: 0.0,
    votes: 0,
    votesCount: [],
    info: '',
  );
  return OfflineVideoPlaybackArgs(
    bangumiItem: bangumiItem,
    pluginName: record.pluginName,
    episodeNumber: episodeNumber,
    road: road,
    downloadedEpisodes: completed,
  );
}

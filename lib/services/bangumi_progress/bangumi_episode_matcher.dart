import 'package:kazumi/modules/bangumi/episode_item.dart';

/// Sources number a second season 1..12 while Bangumi's `sort` continues
/// from the first season; `ep` is the in-season number, so try it first.
int? matchBangumiEpisodeId(List<EpisodeInfo> episodes, int localNumber) {
  final mains = episodes.where((e) => e.type == 0).toList();
  for (final e in mains) {
    if (e.ep == localNumber) return e.id;
  }
  for (final e in mains) {
    if (e.episode == localNumber) return e.id;
  }
  return null;
}

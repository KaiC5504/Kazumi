import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/player/danmaku_source_kind.dart';
import 'package:kazumi/services/player/audio_delay.dart';
import 'package:kazumi/services/player/danmaku_binding_store.dart';
import 'package:kazumi/services/player/episode_order_store.dart';
import 'package:kazumi/services/storage/storage.dart';

import 'support/syncplay_sim.dart' show setUpSyncplayStorage;

// With nothing picked, flipped or adjusted, her app behaves as before.
void main() {
  setUpSyncplayStorage();

  test('no remembered match: the automatic lookup runs', () {
    expect(DanmakuBindingStore.bindingFor(42), isNull);
  });

  test('nothing flipped: ±1 navigation and today\'s room follow', () {
    expect(EpisodeOrderStore.isReversed(42, 'AGE'), isFalse);
    final dir = EpisodeOrder.nextDirection(
      flipped: false,
      inRoom: false,
      titles: () => TitleOrder.descending,
    );
    expect(dir, 1);
    for (var p = 1; p <= 12; p++) {
      final e = EpisodeOrder.endOfEpisode(
        position: p,
        length: 12,
        direction: dir,
        followEpisode: p + 1,
      );
      expect(e.next, p < 12 ? p + 1 : null);
      expect(e.roomWantsNext, isTrue);
    }
  });

  test('a flip never changes a 一起看 room', () {
    expect(
      EpisodeOrder.nextDirection(
        flipped: true,
        inRoom: true,
        titles: () => TitleOrder.descending,
      ),
      1,
    );
  });

  test('audio delay starts at zero, so init sets nothing', () {
    expect(GStorage.getSetting(audioDelaySetting), 0);
  });

  test('all danmaku sources start on', () {
    expect(DanmakuSourceKind.enabledNow().values, everyElement(isTrue));
  });
}

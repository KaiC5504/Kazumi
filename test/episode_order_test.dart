import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/episode_order_store.dart';
import 'package:kazumi/services/storage/storage.dart';

import 'support/syncplay_sim.dart' show setUpSyncplayStorage;

void main() {
  setUpSyncplayStorage();

  setUp(() async {
    await GStorage.putSetting<String>(EpisodeOrderStore.setting, '[]');
  });

  group('titleOrder', () {
    test('ascending', () {
      expect(
        EpisodeOrder.titleOrder(['第1集', '第2集', '第12集']),
        TitleOrder.ascending,
      );
    });
    test('descending (DM84 style)', () {
      expect(
        EpisodeOrder.titleOrder(['第12集', '第11集', '第1集']),
        TitleOrder.descending,
      );
    });
    test('unknown without numbers or with one item', () {
      expect(EpisodeOrder.titleOrder(['正片', '特别篇']), TitleOrder.unknown);
      expect(EpisodeOrder.titleOrder(['第1集']), TitleOrder.unknown);
      expect(EpisodeOrder.titleOrder(const []), TitleOrder.unknown);
    });
    test('skips unnumbered ends', () {
      expect(
        EpisodeOrder.titleOrder(['第1集', '第2集', '第12集', '特别篇']),
        TitleOrder.ascending,
      );
      expect(
        EpisodeOrder.titleOrder(['PV', '第12集', '第11集', '第1集']),
        TitleOrder.descending,
      );
    });
    test('one parsable title or equal numbers are unknown', () {
      expect(EpisodeOrder.titleOrder(['第3集', 'OVA']), TitleOrder.unknown);
      expect(EpisodeOrder.titleOrder(['第5集', '第5集']), TitleOrder.unknown);
    });
  });

  group('nextDirection', () {
    TitleOrder Function() t(TitleOrder o) =>
        () => o;
    test('not flipped is +1 and never parses titles', () {
      expect(
        EpisodeOrder.nextDirection(
          flipped: false,
          inRoom: false,
          titles: () => throw StateError('parsed'),
        ),
        1,
      );
    });
    test('in a room is +1 even when flipped', () {
      expect(
        EpisodeOrder.nextDirection(
          flipped: true,
          inRoom: true,
          titles: () => throw StateError('parsed'),
        ),
        1,
      );
    });
    test('flipped to view newest first: titles ascending, still +1', () {
      expect(
        EpisodeOrder.nextDirection(
          flipped: true,
          inRoom: false,
          titles: t(TitleOrder.ascending),
        ),
        1,
      );
    });
    test('flipped backwards source: titles descending, −1', () {
      expect(
        EpisodeOrder.nextDirection(
          flipped: true,
          inRoom: false,
          titles: t(TitleOrder.descending),
        ),
        -1,
      );
    });
    test('flipped without numbers follows the flipped list', () {
      expect(
        EpisodeOrder.nextDirection(
          flipped: true,
          inRoom: false,
          titles: t(TitleOrder.unknown),
        ),
        -1,
      );
    });
  });

  group('step', () {
    test('direction +1 is today\'s ±1 with bounds', () {
      for (var length = 1; length <= 4; length++) {
        for (var p = 1; p <= length; p++) {
          expect(
            EpisodeOrder.step(p, next: true, length: length, direction: 1),
            p < length ? p + 1 : null,
          );
          expect(
            EpisodeOrder.step(p, next: false, length: length, direction: 1),
            p > 1 ? p - 1 : null,
          );
        }
      }
    });
    test('direction −1 walks the list backwards', () {
      expect(EpisodeOrder.step(5, next: true, length: 12, direction: -1), 4);
      expect(EpisodeOrder.step(5, next: false, length: 12, direction: -1), 6);
      expect(
        EpisodeOrder.step(1, next: true, length: 12, direction: -1),
        isNull,
      );
      expect(
        EpisodeOrder.step(12, next: false, length: 12, direction: -1),
        isNull,
      );
    });
  });

  group('endOfEpisode', () {
    test('direction +1 matches today\'s hasNext and roomWantsNext', () {
      for (var p = 1; p <= 4; p++) {
        for (final follow in <int?>[null, p - 1, p + 1, p + 2]) {
          final e = EpisodeOrder.endOfEpisode(
            position: p,
            length: 4,
            direction: 1,
            followEpisode: follow,
          );
          expect(e.next != null, p < 4);
          expect(e.next, p < 4 ? p + 1 : null);
          expect(e.roomWantsNext, follow == p + 1);
        }
      }
    });
    test('room follow ignores a flipped direction', () {
      final e = EpisodeOrder.endOfEpisode(
        position: 5,
        length: 12,
        direction: -1,
        followEpisode: 6,
      );
      expect(e.next, 4);
      expect(e.roomWantsNext, isTrue);
    });
  });

  group('display mapping', () {
    test('identity when not flipped', () {
      expect(EpisodeOrder.positionAt(0, length: 12, reversed: false), 1);
      expect(EpisodeOrder.displayIndexOf(12, length: 12, reversed: false), 11);
    });
    test('flipped shows the last position first', () {
      expect(EpisodeOrder.positionAt(0, length: 12, reversed: true), 12);
      expect(EpisodeOrder.positionAt(11, length: 12, reversed: true), 1);
    });
    test('round trip', () {
      for (final reversed in [false, true]) {
        for (var i = 0; i < 7; i++) {
          final p = EpisodeOrder.positionAt(i, length: 7, reversed: reversed);
          expect(
            EpisodeOrder.displayIndexOf(p, length: 7, reversed: reversed),
            i,
          );
        }
      }
    });
  });

  group('store', () {
    test('nothing flipped by default', () {
      expect(EpisodeOrderStore.isReversed(42, 'AGE'), isFalse);
    });
    test('per anime and per source', () async {
      await EpisodeOrderStore.setReversed(42, 'AGE', true);
      expect(EpisodeOrderStore.isReversed(42, 'AGE'), isTrue);
      expect(EpisodeOrderStore.isReversed(42, 'DM84'), isFalse);
      expect(EpisodeOrderStore.isReversed(7, 'AGE'), isFalse);
      await EpisodeOrderStore.setReversed(42, 'AGE', false);
      expect(EpisodeOrderStore.isReversed(42, 'AGE'), isFalse);
    });
    test('corrupt storage reads as not flipped', () async {
      await GStorage.putSetting<String>(EpisodeOrderStore.setting, '[oops');
      expect(EpisodeOrderStore.isReversed(42, 'AGE'), isFalse);
    });
  });
}

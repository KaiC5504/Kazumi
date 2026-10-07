import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/syncplay_watchdog.dart';

void main() {
  late DateTime now;
  late SyncPlayWatchdog dog;
  void advance(int s) => now = now.add(Duration(seconds: s));

  setUp(() {
    now = DateTime(2026, 10, 7, 21);
    dog = SyncPlayWatchdog(clock: () => now)..onConnected();
  });

  test('steady server states keep it quiet', () {
    for (var i = 0; i < 30; i++) {
      advance(1);
      dog.onInbound();
      expect(dog.onTick(), WatchAction.none);
    }
  });

  test('6 s of silence probes once, 3 s more reconnects', () {
    advance(6);
    expect(dog.onTick(), WatchAction.probe);
    advance(1);
    expect(dog.onTick(), WatchAction.none);
    advance(2);
    expect(dog.onTick(), WatchAction.reconnect);
  });

  test('an answer to the probe clears it', () {
    advance(6);
    expect(dog.onTick(), WatchAction.probe);
    advance(1);
    dog.onInbound();
    advance(3);
    expect(dog.onTick(), WatchAction.none);
  });

  test('interface change reconnects at once; none holds', () {
    expect(dog.onNetwork(NetKind.wifi), WatchAction.none);
    expect(dog.onNetwork(NetKind.cellular), WatchAction.reconnect);
    expect(dog.onNetwork(NetKind.none), WatchAction.none);
    expect(dog.offline, isTrue);
    advance(20);
    expect(dog.onTick(), WatchAction.none, reason: 'no attempts while offline');
    expect(dog.onNetwork(NetKind.cellular), WatchAction.reconnect);
    expect(dog.offline, isFalse);
  });

  test('resume thresholds', () {
    expect(dog.onResumed(const Duration(seconds: 8)), WatchAction.none);
    expect(dog.onResumed(const Duration(seconds: 30)), WatchAction.probe);
    expect(dog.onResumed(const Duration(seconds: 61)), WatchAction.reconnect);
  });

  group('ReconnectBackoff', () {
    test('0,1,2,4,8,15,15,15 then exhausted at about a minute', () {
      final b = ReconnectBackoff(clock: () => now)..start();
      final at = <int>[];
      for (var s = 0; s <= 70; s++) {
        if (b.due()) {
          at.add(b.elapsed.inSeconds);
          b.attempted();
        }
        if (b.exhausted) break;
        advance(1);
      }
      expect(at, [0, 1, 3, 7, 15, 30, 45, 60]);
      expect(b.exhausted, isTrue);
    });

    test('suspended during backoff: no catch-up burst on resume', () {
      final b = ReconnectBackoff(clock: () => now)..start();
      expect(b.due(), isTrue);
      b.attempted();
      advance(40); // phone locked, ticks stopped
      expect(b.due(), isTrue);
      b.attempted();
      expect(b.due(), isFalse, reason: 'one attempt, not a burst');
    });
  });
}

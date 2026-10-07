@Tags(['real-server'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/syncplay_watchdog.dart';

import 'support/syncplay_sim.dart';
import 'support/tcp_proxy.dart';

// Runs against a real Syncplay server, started from SYNCPLAY_SERVER (the
// path to syncplay-server.exe), in real time.
void main() {
  final exe = Platform.environment['SYNCPLAY_SERVER'];
  setUpSyncplayStorage();

  test('ghost after her reconnect: does it hold the room?', () async {
    const port = 18999;
    final proc = await Process.start(
      exe!,
      ['--port', '$port', '--isolate-rooms'],
      environment: {'PYTHONUNBUFFERED': '1'},
    );
    final serverLog = <String>[];
    final clock = VirtualClock(1.0);
    for (final out in [proc.stdout, proc.stderr]) {
      out
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (l) => serverLog.add('${clock.seconds.toStringAsFixed(1)} $l'),
          );
    }
    await _waitForPort(port);
    final herRoute = await TcpProxy.start(port);
    final kai = SimViewer(
      'kai',
      clock,
      network: NetworkProfile.australiaToHk,
      episodeLength: 1440,
    );
    final her = SimViewer(
      'her',
      clock,
      network: NetworkProfile.nanningToHk,
      episodeLength: 1440,
    );
    final timeline = <String>[];
    var noticesSeen = 0;
    void sample(String what) {
      final fresh = simNotices.sublist(noticesSeen);
      noticesSeen = simNotices.length;
      timeline.add(
        '${clock.seconds.toStringAsFixed(1)} $what '
        'kai=${kai.position.toStringAsFixed(1)} '
        'her=${her.position.toStringAsFixed(1)} '
        'kaiPeers=${kai.sync.peers.toList()} '
        'herName=${her.sync.syncplayController?.username} '
        'herPeers=${her.sync.peers.toList()} '
        'kaiRate=${kai.rateFactor} herRate=${her.rateFactor} '
        'kaiPlaying=${kai.playing} herPlaying=${her.playing}'
        '${fresh.isEmpty ? '' : ' notices=$fresh'}',
      );
    }

    try {
      await kai.joinEndpoint('127.0.0.1:$port', at: 300);
      await her.joinEndpoint('127.0.0.1:${herRoute.port}', at: 300);
      await clock.wait(10);
      sample('before');
      final noticesBefore = simNotices.length;
      final kaiRatesBefore = kai.rates.length;
      final kaiSeeksBefore = kai.seeks.length;
      final kaiPausesBefore = kai.syncPauses;

      herRoute.zombieExisting();
      her.switchNetwork(NetKind.cellular);
      await clock.until(
        () =>
            !her.sync.reconnecting &&
            (her.sync.syncplayController?.isConnected ?? false),
        timeout: 30,
      );
      sample('reconnected');
      final first = kai.position;
      for (var i = 0; i < 20; i++) {
        await clock.wait(2);
        sample('+${(i + 1) * 2}s');
      }
      final kaiAdvanced = kai.position - first;
      final heldBack = kaiAdvanced < 30;
      final notices = simNotices.sublist(noticesBefore);
      // ignore: avoid_print
      print(
        'GHOST_RESULT heldBack=$heldBack '
        'kaiAdvanced=${kaiAdvanced.toStringAsFixed(1)} '
        'herName=${her.sync.syncplayController?.username} '
        'kaiPeers=${kai.sync.peers.toList()} '
        'herPeers=${her.sync.peers.toList()} '
        'kaiRates=${kai.rates.sublist(kaiRatesBefore)} '
        'kaiSyncSeeks=${kai.seeks.length - kaiSeeksBefore} '
        'kaiSyncPauses=${kai.syncPauses - kaiPausesBefore} '
        'notices=${notices.join(' | ')}',
      );
      // ignore: avoid_print
      print('--- timeline\n${timeline.join('\n')}');
      // ignore: avoid_print
      print('--- server\n${serverLog.join('\n')}');
      expect(heldBack, isFalse);
      expect(kai.rates.sublist(kaiRatesBefore), isEmpty);
      // The server renames her rejoin (her_) and drops her old connection
      // itself after 12.5 s without a state update.
      expect(kai.sync.peers, [her.sync.syncplayController?.username]);
      expect(her.sync.peers, ['kai']);
      expect(
        notices.where((n) => n.contains('离开') || n.contains('加入')),
        isEmpty,
      );
      herRoute.killGhosts();
      await clock.wait(10);
      expect(
        (kai.position - her.position).abs(),
        lessThan(1.5),
        reason: 'once the ghost is gone both must be in sync',
      );

      // Again: her_ is now the ghost and her original name is free.
      herRoute.zombieExisting();
      her.switchNetwork(NetKind.wifi);
      await clock.until(
        () =>
            !her.sync.reconnecting &&
            (her.sync.syncplayController?.isConnected ?? false),
        timeout: 30,
      );
      await clock.wait(32);
      sample('second reconnect');
      // ignore: avoid_print
      print('GHOST_RESULT_2 ${timeline.last}');
      expect(kai.sync.peers, [her.sync.syncplayController?.username]);
      expect(her.sync.peers, ['kai']);
      expect(
        simNotices
            .sublist(noticesBefore)
            .where((n) => n.contains('离开') || n.contains('加入')),
        isEmpty,
      );
      expect((kai.position - her.position).abs(), lessThan(1.5));
    } finally {
      await her.leave();
      await kai.leave();
      await herRoute.close();
      proc.kill();
    }
  }, skip: exe == null ? 'set SYNCPLAY_SERVER to run' : false);
}

Future<void> _waitForPort(int port) async {
  for (var i = 0; i < 100; i++) {
    try {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
      s.destroy();
      return;
    } on SocketException {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  fail('Syncplay server never opened port $port');
}

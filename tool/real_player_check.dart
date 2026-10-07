import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:kazumi/services/player/playback_end_guard.dart';
import 'package:media_kit/media_kit.dart';

final _log = File('${Directory.systemTemp.path}/real_player_check.log');

// A release GUI exe has no console, so the result also goes to a file.
void _say(String line) {
  stdout.writeln(line);
  _log.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

// Run: flutter build windows --release -t tool/real_player_check.dart, then
// start build\windows\x64\runner\Release\kazumi.exe and read the log above.
// Proves on real libmpv what the end guard assumes: a stream cut mid-file
// shows up as `completed` well before the end, and reopening at the last
// good position resumes there.
Future<void> main() async {
  if (_log.existsSync()) _log.deleteSync();
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final clip = File('${Directory.systemTemp.path}/kazumi_cut_check.mp4');
  if (!clip.existsSync()) {
    final r = await Process.run(r'D:\Tools\ffmpeg\bin\ffmpeg.exe', [
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=640x360:rate=24',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440',
      '-t',
      '90',
      '-c:v',
      'libx265',
      '-preset',
      'ultrafast',
      '-b:v',
      '1M',
      '-tag:v',
      'hvc1',
      '-c:a',
      'aac',
      '-movflags',
      '+faststart',
      clip.path,
    ]);
    if (r.exitCode != 0) {
      _say('REAL_PLAYER_CHECK FAIL ffmpeg ${r.stderr}');
      exit(1);
    }
  }
  final bytes = await clip.readAsBytes();
  final cutAt = (bytes.length * 0.4).round();
  var refuseUntil = DateTime(0);
  var firstConnection = true;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    _say(
      '${DateTime.now().toIso8601String()} req '
      '${req.headers.value(HttpHeaders.rangeHeader)}',
    );
    if (DateTime.now().isBefore(refuseUntil)) {
      res.statusCode = 503;
      await res.close();
      return;
    }
    final range = req.headers.value(HttpHeaders.rangeHeader);
    var start = 0;
    if (range != null) {
      start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
    }
    res.statusCode = range == null ? 200 : 206;
    res.headers.contentType = ContentType('video', 'mp4');
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    res.headers.contentLength = bytes.length - start;
    if (range != null) {
      res.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${bytes.length - 1}/${bytes.length}',
      );
    }
    final cut = firstConnection;
    firstConnection = false;
    final end = cut ? cutAt : bytes.length;
    if (start < end) res.add(bytes.sublist(start, end));
    if (cut) {
      refuseUntil = DateTime.now().add(const Duration(seconds: 40));
      await res.flush();
      await res.detachSocket().then((s) => s.destroy());
      return;
    }
    await res.close();
  });
  final url = 'http://127.0.0.1:${server.port}/clip.mp4';

  final guard = PlaybackEndGuard()..onEpisodeStarted('check[1]');
  final player = Player();
  await (player.platform as NativePlayer).setProperty('cache', 'no');
  await player.open(Media(url));
  final completedAt = Completer<Duration>();
  final timer = Timer.periodic(const Duration(seconds: 1), (_) {
    final s = player.state;
    guard.onTick(
      position: s.position,
      playing: s.playing,
      completed: s.completed,
    );
    if (s.completed && !completedAt.isCompleted) {
      completedAt.complete(s.position);
    }
  });
  try {
    final pos = await completedAt.future.timeout(const Duration(minutes: 4));
    final duration = player.state.duration;
    // The guard spaces its reload attempts, so it answers `none` at first.
    var decision = const EndDecision(EndAction.none);
    for (var i = 0; i < 15 && decision.action == EndAction.none; i++) {
      decision = guard.onCompleted(
        position: pos,
        duration: duration,
        resumedNearEnd: false,
      );
      if (decision.action == EndAction.none) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    final early = duration - pos > const Duration(seconds: 30);
    _say(
      'cut: completed at $pos of $duration, '
      'decision ${decision.action} resumeAt ${decision.resumeAt}',
    );
    await Future<void>.delayed(const Duration(seconds: 41));
    guard.onEpisodeStarted('check[1]');
    await player.open(Media(url, start: decision.resumeAt));
    await Future<void>.delayed(const Duration(seconds: 6));
    final resumed = player.state.position;
    final drift = (resumed - decision.resumeAt).abs();
    timer.cancel();
    final pass =
        early &&
        decision.action == EndAction.reload &&
        drift < const Duration(seconds: 8);
    _say(
      'REAL_PLAYER_CHECK ${pass ? 'PASS' : 'FAIL'} '
      'early=$early action=${decision.action} resumeAt=${decision.resumeAt} '
      'resumedAt=$resumed',
    );
    await player.dispose();
    await server.close(force: true);
    exit(pass ? 0 : 1);
  } on TimeoutException {
    final s = player.state;
    _say(
      'REAL_PLAYER_CHECK FAIL never completed: '
      'position=${s.position} duration=${s.duration} '
      'buffering=${s.buffering} playing=${s.playing}',
    );
    exit(1);
  }
}

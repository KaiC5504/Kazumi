import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/download/parted_transfer.dart';

void main() {
  late Directory tmp;
  late File tmpFile;
  late File partsLog;
  final source = List<int>.generate(1000, (i) => i % 251);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kazumi_parted_test');
    tmpFile = File('${tmp.path}/video.mp4.tmp');
    partsLog = File('${tmp.path}/video.mp4.parts');
  });
  tearDown(() => tmp.delete(recursive: true));

  Stream<List<int>> chunked(int start, int end) async* {
    for (var i = start; i < end; i += 37) {
      await Future<void>.delayed(Duration.zero);
      yield source.sublist(i, i + 37 < end ? i + 37 : end);
    }
  }

  Future<bool> download({
    required Future<Stream<List<int>>> Function(int, int) openRange,
    bool Function()? stopped,
    void Function(int)? onProgress,
  }) => downloadInParts(
    tmpFile: tmpFile,
    partsLog: partsLog,
    totalSize: source.length,
    openRange: openRange,
    stopped: stopped ?? () => false,
    onProgress: onProgress,
    partSize: 128,
    connections: 3,
    backoff: (_) => Duration.zero,
  );

  test('assembles parts fetched concurrently and out of order', () async {
    final opened = <int>[];
    var active = 0;
    var peak = 0;
    final progress = <int>[];
    final ok = await download(
      openRange: (start, end) async {
        opened.add(start);
        active++;
        peak = peak > active ? peak : active;
        // Later parts answer first.
        await Future<void>.delayed(Duration(milliseconds: 20 - start ~/ 64));
        active--;
        return chunked(start, end);
      },
      onProgress: progress.add,
    );
    expect(ok, isTrue);
    expect(await tmpFile.readAsBytes(), source);
    expect(await partsLog.exists(), isFalse);
    expect(opened.length, 8);
    expect(peak, 3);
    expect(progress.last, source.length);
  });

  test('retries a part whose stream ends early', () async {
    var shortOnce = true;
    final ok = await download(
      openRange: (start, end) async {
        if (start == 256 && shortOnce) {
          shortOnce = false;
          return chunked(start, start + 10);
        }
        return chunked(start, end);
      },
    );
    expect(ok, isTrue);
    expect(await tmpFile.readAsBytes(), source);
  });

  test('gives up after the attempts run out and keeps finished parts', () async {
    await expectLater(
      download(
        openRange: (start, end) async {
          if (start == 512) throw const SocketException('reset');
          return chunked(start, end);
        },
      ),
      throwsA(isA<SocketException>()),
    );
    final logged = (await partsLog.readAsLines()).map(int.parse).toSet();
    expect(logged, isNot(contains(4)));
    expect(logged, isNotEmpty);

    final reopened = <int>[];
    final ok = await download(
      openRange: (start, end) async {
        reopened.add(start ~/ 128);
        return chunked(start, end);
      },
    );
    expect(ok, isTrue);
    expect(await tmpFile.readAsBytes(), source);
    expect(reopened.toSet().intersection(logged), isEmpty);
  });

  test('does not retry errors that are not retryable', () async {
    var calls = 0;
    await expectLater(
      downloadInParts(
        tmpFile: tmpFile,
        partsLog: partsLog,
        totalSize: source.length,
        partSize: 128,
        connections: 1,
        stopped: () => false,
        retryable: (e) => e is! StateError,
        backoff: (_) => Duration.zero,
        openRange: (start, end) async {
          calls++;
          throw StateError('cancelled');
        },
      ),
      throwsA(isA<StateError>()),
    );
    expect(calls, 1);
  });

  test('stopping leaves a resumable download', () async {
    var stop = false;
    final ok = await download(
      openRange: (start, end) async {
        if (start >= 384) stop = true;
        return chunked(start, end);
      },
      stopped: () => stop,
    );
    expect(ok, isFalse);
    expect(await tmpFile.exists(), isTrue);
    final logged = (await partsLog.readAsLines()).map(int.parse).toSet();
    expect(logged.length, lessThan(8));

    final reopened = <int>[];
    expect(
      await download(
        openRange: (start, end) async {
          reopened.add(start ~/ 128);
          return chunked(start, end);
        },
      ),
      isTrue,
    );
    expect(await tmpFile.readAsBytes(), source);
    expect(reopened.toSet().intersection(logged), isEmpty);
  });

  test('a tmp file from the old single-stream download counts as done', () async {
    await tmpFile.writeAsBytes(source.sublist(0, 300));
    final reopened = <int>[];
    final ok = await download(
      openRange: (start, end) async {
        reopened.add(start ~/ 128);
        return chunked(start, end);
      },
    );
    expect(ok, isTrue);
    expect(reopened..sort(), [2, 3, 4, 5, 6, 7]);
    expect(await tmpFile.readAsBytes(), source);
  });

  test('a stale tmp longer than the file is trimmed', () async {
    await tmpFile.writeAsBytes(List.filled(2000, 7));
    await partsLog.writeAsString('');
    final ok = await download(openRange: (s, e) async => chunked(s, e));
    expect(ok, isTrue);
    expect(await tmpFile.readAsBytes(), source);
  });

  test('part math covers a short last part', () {
    expect(partCount(1000, 128), 8);
    expect(partLength(7, 1000, 128), 104);
    expect(partCount(1024, 128), 8);
    expect(partLength(7, 1024, 128), 128);
  });
}

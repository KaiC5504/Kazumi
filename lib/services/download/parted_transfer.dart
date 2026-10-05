import 'dart:async';
import 'dart:io';
import 'dart:math';

/// Transfers to and from the library server cross long, lossy links (home
/// uplink to Singapore, Singapore to mainland China) where one TCP stream
/// gets a small share of the bandwidth, so files move as fixed-size parts
/// over several connections at once.
const int transferPartSize = 8 * 1024 * 1024;
const int transferConnections = 8;

int partCount(int totalSize, int partSize) =>
    (totalSize + partSize - 1) ~/ partSize;

int partLength(int index, int totalSize, int partSize) =>
    min(partSize, totalSize - index * partSize);

class ShortPartException implements Exception {
  const ShortPartException(this.index, this.received, this.expected);

  final int index;
  final int received;
  final int expected;

  @override
  String toString() => 'part $index ended at $received of $expected bytes';
}

/// Runs [transfer] for every index in [pending] on up to [connections]
/// workers. A failed part is retried up to [attempts] times unless
/// [retryable] says otherwise; once a part runs out of attempts the other
/// workers finish their current part, start no new one, and the error is
/// rethrown.
Future<void> runParts({
  required List<int> pending,
  required Future<void> Function(int index) transfer,
  required bool Function() stopped,
  int connections = transferConnections,
  int attempts = 5,
  bool Function(Object error) retryable = _always,
  Duration Function(int attempt) backoff = _backoff,
  void Function(int index, Object error)? onRetry,
}) async {
  final queue = List<int>.of(pending);
  var failed = false;

  Future<void> worker() async {
    while (queue.isNotEmpty && !failed && !stopped()) {
      final index = queue.removeAt(0);
      var attempt = 0;
      while (true) {
        try {
          await transfer(index);
          break;
        } catch (e) {
          if (!retryable(e) || ++attempt >= attempts) {
            failed = true;
            rethrow;
          }
          onRetry?.call(index, e);
        }
        if (failed || stopped()) return;
        await Future.delayed(backoff(attempt));
      }
    }
  }

  await Future.wait([
    for (var i = 0; i < min(connections, queue.length); i++) worker(),
  ]);
}

bool _always(Object _) => true;

Duration _backoff(int attempt) => Duration(seconds: 2 * attempt);

/// Downloads [totalSize] bytes into [tmpFile] in parts fetched with
/// [openRange] (`end` exclusive). Finished part indices are appended to
/// [partsLog], so calling this again resumes. Returns false when [stopped]
/// cut it short; the caller renames [tmpFile] once this returns true.
Future<bool> downloadInParts({
  required File tmpFile,
  required File partsLog,
  required int totalSize,
  required Future<Stream<List<int>>> Function(int start, int end) openRange,
  required bool Function() stopped,
  void Function(int receivedBytes)? onProgress,
  int partSize = transferPartSize,
  int connections = transferConnections,
  int attempts = 5,
  bool Function(Object error) retryable = _always,
  Duration Function(int attempt) backoff = _backoff,
}) async {
  final count = partCount(totalSize, partSize);
  int lengthOf(int i) => partLength(i, totalSize, partSize);

  final done = <int>{};
  if (await tmpFile.exists()) {
    if (await partsLog.exists()) {
      for (final line in await partsLog.readAsLines()) {
        final i = int.tryParse(line);
        if (i != null && i >= 0 && i < count) done.add(i);
      }
    } else {
      // A .tmp left by the old single-stream download is a valid prefix.
      final prefix = min(await tmpFile.length() ~/ partSize, count);
      done.addAll([for (var i = 0; i < prefix; i++) i]);
      await partsLog.writeAsString(done.map((i) => '$i\n').join());
    }
  } else {
    if (await partsLog.exists()) await partsLog.delete();
    await tmpFile.create(recursive: true);
  }

  var finished = done.fold<int>(0, (sum, i) => sum + lengthOf(i));
  final inFlight = <int, int>{};
  void report() => onProgress?.call(
    finished + inFlight.values.fold<int>(0, (sum, n) => sum + n),
  );
  report();

  await runParts(
    pending: [
      for (var i = 0; i < count; i++)
        if (!done.contains(i)) i,
    ],
    connections: connections,
    attempts: attempts,
    retryable: retryable,
    backoff: backoff,
    stopped: stopped,
    transfer: (index) async {
      final start = index * partSize;
      final length = lengthOf(index);
      final stream = await openRange(start, start + length);
      final raf = await tmpFile.open(mode: FileMode.append);
      try {
        await raf.setPosition(start);
        var received = 0;
        await for (final chunk in stream) {
          if (stopped()) return;
          await raf.writeFrom(chunk);
          received += chunk.length;
          inFlight[index] = received;
          report();
        }
        if (received != length) {
          throw ShortPartException(index, received, length);
        }
        await raf.flush();
      } finally {
        inFlight.remove(index);
        await raf.close();
      }
      if (stopped()) return;
      finished += length;
      await partsLog.writeAsString(
        '$index\n',
        mode: FileMode.append,
        flush: true,
      );
      report();
    },
  );
  if (stopped()) return false;

  final raf = await tmpFile.open(mode: FileMode.append);
  try {
    await raf.truncate(totalSize);
  } finally {
    await raf.close();
  }
  await partsLog.delete();
  return true;
}

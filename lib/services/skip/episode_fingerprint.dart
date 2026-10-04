import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kazumi/services/upscale/upscale_baker.dart';
import 'package:path/path.dart' as path;

const String episodeFingerprintFileName = 'skip_fingerprint.json';

/// Chromaprint fingerprints of an episode's first and last minutes, kept next
/// to the download so later episodes can be compared without decoding again.
class EpisodeFingerprint {
  const EpisodeFingerprint({
    required this.duration,
    required this.tailStart,
    required this.head,
    required this.tail,
  });

  /// Seconds.
  final double duration;
  final double tailStart;
  final Uint32List head;
  final Uint32List tail;

  /// Long enough to reach an opening after a long cold open.
  static double headSecondsFor(double duration) =>
      duration <= 0 ? 600 : (duration * 0.4).clamp(0, 600).toDouble();

  static double tailSecondsFor(double duration) =>
      (duration * 0.4).clamp(0, 360).toDouble();

  factory EpisodeFingerprint.fromJson(Map<String, dynamic> json) =>
      EpisodeFingerprint(
        duration: (json['duration'] as num).toDouble(),
        tailStart: (json['tailStart'] as num).toDouble(),
        head: _decodePoints(json['head'] as String),
        tail: _decodePoints(json['tail'] as String),
      );

  Map<String, dynamic> toJson() => {
    'duration': duration,
    'tailStart': tailStart,
    'head': _encodePoints(head),
    'tail': _encodePoints(tail),
  };

  static Future<EpisodeFingerprint?> load(String directory) async {
    final file = File(path.join(directory, episodeFingerprintFileName));
    if (!await file.exists()) return null;
    try {
      return EpisodeFingerprint.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
    } on Object {
      return null;
    }
  }

  Future<void> save(String directory) => File(
    path.join(directory, episodeFingerprintFileName),
  ).writeAsString(jsonEncode(toJson()), flush: true);

  /// Runs ffmpeg's chromaprint muxer over the start and end of [input].
  static Future<EpisodeFingerprint> compute(
    FfmpegInfo ffmpeg,
    String input,
  ) async {
    final durationUs = await UpscaleBaker.probeDurationUs(
      ffmpeg.executable,
      input,
    );
    if (durationUs <= 0) {
      throw UpscaleBakeException('无法读取视频时长: $input');
    }
    final duration = durationUs / 1000000;
    final tailSeconds = tailSecondsFor(duration);
    final tailStart = duration - tailSeconds;
    final temp = await Directory.systemTemp.createTemp('kazumi_fp');
    try {
      final head = await _run(
        ffmpeg.executable,
        input,
        path.join(temp.path, 'head.bin'),
        start: 0,
        seconds: headSecondsFor(duration),
      );
      final tail = await _run(
        ffmpeg.executable,
        input,
        path.join(temp.path, 'tail.bin'),
        start: tailStart,
        seconds: tailSeconds,
      );
      return EpisodeFingerprint(
        duration: duration,
        tailStart: tailStart,
        head: head,
        tail: tail,
      );
    } finally {
      await temp.delete(recursive: true);
    }
  }

  static Future<Uint32List> _run(
    String exe,
    String input,
    String output, {
    required double start,
    required double seconds,
  }) async {
    final result = await Process.run(exe, [
      '-hide_banner',
      '-y',
      '-loglevel',
      'error',
      if (input.toLowerCase().endsWith('.m3u8')) ...[
        '-allowed_extensions',
        'ALL',
        '-protocol_whitelist',
        'file,crypto,data',
      ],
      if (start > 0) ...['-ss', start.toStringAsFixed(3)],
      '-i',
      input,
      '-t',
      seconds.toStringAsFixed(3),
      '-map',
      '0:a:0',
      '-vn',
      '-ac',
      '1',
      '-ar',
      '11025',
      '-f',
      'chromaprint',
      '-fp_format',
      'raw',
      output,
    ]);
    if (result.exitCode != 0) {
      final detail = (result.stderr as String).trim();
      throw UpscaleBakeException(
        'ffmpeg 指纹提取失败 (${result.exitCode}) '
        '${detail.isEmpty ? '' : detail.split('\n').last}',
      );
    }
    final bytes = await File(output).readAsBytes();
    return _pointsFromBytes(bytes);
  }

  static Uint32List _pointsFromBytes(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    return Uint32List.fromList([
      for (var i = 0; i + 4 <= bytes.length; i += 4)
        data.getUint32(i, Endian.little),
    ]);
  }

  static String _encodePoints(Uint32List points) {
    final data = ByteData(points.length * 4);
    for (var i = 0; i < points.length; i++) {
      data.setUint32(i * 4, points[i], Endian.little);
    }
    return base64Encode(data.buffer.asUint8List());
  }

  static Uint32List _decodePoints(String encoded) =>
      _pointsFromBytes(base64Decode(encoded));
}

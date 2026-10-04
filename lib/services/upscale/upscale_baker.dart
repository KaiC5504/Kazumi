import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:path/path.dart' as path;

class FfmpegInfo {
  const FfmpegInfo({
    required this.executable,
    required this.version,
    required this.encoder,
    this.chromaprint = false,
  });

  final String executable;
  final String version;

  /// 'hevc_nvenc' when an NVIDIA GPU is usable, otherwise 'libx265' (slow).
  final String encoder;

  /// Needed to fingerprint openings and endings; the essentials builds lack it.
  final bool chromaprint;

  bool get hardwareEncoder => encoder != 'libx265';
}

class UpscaleBakeException implements Exception {
  UpscaleBakeException(this.message);
  final String message;

  @override
  String toString() => message;
}

class UpscaleBakeCancelled implements Exception {}

/// Renders Kazumi's quality-tier Anime4K chain into a standalone HEVC file
/// with ffmpeg's libplacebo filter, so weaker devices can play it without
/// running the shaders live.
class UpscaleBaker {
  Process? _process;
  bool _cancelled = false;

  /// Finds a usable ffmpeg. Returns null with [error] set when none works.
  static Future<(FfmpegInfo?, String?)> detect(String configuredPath) async {
    final candidates = <String>[
      if (configuredPath.trim().isNotEmpty) configuredPath.trim(),
      Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg',
    ];
    String? lastError;
    for (final exe in candidates) {
      try {
        final version = await Process.run(exe, ['-hide_banner', '-version']);
        if (version.exitCode != 0) {
          lastError = '无法运行 $exe';
          continue;
        }
        final versionLine = (version.stdout as String).split('\n').first.trim();

        final filters = await Process.run(exe, ['-hide_banner', '-filters']);
        if (!(filters.stdout as String).contains('libplacebo')) {
          lastError = '$exe 不包含 libplacebo 滤镜，请安装 gyan.dev full 版本';
          continue;
        }
        final muxers = await Process.run(exe, ['-hide_banner', '-muxers']);
        final chromaprint = (muxers.stdout as String).contains('chromaprint');

        final encoder = await _probeNvenc(exe) ? 'hevc_nvenc' : 'libx265';
        return (
          FfmpegInfo(
            executable: exe,
            version: versionLine,
            encoder: encoder,
            chromaprint: chromaprint,
          ),
          null,
        );
      } on ProcessException {
        lastError = configuredPath.trim().isEmpty
            ? '未找到 ffmpeg，请安装后在此填写路径'
            : '找不到 $exe';
      }
    }
    return (null, lastError);
  }

  /// Listing the encoder isn't enough; it is compiled in on machines without
  /// an NVIDIA GPU, so encode a single frame to be sure.
  static Future<bool> _probeNvenc(String exe) async {
    try {
      final result = await Process.run(exe, [
        '-hide_banner',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'color=black:s=256x256',
        '-frames:v',
        '1',
        '-c:v',
        'hevc_nvenc',
        '-f',
        'null',
        '-',
      ]);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// libplacebo takes a single custom shader file, so the tier's shaders are
  /// concatenated in playback order.
  static Future<String> buildCombinedShader(String shadersDirectory) async {
    final buffer = StringBuffer();
    for (final name in mpvAnime4KShaders) {
      buffer.writeln(
        await File(path.join(shadersDirectory, name)).readAsString(),
      );
    }
    final combined = File(
      path.join(shadersDirectory, 'anime4k_quality_combined.glsl'),
    );
    await combined.writeAsString(buffer.toString(), flush: true);
    return combined.path;
  }

  Future<void> bake({
    required FfmpegInfo ffmpeg,
    required String input,
    required String output,
    required String shaderPath,
    required int targetHeight,
    required void Function(double progress) onProgress,
  }) async {
    _cancelled = false;
    final tmpOutput = '$output.tmp.mp4';
    await Directory(path.dirname(output)).create(recursive: true);
    try {
      try {
        await _run(
          ffmpeg,
          input,
          tmpOutput,
          shaderPath,
          targetHeight,
          onProgress,
          copyAudio: true,
        );
      } on UpscaleBakeException catch (e) {
        if (_cancelled) rethrow;
        // Some sources carry audio the mp4 muxer rejects as-is.
        KazumiLogger().w(
          'UpscaleBaker: retrying with re-encoded audio after: ${e.message}',
        );
        await _run(
          ffmpeg,
          input,
          tmpOutput,
          shaderPath,
          targetHeight,
          onProgress,
          copyAudio: false,
        );
      }
      final finalFile = File(output);
      if (await finalFile.exists()) await finalFile.delete();
      await File(tmpOutput).rename(output);
    } finally {
      final tmp = File(tmpOutput);
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } on FileSystemException {
          // ffmpeg may still hold the handle for a moment after a kill.
        }
      }
    }
  }

  Future<void> _run(
    FfmpegInfo ffmpeg,
    String input,
    String output,
    String shaderPath,
    int targetHeight,
    void Function(double progress) onProgress, {
    required bool copyAudio,
  }) async {
    final scaleFilter =
        'libplacebo='
        'w=trunc(iw*$targetHeight/ih/2)*2:h=$targetHeight:'
        'custom_shader_path=${path.basename(shaderPath)}:'
        'format=${ffmpeg.hardwareEncoder ? 'p010le' : 'yuv420p10le'}';
    final videoArgs = ffmpeg.hardwareEncoder
        ? ['-c:v', 'hevc_nvenc', '-preset', 'p5', '-rc', 'vbr', '-cq', '22'] +
              ['-b:v', '0']
        : ['-c:v', 'libx265', '-preset', 'medium', '-crf', '20'];
    final args = [
      '-hide_banner',
      '-y',
      '-nostats',
      '-loglevel',
      'error',
      '-init_hw_device',
      'vulkan',
      if (input.toLowerCase().endsWith('.m3u8')) ...[
        '-allowed_extensions',
        'ALL',
        '-protocol_whitelist',
        'file,crypto,data',
      ],
      '-i',
      input,
      '-map',
      '0:v:0',
      '-map',
      '0:a:0?',
      '-vf',
      scaleFilter,
      ...videoArgs,
      '-profile:v',
      'main10',
      '-tag:v',
      'hvc1',
      ...copyAudio ? ['-c:a', 'copy'] : ['-c:a', 'aac', '-b:a', '192k'],
      '-movflags',
      '+faststart',
      '-progress',
      'pipe:1',
      output,
    ];

    final duration = await probeDurationUs(ffmpeg.executable, input);
    KazumiLogger().i('UpscaleBaker: ${ffmpeg.executable} ${args.join(' ')}');

    // Filtergraph escaping of Windows paths is fragile, so run next to the
    // shader and refer to it by bare file name.
    final process = await Process.start(
      ffmpeg.executable,
      args,
      workingDirectory: path.dirname(shaderPath),
    );
    _process = process;
    final stderrBuffer = StringBuffer();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .listen(stderrBuffer.write)
        .asFuture<void>();
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (duration > 0 && line.startsWith('out_time_us=')) {
            final us = int.tryParse(line.substring('out_time_us='.length));
            if (us != null) onProgress((us / duration).clamp(0.0, 1.0));
          }
        })
        .asFuture<void>();

    final exitCode = await process.exitCode;
    await Future.wait([stdoutDone, stderrDone]);
    _process = null;

    if (_cancelled) throw UpscaleBakeCancelled();
    if (exitCode != 0) {
      final detail = stderrBuffer.toString().trim();
      KazumiLogger().e('UpscaleBaker: ffmpeg exited with $exitCode: $detail');
      final lastLine = detail.isEmpty ? '' : detail.split('\n').last;
      throw UpscaleBakeException('ffmpeg 失败 ($exitCode) $lastLine');
    }
    onProgress(1.0);
  }

  static Future<int> probeDurationUs(String exe, String input) async {
    final result = await Process.run(exe, [
      '-hide_banner',
      if (input.toLowerCase().endsWith('.m3u8')) ...[
        '-allowed_extensions',
        'ALL',
        '-protocol_whitelist',
        'file,crypto,data',
      ],
      '-i',
      input,
    ]);
    final match = RegExp(
      r'Duration: (\d+):(\d+):(\d+)\.(\d+)',
    ).firstMatch(result.stderr as String);
    if (match == null) return 0;
    final h = int.parse(match.group(1)!);
    final m = int.parse(match.group(2)!);
    final s = int.parse(match.group(3)!);
    final frac = match.group(4)!;
    final fracUs = (int.parse(frac) * 1000000) ~/ _pow10(frac.length);
    return ((h * 3600 + m * 60 + s) * 1000000) + fracUs;
  }

  static int _pow10(int n) {
    var v = 1;
    for (var i = 0; i < n; i++) {
      v *= 10;
    }
    return v;
  }

  void cancel() {
    _cancelled = true;
    _process?.kill();
  }
}

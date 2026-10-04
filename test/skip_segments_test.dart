import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/skip/aniskip_client.dart';
import 'package:kazumi/services/skip/skip_segments.dart';
import 'package:kazumi/services/upscale/upscaled_package.dart';

UpscaledEpisodeManifest _manifest({
  SkipSegments skipSegments = SkipSegments.empty,
}) => UpscaledEpisodeManifest(
  bangumiId: 10639,
  pluginName: 'aafun',
  bangumiName: 'Fate/Zero',
  bangumiCover: '',
  episodeNumber: 3,
  episodeName: '',
  road: 0,
  episodePageUrl: '',
  danDanBangumiID: 0,
  tier: 'quality',
  width: 0,
  height: 1440,
  sizeBytes: 123,
  hasDanmaku: false,
  skipSegments: skipSegments,
);

void main() {
  const segments = SkipSegments(
    opening: SkipRange(137.7, 227.0, SkipSource.fingerprint),
    ending: SkipRange(1369.3, 1459.2, SkipSource.aniskip),
  );

  group('SkipSegments', () {
    test('round-trips through the stored string', () {
      expect(SkipSegments.decode(segments.encode()), segments);
    });

    test('stores nothing when empty', () {
      expect(SkipSegments.empty.encode(), '');
      expect(SkipSegments.decode(''), SkipSegments.empty);
      expect(SkipSegments.decode('not json'), SkipSegments.empty);
    });

    test('finds the segment playing now', () {
      expect(segments.activeAt(100), isNull);
      expect(segments.activeAt(140)?.$1, SkipKind.opening);
      expect(segments.activeAt(1400)?.$1, SkipKind.ending);
      expect(segments.activeAt(227.0), isNull);
    });
  });

  group('manifest', () {
    test('carries skip times and stays version 1', () {
      final decoded = UpscaledEpisodeManifest.decode(
        _manifest(skipSegments: segments).encode(),
      );
      expect(decoded.version, 1);
      expect(decoded.skipSegments, segments);
      expect(decoded.toDownloadEntities().$2.skipSegments, segments.encode());
    });

    test('omits the key without skip times', () {
      expect(_manifest().toJson().containsKey('skip'), isFalse);
    });

    test('reads manifests written before skip times existed', () {
      final json = _manifest().toJson()..remove('skip');
      final decoded = UpscaledEpisodeManifest.fromJson(json);
      expect(decoded.skipSegments.isEmpty, isTrue);
    });
  });

  group('AniSkip', () {
    test('parses openings and endings', () {
      final parsed = parseAniSkipResponse({
        'found': true,
        'results': [
          {
            'interval': {'startTime': 6.576, 'endTime': 96.576},
            'skipType': 'op',
          },
          {
            'interval': {'startTime': 1460, 'endTime': 1550},
            'skipType': 'mixed-ed',
          },
        ],
      });
      expect(
        parsed.opening,
        const SkipRange(6.576, 96.576, SkipSource.aniskip),
      );
      expect(parsed.ending, const SkipRange(1460, 1550, SkipSource.aniskip));
    });

    test('treats not found as empty', () {
      expect(
        parseAniSkipResponse({'found': false, 'results': []}).isEmpty,
        isTrue,
      );
    });

    test('compacts the bangumi to MAL id map', () {
      final map = compactBangumiMalMap(
        '[{"bgm_id": "10639", "mal_id": "10087"},'
        ' {"bgm_id": "12", "douban_id": "1"}]',
      );
      expect(map, {10639: 10087});
    });
  });
}

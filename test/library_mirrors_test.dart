import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/download/mirror_selector.dart';
import 'package:kazumi/services/library/library_api.dart';

void main() {
  final server = Uri.parse('https://kazumi.kaic5504.com');
  final hk = Uri.parse('https://hk.kaic5504.com');
  const queued =
      'https://kazumi.kaic5504.com/episodes/abc123/video.mp4?token=secret';

  group('LibraryApi.rehost', () {
    test('keeps the path and token, swaps the host', () {
      expect(
        LibraryApi.rehost(queued, hk),
        'https://hk.kaic5504.com/episodes/abc123/video.mp4?token=secret',
      );
    });

    test('carries a port when the host has one', () {
      expect(
        LibraryApi.rehost(queued, Uri.parse('http://10.0.0.2:8443')),
        'http://10.0.0.2:8443/episodes/abc123/video.mp4?token=secret',
      );
    });

    test('a rehosted URL still belongs to the library', () {
      final api = LibraryApi('kazumi.kaic5504.com', 'secret');
      expect(api.ownsUrl(LibraryApi.rehost(queued, hk)), isTrue);
    });
  });

  test('a relay that accepts but stalls gives up quickly', () async {
    final hung = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    hung.listen((_) {});
    addTearDown(() => hung.close(force: true));
    final api = LibraryApi(
      'kazumi.kaic5504.com',
      'secret',
      apiHost: Uri.parse('http://127.0.0.1:${hung.port}'),
      relayTimeout: const Duration(milliseconds: 300),
    );
    final watch = Stopwatch()..start();
    await expectLater(api.config(), throwsA(isA<LibraryException>()));
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });

  group('LibraryApi.hostOrder', () {
    test('relays first until ranked', () {
      expect(LibraryApi.hostOrder(server, [hk], const []), [hk, server]);
    });

    test('no relays leaves just the server', () {
      expect(LibraryApi.hostOrder(server, const [], const []), [server]);
    });

    test('a measured ranking wins', () {
      expect(LibraryApi.hostOrder(server, [hk], [server, hk]), [server, hk]);
    });
  });

  group('MirrorRegistry', () {
    tearDown(MirrorRegistry.reset);

    test('a download from an old build gains the relay', () {
      final api = LibraryApi('kazumi.kaic5504.com', 'secret');
      MirrorRegistry.expand = (url) => api.ownsUrl(url)
          ? [
              for (final host in LibraryApi.hostOrder(server, [hk], const []))
                LibraryApi.rehost(url, host),
            ]
          : null;

      final set = MirrorRegistry.forUrl(queued);
      expect(set.urls, [
        'https://hk.kaic5504.com/episodes/abc123/video.mp4?token=secret',
        queued,
      ]);
      expect(set.pick(), startsWith('https://hk.kaic5504.com/'));
      expect(identical(MirrorRegistry.forUrl(queued), set), isTrue);
    });

    test('URLs outside the library stay on their own host', () {
      final api = LibraryApi('kazumi.kaic5504.com', 'secret');
      MirrorRegistry.expand = (url) => api.ownsUrl(url) ? [url, url] : null;
      const other = 'https://example.com/v.m3u8';
      expect(MirrorRegistry.forUrl(other).urls, [other]);
      const otherKey =
          'https://kazumi.kaic5504.com/episodes/abc123/video.mp4?token=nope';
      expect(MirrorRegistry.forUrl(otherKey).urls, [otherKey]);
    });

    test('the original URL is kept even if expand leaves it out', () {
      MirrorRegistry.expand = (_) => [
        'https://hk.kaic5504.com/a',
        'https://hk2.kaic5504.com/a',
      ];
      expect(MirrorRegistry.forUrl(queued).urls.last, queued);
    });

    test('a set registered while queueing wins over expand', () {
      MirrorRegistry.register(['https://a/x', 'https://b/x']);
      MirrorRegistry.expand = (_) => fail('should not be asked');
      expect(MirrorRegistry.forUrl('https://b/x').urls, [
        'https://a/x',
        'https://b/x',
      ]);
    });

    test('no expand behaves as before', () {
      expect(MirrorRegistry.forUrl(queued).urls, [queued]);
    });
  });
}

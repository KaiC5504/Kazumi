import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/download/mirror_selector.dart';

void main() {
  const hk = 'https://hk.example.com/episodes/a/video.mp4?token=k';
  const sg = 'https://sg.example.com/episodes/a/video.mp4?token=k';
  const second = Duration(seconds: 1);

  test('uses the first url until speeds are known', () {
    final set = MirrorSet([hk, sg]);
    expect([for (var i = 0; i < 7; i++) set.pick()], everyElement(hk));
  });

  test('moves to the faster host once measured', () {
    final set = MirrorSet([hk, sg]);
    set.reportSuccess(hk, 100 * 1024, second);
    set.reportSuccess(sg, 4 * 1024 * 1024, second);
    final picks = [for (var i = 0; i < 16; i++) set.pick()];
    expect(picks.where((u) => u == sg).length, 14);
    expect(picks.where((u) => u == hk).length, 2, reason: 'every 8th tries hk');
  });

  test('a recovered host wins back the traffic', () {
    final set = MirrorSet([hk, sg]);
    set.reportSuccess(hk, 1024, second);
    set.reportSuccess(sg, 1024 * 1024, second);
    for (var i = 0; i < 6; i++) {
      set.reportSuccess(hk, 8 * 1024 * 1024, second);
    }
    expect(set.pick(), hk);
  });

  test('a failed host rests, then comes back', () {
    var now = DateTime(2026);
    final set = MirrorSet([hk, sg], clock: () => now);
    set.reportFailure(hk);
    expect([for (var i = 0; i < 10; i++) set.pick()], everyElement(sg));
    now = now.add(const Duration(seconds: 31));
    expect(set.pick(), hk);
  });

  test('when every host is resting it still answers', () {
    final set = MirrorSet([hk, sg]);
    set.reportFailure(hk);
    set.reportFailure(sg);
    expect([hk, sg], contains(set.pick()));
  });

  test('the registry shares one set across all urls of a file', () {
    MirrorRegistry.register([hk, sg]);
    expect(identical(MirrorRegistry.forUrl(hk), MirrorRegistry.forUrl(sg)),
        isTrue);
    expect(MirrorRegistry.forUrl('https://other/x').urls, ['https://other/x']);
  });
}

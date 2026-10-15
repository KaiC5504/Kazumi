import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/player/danmaku_binding_card.dart';
import 'package:kazumi/pages/video/video_controller.dart';

void main() {
  testWidgets('shows the remembered anime and resets on tap', (tester) async {
    var resets = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DanmakuBindingCard(
            animeTitle: '进击的巨人 最终季',
            onReset: () => resets++,
          ),
        ),
      ),
    );
    expect(find.text('已记住：进击的巨人 最终季'), findsOneWidget);
    await tester.tap(find.text('恢复自动匹配'));
    expect(resets, 1);
  });

  group('danmakuPickAllowed', () {
    const ep3 = VideoEpisodeSelection(episode: 3, road: 0);
    const ep4 = VideoEpisodeSelection(episode: 4, road: 0);
    test('same episode throughout', () {
      expect(
        danmakuPickAllowed(
          loadedFor: ep3,
          openedFor: ep3,
          playingNow: ep3,
          sessionActive: true,
        ),
        isTrue,
      );
    });
    test('episode changed while the sheet was open', () {
      expect(
        danmakuPickAllowed(
          loadedFor: ep3,
          openedFor: ep3,
          playingNow: ep4,
          sessionActive: true,
        ),
        isFalse,
      );
    });
    test('new episode not loaded yet', () {
      expect(
        danmakuPickAllowed(
          loadedFor: null,
          openedFor: ep4,
          playingNow: ep4,
          sessionActive: true,
        ),
        isFalse,
      );
      expect(
        danmakuPickAllowed(
          loadedFor: ep3,
          openedFor: ep4,
          playingNow: ep4,
          sessionActive: true,
        ),
        isFalse,
      );
    });
    test('stale session', () {
      expect(
        danmakuPickAllowed(
          loadedFor: ep3,
          openedFor: ep3,
          playingNow: ep3,
          sessionActive: false,
        ),
        isFalse,
      );
    });
  });
}

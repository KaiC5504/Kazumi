import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/bean/widget/source_quality_badge.dart';

Widget _host(String name) => MaterialApp(
  home: Scaffold(
    body: Center(child: SourceQualityBadge(pluginName: name)),
  ),
);

void main() {
  test('lookup ignores rule-name case', () {
    expect(sourceQualityFor('AGE')?.road, 4);
    expect(sourceQualityFor('DM84')?.video, 3);
    expect(sourceQualityFor('not-a-rule'), isNull);
  });

  testWidgets('measured source shows resolution and road', (tester) async {
    await tester.pumpWidget(_host('dmghg1'));
    expect(find.text('1080p'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
  });

  testWidgets('blocked and unknown sources show a single icon', (tester) async {
    await tester.pumpWidget(_host('baimao'));
    expect(find.byIcon(Icons.block_rounded), findsOneWidget);
    await tester.pumpWidget(_host('LMM'));
    expect(find.byIcon(Icons.help_outline_rounded), findsOneWidget);
  });

  testWidgets('unlisted source renders nothing', (tester) async {
    await tester.pumpWidget(_host('brand-new-rule'));
    expect(find.byType(Icon), findsNothing);
    expect(find.byType(Text), findsNothing);
  });
}

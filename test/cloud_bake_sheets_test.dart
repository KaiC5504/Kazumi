import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/download/cloud_bake_sheets.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_estimate.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_session.dart';
import 'package:kazumi/services/upscale/cloud/runpod_api.dart';
import 'package:mobx/mobx.dart';

void main() {
  CloudBakeQuote quote({bool includeLocal = true}) => CloudBakeQuote(
    recordKey: 'r',
    jobs: const [],
    offer: const CloudOffer(available: true, pricePerHour: 1.2),
    estimate: const CloudBakeEstimate(
      cloudCount: 2,
      localCount: 1,
      cloudSec: 760,
      finishSec: 760,
    ),
    includeLocal: includeLocal,
    height: 1440,
  );

  Future<bool?> pump(WidgetTester tester, CloudBakeQuote q) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(body: CloudBakeConfirmSheet(quote: q)),
        ),
      ),
    );
    return result;
  }

  testWidgets('the confirm sheet shows the split, time and cost', (
    tester,
  ) async {
    await pump(tester, quote());
    expect(find.text('2 集'), findsOneWidget);
    expect(find.text('本机 1 集'), findsOneWidget);
    expect(find.text('13 分钟'), findsOneWidget);
    expect(find.text('\$0.25'), findsOneWidget);
    expect(find.text('最多 \$0.60'), findsOneWidget);
    expect(find.textContaining('L40S 悉尼 \$1.20/小时'), findsOneWidget);
    expect(find.text('开始'), findsOneWidget);
  });

  testWidgets('cloud-only quotes say the laptop sits out', (tester) async {
    await pump(tester, quote(includeLocal: false));
    expect(find.textContaining('本机不参与'), findsOneWidget);
  });

  test('cloud status text per stage', () {
    expect(
      cloudStatusText(
        const CloudEpisodePhase(CloudEpisodeStage.uploading, 0.42),
      ),
      '☁ 上传中 42%',
    );
    expect(
      cloudStatusText(const CloudEpisodePhase(CloudEpisodeStage.waiting)),
      '☁ 等待 GPU',
    );
    expect(
      cloudStatusText(const CloudEpisodePhase(CloudEpisodeStage.baking, 0.5)),
      '☁ 烘焙中 50%',
    );
    expect(
      cloudStatusText(
        const CloudEpisodePhase(CloudEpisodeStage.downloading, 1),
      ),
      '☁ 下载中 100%',
    );
  });

  testWidgets('stop stays available while the laptop finishes the season', (
    tester,
  ) async {
    final session = Observable<CloudBakeSessionView?>(
      CloudBakeSessionView(
        phase: CloudBakePhase.finishing,
        cloudDone: 0,
        localDone: 1,
        failed: 0,
        total: 4,
        startedAt: DateTime.now(),
        pricePerHour: 1.09,
        message: '云端 GPU 启动超时，改用本机烘焙',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CloudBakeBanner(session: session, onStop: () async {}),
        ),
      ),
    );
    final stop = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '停止'),
    );
    expect(stop.onPressed, isNotNull);
    expect(find.text('云端 GPU 启动超时，改用本机烘焙'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

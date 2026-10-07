import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/download/cloud_bake_report.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_session.dart';

void main() {
  CloudJob job(int n, int duration) => CloudJob(
    recordKey: 'r',
    episodeNumber: n,
    durationSec: duration,
    outputPath: 'x',
  );

  final start = DateTime(2026, 10, 8, 2, 40);
  final report = CloudBakeReport(
    startedAt: start,
    endedAt: start.add(const Duration(minutes: 47)),
    podStartedAt: start,
    podEndedAt: start.add(const Duration(minutes: 47)),
    pricePerHour: 1.09,
    encoder: 'hevc_nvenc',
    stopped: false,
    episodes: [
      CloudEpisodeReport(
        job: job(2, 7028),
        outcome: CloudEpisodeOutcome.cloud,
        uploadSec: 180,
        bakeSec: 1740,
        downloadSec: 90,
        outBytes: 2965289941,
      ),
      CloudEpisodeReport(
        job: job(3, 7325),
        outcome: CloudEpisodeOutcome.failed,
        error: '云端烘焙未完成: 上传失败',
      ),
    ],
  );

  testWidgets('the summary shows time, cost and each episode', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CloudBakeReportDialog(
            report: report,
            titleOf: (j) => ('Fate HF', '第 ${j.episodeNumber} 部'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('云端烘焙结束'), findsOneWidget);
    expect(find.text('47 分钟'), findsOneWidget);
    expect(find.text('\$0.85'), findsOneWidget);
    expect(find.text('Fate HF · 第 2 部'), findsOneWidget);
    expect(
      find.textContaining('上传 3 分钟 · 烘焙 29 分钟 · 下载 2 分钟 · 2.97 GB'),
      findsOneWidget,
    );
    expect(find.text('云端烘焙未完成: 上传失败'), findsOneWidget);
    expect(find.textContaining('hevc_nvenc'), findsOneWidget);
    expect(find.textContaining('本机需约 43 分钟'), findsOneWidget);
  });

  test('cost and laptop time come from pod time and media baked', () {
    expect(report.podSec, 47 * 60);
    expect(report.cost, closeTo(47 / 60 * 1.09, 1e-9));
    expect(report.laptopSec, (7028 / 2.7).ceil());
  });
}

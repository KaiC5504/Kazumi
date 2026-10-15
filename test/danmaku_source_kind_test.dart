import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/pages/player/danmaku_source_kind.dart';

import 'support/syncplay_sim.dart' show setUpSyncplayStorage;

DanmakuEntry entry(String source) => DanmakuEntry(
  message: 'x',
  time: 1,
  type: 1,
  color: Colors.white,
  source: source,
);

void main() {
  setUpSyncplayStorage();

  test('classifies like the old filter', () {
    expect(
      DanmakuSourceKind.of(entry('[BiliBili]')),
      DanmakuSourceKind.bilibili,
    );
    expect(DanmakuSourceKind.of(entry('[Gamer]')), DanmakuSourceKind.gamer);
    expect(DanmakuSourceKind.of(entry('')), DanmakuSourceKind.dandan);
    expect(DanmakuSourceKind.of(entry('[AcFun]')), DanmakuSourceKind.dandan);
  });

  test('labels match the Settings page', () {
    expect(DanmakuSourceKind.values.map((k) => k.label), [
      'BiliBili',
      'Gamer',
      '弹弹play',
    ]);
  });

  test('counts per source, zero for missing', () {
    final counts = countDanmakuBySource([
      entry('[BiliBili]'),
      entry('[BiliBili]'),
      entry(''),
    ]);
    expect(counts[DanmakuSourceKind.bilibili], 2);
    expect(counts[DanmakuSourceKind.gamer], 0);
    expect(counts[DanmakuSourceKind.dandan], 1);
  });

  test('only switching a source off clears the screen', () {
    const on = {
      DanmakuSourceKind.bilibili: true,
      DanmakuSourceKind.gamer: true,
      DanmakuSourceKind.dandan: true,
    };
    final bOff = {...on, DanmakuSourceKind.bilibili: false};
    expect(turnedOff(on, bOff), isTrue);
    expect(turnedOff(bOff, on), isFalse);
    expect(turnedOff(on, on), isFalse);
  });
}

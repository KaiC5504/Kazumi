import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/upscale/keep_awake.dart';

void main() {
  test('holds the power request until the last holder releases', () {
    final keepAwake = KeepAwake.instance;
    keepAwake.acquire();
    expect(keepAwake.isHeld, isTrue);

    keepAwake.acquire();
    keepAwake.release();
    expect(keepAwake.isHeld, isTrue);

    keepAwake.release();
    expect(keepAwake.isHeld, isFalse);

    keepAwake.release();
    keepAwake.acquire();
    expect(keepAwake.isHeld, isTrue);
    keepAwake.release();
    expect(keepAwake.isHeld, isFalse);
  }, skip: !Platform.isWindows);
}

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/library/host_router.dart';
import 'package:kazumi/services/library/route_check_store.dart';

void main() {
  final at = DateTime(2026, 10, 7);
  final result = RouteCheckResult(
    chosenHost: 'https://hk.kaic5504.com',
    byHost: const {},
    at: at,
  );

  test('23 runs once, then never again until forced', () async {
    var saved = '';
    var checks = 0;
    RouteCheckStore store() =>
        RouteCheckStore(read: () => saved, write: (s) async => saved = s);
    Future<RouteCheckResult> check() async {
      checks++;
      return result;
    }

    expect(
      (await store().ensure(configured: true, check: check))!.chosenHost,
      result.chosenHost,
    );
    for (var launch = 0; launch < 5; launch++) {
      await store().ensure(configured: true, check: check);
    }
    expect(checks, 1);
    await store().ensure(configured: true, check: check, force: true);
    expect(checks, 2);
  });

  test('not configured: never probes', () async {
    var checks = 0;
    final s = RouteCheckStore(read: () => '', write: (_) async {});
    await s.ensure(
      configured: false,
      check: () async {
        checks++;
        return result;
      },
    );
    expect(checks, 0);
  });

  test(
    'a failed check stores nothing, so the next launch tries again',
    () async {
      var saved = '';
      final s = RouteCheckStore(
        read: () => saved,
        write: (v) async => saved = v,
      );
      await s.ensure(configured: true, check: () async => throw Exception('x'));
      expect(saved, isEmpty);
      expect(s.stored, isNull);
    },
  );

  test('concurrent calls share one check', () async {
    var checks = 0;
    final s = RouteCheckStore(read: () => '', write: (_) async {});
    Future<RouteCheckResult> check() async {
      checks++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return result;
    }

    await Future.wait([
      s.ensure(configured: true, check: check),
      s.ensure(configured: true, check: check, force: true),
    ]);
    expect(checks, 1);
  });
}

import 'package:kazumi/services/library/host_router.dart';
import 'package:kazumi/services/logging/logger.dart';

/// The route check runs once and is remembered; only 重新测速 runs it again.
class RouteCheckStore {
  RouteCheckStore({required this.read, required this.write});

  final String Function() read;
  final Future<void> Function(String) write;
  Future<RouteCheckResult?>? _inFlight;
  int runs = 0;

  RouteCheckResult? get stored => RouteCheckResult.decode(read());

  Future<RouteCheckResult?> ensure({
    required bool configured,
    required Future<RouteCheckResult> Function() check,
    bool force = false,
  }) {
    if (!configured) return Future.value(stored);
    if (!force && stored != null) return Future.value(stored);
    return _inFlight ??= _run(check).whenComplete(() => _inFlight = null);
  }

  Future<RouteCheckResult?> _run(
    Future<RouteCheckResult> Function() check,
  ) async {
    runs++;
    try {
      final result = await check();
      await write(result.encode());
      KazumiLogger().i('RouteCheck: chose ${result.chosenHost}');
      return result;
    } catch (e) {
      KazumiLogger().w('RouteCheck: failed, staying on HK', error: e);
      return null;
    }
  }
}

import 'dart:async';
import 'dart:io';

class _Pair {
  _Pair(this.client, this.upstream);
  final Socket client;
  final Socket upstream;
  bool silent = false;

  void destroy() {
    client.destroy();
    upstream.destroy();
  }
}

/// Loopback proxy in front of a real server. zombieExisting() silences the
/// current connections both ways without closing them, like a phone that
/// switched networks; new connections still work.
class TcpProxy {
  TcpProxy._(this._server, this._target);

  final ServerSocket _server;
  final int _target;
  final List<_Pair> _pairs = [];

  int get port => _server.port;

  static Future<TcpProxy> start(int targetPort) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = TcpProxy._(server, targetPort);
    server.listen(proxy._accept);
    return proxy;
  }

  Future<void> _accept(Socket client) async {
    final upstream = await Socket.connect(
      InternetAddress.loopbackIPv4,
      _target,
    );
    final pair = _Pair(client, upstream);
    _pairs.add(pair);
    // Either side hanging up mid-write is expected once a pair is torn down.
    client.done.catchError((_) {});
    upstream.done.catchError((_) {});
    // A silenced pair doesn't pass a close on either: the phone's FIN goes
    // out on a network that no longer reaches the server.
    void closeUpstream([_]) {
      if (!pair.silent) upstream.destroy();
    }

    void closeClient([_]) {
      if (!pair.silent) client.destroy();
    }

    client.listen(
      (d) {
        if (!pair.silent) upstream.add(d);
      },
      onDone: closeUpstream,
      onError: closeUpstream,
    );
    upstream.listen(
      (d) {
        if (!pair.silent) client.add(d);
      },
      onDone: closeClient,
      onError: closeClient,
    );
  }

  void zombieExisting() {
    for (final p in _pairs) {
      p.silent = true;
    }
  }

  /// The kernel finally gives up on the dead peer.
  void killGhosts() {
    for (final p in _pairs.where((p) => p.silent).toList()) {
      p.destroy();
      _pairs.remove(p);
    }
  }

  Future<void> close() async {
    for (final p in _pairs) {
      p.destroy();
    }
    _pairs.clear();
    await _server.close();
  }
}

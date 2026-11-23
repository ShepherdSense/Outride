/// Feed server — dart:io implementation (native Android/Windows).
/// The web build compiles the stub instead (dart:io is unavailable
/// there). See feed_server.dart for the protocol.
library;

import 'dart:convert';
import 'dart:io';

import 'experimental_build.dart';

/// Default feed-server port (LAN-reachable; next to the UDP 49160/
/// 49161/49162 family, deliberately distinct from all of them).
const int kFeedServerPort = 49163;

/// Serves the live feed over HTTP + WebSocket. One instance per app.
class FeedServer {
  HttpServer? _server;
  final Set<WebSocket> _clients = {};
  Future<String> Function(Map<String, dynamic>)? _onRecordStart;
  Future<String> Function()? _onRecordStop;

  bool get isServing => _server != null;

  int get clientCount => _clients.length;

  int get port => _server?.port ?? kFeedServerPort;

  String get addressLabel =>
      isServing ? '0.0.0.0:$port (LAN)' : 'off';

  /// Start serving. Returns the address label, or an error string
  /// starting with `ERROR:` (never throws — a busy port surfaces,
  /// it never crashes the app).
  Future<String> start({
    required Future<String> Function(Map<String, dynamic>) onRecordStart,
    required Future<String> Function() onRecordStop,
    int port = kFeedServerPort,
  }) async {
    if (isServing) return addressLabel;
    _onRecordStart = onRecordStart;
    _onRecordStop = onRecordStop;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _server!.listen(_handleRequest);
      return addressLabel;
    } catch (e) {
      _server = null;
      return 'ERROR: feed server failed to start: $e';
    }
  }

  /// Stop serving (closes the socket and all clients). Never throws.
  Future<void> stop() async {
    for (final c in _clients.toList()) {
      try {
        await c.close();
      } catch (_) {}
    }
    _clients.clear();
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
  }

  /// Broadcast one snapshot to all connected web clients. No-op
  /// when nobody is connected. Never throws.
  void broadcastSnapshot(Map<String, dynamic> snapshot) {
    if (_clients.isEmpty) return;
    final text = jsonEncode(snapshot);
    for (final c in _clients.toList()) {
      try {
        c.add(text);
      } catch (_) {
        _clients.remove(c);
      }
    }
  }

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      if (req.uri.path == '/status') {
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'ok': true,
            'app_version': kExperimentalVersion,
            'mode': 'live',
            'recording': _recording,
            'clients': _clients.length,
          }));
        await req.response.close();
        return;
      }
      if (req.uri.path == '/feed' &&
          WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        _clients.add(ws);
        ws.add(jsonEncode({
          'type': 'hello',
          'app_version': kExperimentalVersion,
          'mode': 'live',
          'recording': _recording,
        }));
        ws.listen(
          (msg) => _handleMessage(ws, msg),
          onDone: () => _clients.remove(ws),
          onError: (_) => _clients.remove(ws),
          cancelOnError: true,
        );
        return;
      }
      req.response
        ..statusCode = HttpStatus.notFound
        ..write('Outride experimental feed server — /status or /feed');
      await req.response.close();
    } catch (_) {
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  // Set by AppState each snapshot (single-writer: the poller).
  bool _recording = false;
  set recording(bool v) => _recording = v;

  Future<void> _handleMessage(WebSocket ws, dynamic msg) async {
    Map<String, dynamic>? j;
    try {
      j = jsonDecode('$msg') as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final id = j['id'];
    final cmd = '${j['cmd'] ?? ''}';
    void reply(Map<String, dynamic> m) {
      try {
        ws.add(jsonEncode(m));
      } catch (_) {}
    }

    switch (cmd) {
      case 'ping':
        reply({'type': 'pong', 'id': id});
        return;
      case 'record_status':
        reply({
          'type': 'record_status',
          'id': id,
          'recording': _recording,
        });
        return;
      case 'record_start':
        final handler = _onRecordStart;
        if (handler == null) {
          reply({
            'type': 'record_result',
            'id': id,
            'ok': false,
            'summary': 'record start not wired on this node',
          });
          return;
        }
        final summary = await handler(j);
        // Contract with the AppState handler: a summary starting
        // with 'ERROR' means the start failed; anything else is the
        // session file path and recording is live.
        final ok = summary.isNotEmpty && !summary.startsWith('ERROR');
        _recording = ok;
        reply({
          'type': 'record_result',
          'id': id,
          'ok': ok,
          'summary': summary,
        });
        return;
      case 'record_stop':
        final handler = _onRecordStop;
        if (handler == null) {
          reply({
            'type': 'record_result',
            'id': id,
            'ok': false,
            'summary': 'record stop not wired on this node',
          });
          return;
        }
        final summary = await handler();
        _recording = false;
        reply({
          'type': 'record_result',
          'id': id,
          'ok': !summary.startsWith('STOP FAILED'),
          'summary': summary,
        });
        return;
      default:
        reply({
          'type': 'error',
          'id': id,
          'summary': 'unknown cmd: $cmd',
        });
    }
  }
}

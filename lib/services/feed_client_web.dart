/// Feed client — web implementation (dart:html WebSocket). See
/// feed_client.dart for the contract. Same API as the io build.
///
/// NOTE: dart:html is deprecated in favor of package:web, but
/// package:web would be a NEW dependency (needs review), and this
/// build adds none. The ignore below is deliberate, not accidental:
/// this file compiles only for the web build, where dart:html
/// WebSocket is the zero-dependency route.
library;

import 'dart:async';
import 'dart:convert';
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/foundation.dart';

/// Explicit connection states (see feed_client.dart).
enum FeedState { disconnected, connecting, connected, unreachable }

/// WebSocket client to one mesh node's feed server (browser side).
class FeedClient extends ChangeNotifier {
  html.WebSocket? _ws;
  Timer? _connectTimer;
  FeedState _state = FeedState.disconnected;
  String? _lastError;
  String? _connectedTo;
  Map<String, dynamic>? _latestSnapshot;
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};

  FeedState get state => _state;

  String? get lastError => _lastError;

  String? get connectedTo => _connectedTo;

  Map<String, dynamic>? get latestSnapshot => _latestSnapshot;

  bool get isConnected => _state == FeedState.connected;

  /// Connect to `host:port` (e.g. `192.168.1.10:49163`). Never
  /// throws — failures land in [state] = unreachable + [lastError].
  /// Note: the web build is served over plain local HTTP, so ws://
  /// works; over HTTPS the browser would block ws:// (use wss://).
  /// A connect that never opens times out after ~10 s (mirroring
  /// the io client) instead of sitting on "connecting" forever.
  Future<void> connect(String hostPort) async {
    await disconnect();
    _setState(FeedState.connecting);
    _lastError = null;
    try {
      final ws = html.WebSocket('ws://$hostPort/feed');
      _ws = ws;
      _connectedTo = hostPort;
      _connectTimer?.cancel();
      _connectTimer = Timer(const Duration(seconds: 10), () {
        if (_ws == ws && _state == FeedState.connecting) {
          _drop('could not reach $hostPort — connect timed out '
              'after 10 s');
        }
      });
      ws.onOpen.listen((_) {
        if (_ws == ws) {
          _connectTimer?.cancel();
          _setState(FeedState.connected);
        }
      });
      ws.onMessage.listen((e) {
        if (_ws == ws) _onMessage(e.data);
      });
      ws.onError.listen((_) {
        if (_ws == ws) {
          _drop('could not reach $hostPort — is the node serving '
              'its feed on port 49163?');
        }
      });
      ws.onClose.listen((_) {
        if (_ws == ws) _drop('feed connection closed by the node');
      });
      // onOpen fires async; the connecting state stands until then.
      // A connect that never opens hits the 10 s timer above — the
      // UI shows the connecting state, never fake data.
    } catch (e) {
      _lastError = 'could not reach $hostPort: $e';
      _setState(FeedState.unreachable);
    }
  }

  /// Disconnect (user action). Never throws.
  Future<void> disconnect() async {
    _connectTimer?.cancel();
    _connectTimer = null;
    try {
      _ws?.close();
    } catch (_) {}
    _ws = null;
    _connectedTo = null;
    _latestSnapshot = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.complete({'ok': false, 'summary': 'disconnected'});
      }
    }
    _pending.clear();
    if (_state != FeedState.disconnected) {
      _setState(FeedState.disconnected);
    }
  }

  /// Send a record_start command; returns {ok, summary}. The
  /// recording lands on the ingesting device, never in the browser.
  Future<Map<String, dynamic>> sendRecordStart(
      Map<String, dynamic> config) {
    return _request({'cmd': 'record_start', ...config});
  }

  /// Send a record_stop command; returns {ok, summary}.
  Future<Map<String, dynamic>> sendRecordStop() {
    return _request({'cmd': 'record_stop'});
  }

  Future<Map<String, dynamic>> _request(Map<String, dynamic> msg) async {
    final ws = _ws;
    if (_state != FeedState.connected || ws == null) {
      return {
        'ok': false,
        'summary': 'not connected to a feed source',
      };
    }
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    try {
      ws.sendString(jsonEncode({'id': id, ...msg}));
    } catch (e) {
      _pending.remove(id);
      return {'ok': false, 'summary': 'send failed: $e'};
    }
    try {
      return await c.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      _pending.remove(id);
      return {'ok': false, 'summary': 'no reply from the node (15 s)'};
    }
  }

  void _onMessage(dynamic data) {
    Map<String, dynamic>? j;
    try {
      j = jsonDecode('$data') as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = '${j['type'] ?? ''}';
    if (type == 'snapshot') {
      _latestSnapshot = j;
      notifyListeners();
      return;
    }
    final id = j['id'];
    if (id is int && _pending.containsKey(id)) {
      final c = _pending.remove(id)!;
      if (!c.isCompleted) {
        c.complete({
          'ok': j['ok'] == true,
          'summary': '${j['summary'] ?? ''}',
        });
      }
    }
  }

  void _drop(String reason) {
    _connectTimer?.cancel();
    _connectTimer = null;
    _ws = null;
    _connectedTo = null;
    _latestSnapshot = null;
    _lastError = reason;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.complete({'ok': false, 'summary': reason});
      }
    }
    _pending.clear();
    _setState(FeedState.unreachable);
  }

  void _setState(FeedState s) {
    _state = s;
    notifyListeners();
  }
}

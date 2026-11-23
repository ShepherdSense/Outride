/// Feed client — dart:io implementation (native; also usable in
/// tests). See feed_client.dart for the contract.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Explicit connection states (see feed_client.dart).
enum FeedState { disconnected, connecting, connected, unreachable }

/// WebSocket client to one mesh node's feed server.
class FeedClient extends ChangeNotifier {
  WebSocket? _ws;
  StreamSubscription<dynamic>? _sub;
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
  Future<void> connect(String hostPort) async {
    await disconnect();
    _setState(FeedState.connecting);
    _lastError = null;
    try {
      _ws = await WebSocket.connect('ws://$hostPort/feed')
          .timeout(const Duration(seconds: 10));
      _connectedTo = hostPort;
      _sub = _ws!.listen(
        _onMessage,
        onDone: () => _drop('feed connection closed by the node'),
        onError: (e) => _drop('feed connection error: $e'),
        cancelOnError: true,
      );
      _setState(FeedState.connected);
    } catch (e) {
      _lastError = 'could not reach $hostPort: $e';
      _setState(FeedState.unreachable);
    }
  }

  /// Disconnect (user action). Never throws.
  Future<void> disconnect() async {
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    try {
      await _ws?.close();
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
      ws.add(jsonEncode({'id': id, ...msg}));
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
    _ws = null;
    _sub = null;
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

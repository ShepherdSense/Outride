/// Feed server / client tests (feed_server_io.dart,
/// feed_client_io.dart): handshake, snapshot flow, record
/// command round-trip, unreachable state.
///
/// NOTE: these tests drive the real dart:io server + WebSocket
/// client on a loopback ephemeral port. No browser is involved;
/// the live-browser check is a remaining step for the parent.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/feed_client.dart';
import 'package:outride/services/feed_server.dart';

void main() {
  group('FeedServer (dart:io)', () {
    test('hello, /status, snapshot, record round-trip', () async {
      final server = FeedServer();
      final started = await server.start(
        onRecordStart: (_) async => '/docs/bench_sessions/test.csv',
        onRecordStop: () async => 'ok: stopped',
        port: 0,
      );
      expect(started, isNot(startsWith('ERROR')));
      final port = server.port;
      expect(port, greaterThan(0));
      addTearDown(server.stop);

      // /status over plain HTTP.
      final http = HttpClient();
      final statusReq = await http.get('127.0.0.1', port, '/status');
      final statusRes = await statusReq.close();
      expect(statusRes.statusCode, HttpStatus.ok);
      final statusBody =
          jsonDecode(await statusRes.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      expect(statusBody['ok'], isTrue);
      expect(statusBody['app_version'], '0.29.7-experimental');
      expect(statusBody['mode'], 'live');
      http.close();

      // WebSocket handshake + hello.
      final socket =
          await WebSocket.connect('ws://127.0.0.1:$port/feed');
      addTearDown(socket.close);
      final messages = <Map<String, dynamic>>[];
      final sub = socket.listen((data) {
        messages.add(jsonDecode(data as String) as Map<String, dynamic>);
      });
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(messages, isNotEmpty);
      final hello = messages.first;
      expect(hello['type'], 'hello');
      expect(hello['app_version'], '0.29.7-experimental');
      expect(hello['mode'], 'live');

      // Snapshot broadcast reaches the client.
      server.broadcastSnapshot({'type': 'snapshot', 'links': []});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(messages.any((m) => m['type'] == 'snapshot'), isTrue);

      // Record start/stop round-trip (cmd-based protocol).
      socket.add(jsonEncode({
        'id': 1,
        'cmd': 'record_start',
        'label': 't1',
      }));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final startResult = messages.lastWhere(
          (m) => m['type'] == 'record_result',
          orElse: () => <String, dynamic>{});
      expect(startResult['ok'], isTrue);
      expect(startResult['summary'], contains('bench_sessions'));

      socket.add(jsonEncode({'id': 2, 'cmd': 'record_stop'}));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final stopResult = messages.lastWhere(
          (m) => m['type'] == 'record_result',
          orElse: () => <String, dynamic>{});
      expect(stopResult['ok'], isTrue);
      expect(stopResult['summary'], contains('stopped'));

      // Unknown command gets an explicit error reply, not a hang.
      socket.add(jsonEncode({'id': 3, 'cmd': 'bogus'}));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final errResult = messages.lastWhere(
          (m) => m['type'] == 'error',
          orElse: () => <String, dynamic>{});
      expect(errResult['summary'], contains('unknown cmd'));
    });
  });

  group('FeedClient (dart:io)', () {
    test('connects to a live server, snapshots flow', () async {
      final server = FeedServer();
      await server.start(
        onRecordStart: (_) async => '/docs/bench_sessions/test.csv',
        onRecordStop: () async => 'ok: stopped',
        port: 0,
      );
      addTearDown(server.stop);
      final client = FeedClient();
      addTearDown(client.disconnect);
      await client.connect('127.0.0.1:${server.port}');
      expect(client.state, FeedState.connected);
      expect(client.lastError, isNull);
      // Hello is not a snapshot; the first snapshot arrives on
      // broadcast.
      server.broadcastSnapshot({'type': 'snapshot', 'links': []});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(client.latestSnapshot, isNotNull);
      expect(client.latestSnapshot!['type'], 'snapshot');

      // Record commands go through the feed and come back.
      final start = await client.sendRecordStart({'label': 't1'});
      expect(start['ok'], isTrue);
      final stop = await client.sendRecordStop();
      expect(stop['ok'], isTrue);

      // Disconnect clears the last snapshot — a stale snapshot
      // must never be rendered as if it were live data.
      await client.disconnect();
      expect(client.latestSnapshot, isNull);
    });

    test('feed drop clears the last snapshot', () async {
      final server = FeedServer();
      await server.start(
        onRecordStart: (_) async => '/docs/bench_sessions/test.csv',
        onRecordStop: () async => 'ok: stopped',
        port: 0,
      );
      addTearDown(server.stop);
      final client = FeedClient();
      addTearDown(client.disconnect);
      await client.connect('127.0.0.1:${server.port}');
      server.broadcastSnapshot({'type': 'snapshot', 'links': []});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(client.latestSnapshot, isNotNull);
      await server.stop();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(client.latestSnapshot, isNull);
      expect(client.state, FeedState.unreachable);
    });

    test('unreachable host → unreachable state with a reason, '
        'never silent simulated data', () async {
      final client = FeedClient();
      addTearDown(client.disconnect);
      // Port 1 on loopback: nothing listens there.
      await client.connect('127.0.0.1:1');
      expect(client.state, FeedState.unreachable);
      expect(client.lastError, isNotNull);
      expect(client.lastError, isNotEmpty);
      expect(client.latestSnapshot, isNull);
    });
  });
}

/// Fleet chat tests (design note: research_notes/outride-fleet-chat.md).
///
/// Codec: message/ack round-trip, strict parsing of malformed
/// payloads, text validation, overall-delivery derivation.
///
/// Service: two and three fake-transport services wired through a
/// fake mesh (no sockets bound here — the send path is the injected
/// sink and inbound datagrams are driven through [handleHubText]
/// directly). Fleet broadcast reaches every peer, a DM reaches only
/// its peer, dedup drops a retried copy, a dropped ack is retried
/// and then lands, retries exhaust to FAILED and a manual retry
/// recovers, a peer with no session yet is named (not silently
/// dropped) and delivers once its session appears, inbound
/// per-peer rate caps hold, tampered / misaddressed / wrong-sender
/// envelopes are dropped, zero peers fails honestly, and the
/// outbound 500 ms pacing holds.
///
/// Widget: the chat screen's not-in-fleet state, and the Fleet
/// screen's OPEN CHAT button opening the thread list (real
/// AppState, mocked prefs + secure storage — same pattern as
/// fleet_screen_test.dart).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:outride/screens/fleet_chat_screen.dart';
import 'package:outride/screens/fleet_screen.dart';
import 'package:outride/services/fleet_chat.dart';
import 'package:outride/services/fleet_chat_service.dart';
import 'package:outride/services/fleet_crypto.dart';
import 'package:outride/services/fleet_dialer.dart';
import 'package:outride/services/fleet_service.dart';
import 'package:outride/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fleetId = '0123456789abcdef0123456789abcdef';
const _fleetIdB = 'fedcba9876543210fedcba9876543210';
const _nodeA = 'aaaaaaaaaaaaaaaa';
const _nodeB = 'bbbbbbbbbbbbbbbb';
const _nodeC = 'cccccccccccccccc';

FleetPeer _peer(String nodeId, String address) => FleetPeer(
      nodeId: nodeId,
      callsign: 'OUTRIDE-${nodeId.substring(0, 4).toUpperCase()}',
      fleetId: _fleetId,
      hasSilvus: false,
      memberCount: 3,
      lastSeen: DateTime.utc(2026, 11, 19, 22),
      address: address,
    );

/// A fake mesh: delivers envelopes between services by address.
/// No sockets. Optionally drops acks (to exercise retry) and
/// records every delivery for pacing assertions.
class _FakeMesh {
  _FakeMesh(this.pairKeys);

  /// Session key per ordered pair, `'$from>$to'`.
  final Map<String, List<int>> pairKeys;
  final Map<String, FleetChatService> _byNode = {};
  final Map<String, String> _addressToNode = {};
  final List<Map<String, dynamic>> delivered = [];
  bool dropAcks = false;

  void register(String nodeId, String address, FleetChatService svc) {
    _byNode[nodeId] = svc;
    _addressToNode[address] = nodeId;
  }

  Future<void> deliver(
      Map<String, dynamic> envelope, String address) async {
    final toNode = _addressToNode[address];
    final svc = toNode == null ? null : _byNode[toNode];
    if (svc == null) return;
    if (dropAcks && await _isAck(envelope, toNode!)) return;
    delivered.add(envelope);
    await svc.handleHubText(jsonEncode(envelope));
  }

  Future<bool> _isAck(Map<String, dynamic> envelope, String toNode) async {
    try {
      final fromNode = '${envelope['from_node'] ?? ''}';
      final key = pairKeys['$fromNode>$toNode'];
      if (key == null) return false;
      final inner = await fleetDecryptEnvelope(
        envelope,
        sessionKey: key,
        expectedFleetId: _fleetId,
        seenNonces: <String>{},
      );
      if (inner == null) return false;
      final decoded = jsonDecode(inner);
      return decoded is Map<String, dynamic> &&
          decoded['type'] == 'fleet_chat_ack';
    } catch (_) {
      return false;
    }
  }
}

FleetChatService _makeService({
  required String nodeId,
  required List<FleetPeer> peers,
  required Map<String, List<int>> sessions,
  required _FakeMesh mesh,
  required DateTime Function() now,
  bool inFleet = true,
  String? fleetId,
  String? Function()? fleetIdFn,
}) {
  return FleetChatService(
    ownNodeId: () async => nodeId,
    ownCallsign: () => 'OUTRIDE-${nodeId.substring(0, 4).toUpperCase()}',
    fleetId: fleetIdFn ?? () => fleetId ?? _fleetId,
    inFleet: () => inFleet,
    peers: () => peers,
    sessions: () => sessions,
    now: now,
    sendEnvelope: (envelope, address) => mesh.deliver(envelope, address),
  );
}

void main() {
  group('FleetChat codec', () {
    test('fleet message round-trips', () {
      final json = fleetChatMessageToJson(
        msgId: '0123456789abcdef0123456789abcdef',
        channel: 'fleet',
        fromNode: _nodeA,
        fromCallsign: 'OUTRIDE-AAAA',
        seq: 3,
        tMs: 1700000000000,
        text: 'Hold at the treeline.',
      );
      final msg = fleetChatMessageTryParse(json, ourNodeId: _nodeB);
      expect(msg, isNotNull);
      expect(msg!.id, '0123456789abcdef0123456789abcdef');
      expect(msg.threadId, fleetChatThreadFleet);
      expect(msg.fromNode, _nodeA);
      expect(msg.fromCallsign, 'OUTRIDE-AAAA');
      expect(msg.seq, 3);
      expect(msg.text, 'Hold at the treeline.');
      expect(msg.outgoing, isFalse);
    });

    test('DM round-trips for its peer, dropped for anyone else', () {
      final json = fleetChatMessageToJson(
        msgId: '0123456789abcdef0123456789abcdef',
        channel: 'dm',
        toNode: _nodeB,
        fromNode: _nodeA,
        fromCallsign: 'OUTRIDE-AAAA',
        seq: 1,
        tMs: 1700000000000,
        text: 'Eyes on the north gate only.',
      );
      expect(json['to_node'], _nodeB);
      final forB = fleetChatMessageTryParse(json, ourNodeId: _nodeB);
      expect(forB, isNotNull);
      expect(forB!.threadId, fleetChatDmThread(_nodeA));
      final forC = fleetChatMessageTryParse(json, ourNodeId: _nodeC);
      expect(forC, isNull);
    });

    test('malformed payloads are all rejected, never thrown', () {
      Map<String, dynamic> base() => fleetChatMessageToJson(
            msgId: '0123456789abcdef0123456789abcdef',
            channel: 'fleet',
            fromNode: _nodeA,
            fromCallsign: 'OUTRIDE-AAAA',
            seq: 1,
            tMs: 1700000000000,
            text: 'ok',
          );
      final bad = <Map<String, dynamic>>[
        {...base(), 'v': 2},
        {...base(), 'msg_id': 'short'},
        {...base(), 'msg_id': 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'},
        {...base(), 'channel': 'group'},
        {...base(), 'from_node': 'xyz'},
        {...base(), 'from_callsign': ''},
        {...base(), 'text': ''},
        {...base(), 'text': 'x' * 1001},
        {...base(), 't': -1},
        {...base(), 'seq': 0},
        {...base(), 'type': 'fleet_chat_ack'},
        {
          ...base(),
          'channel': 'dm',
          // DM with no to_node.
        },
        {
          ...base(),
          'channel': 'dm',
          'to_node': 'bad',
        },
        {'type': 'fleet_chat'},
        {'type': 'fleet_chat', 'v': 1, 'msg_id': 'x'},
      ];
      for (final j in bad) {
        expect(fleetChatMessageTryParse(j, ourNodeId: _nodeB), isNull,
            reason: 'should reject $j');
      }
      // A fleet message must not carry to_node.
      expect(
          fleetChatMessageTryParse(
              {...base(), 'to_node': _nodeB}, ourNodeId: _nodeB),
          isNull);
    });

    test('ack round-trips; malformed acks rejected', () {
      final json = fleetChatAckToJson(
        msgId: '0123456789abcdef0123456789abcdef',
        channel: 'dm',
        fromNode: _nodeB,
        tMs: 1700000000000,
      );
      final ack = fleetChatAckTryParse(json);
      expect(ack, isNotNull);
      expect(ack!.msgId, '0123456789abcdef0123456789abcdef');
      expect(ack.channel, 'dm');
      expect(ack.fromNode, _nodeB);
      expect(fleetChatAckTryParse({...json, 'msg_id': 'short'}), isNull);
      expect(fleetChatAckTryParse({...json, 'channel': 'x'}), isNull);
      expect(fleetChatAckTryParse({...json, 'from_node': 'zz'}), isNull);
      expect(fleetChatAckTryParse({'type': 'fleet_chat_ack'}), isNull);
    });

    test('text validation: empty rejected, 1000 ok, 1001 rejected', () {
      expect(fleetChatTextError(''), isNotNull);
      expect(fleetChatTextError('   '), isNotNull);
      expect(fleetChatTextError('x' * 1000), isNull);
      expect(fleetChatTextError('x' * 1001), isNotNull);
    });

    test('overall delivery derivation', () {
      FleetChatMessage msgWith(Map<String, FleetChatPeerState> states) =>
          FleetChatMessage(
            id: '0123456789abcdef0123456789abcdef',
            threadId: 'fleet',
            fromNode: _nodeA,
            fromCallsign: 'OUTRIDE-AAAA',
            text: 't',
            sentAt: DateTime.utc(2026, 11, 19, 22),
            seq: 1,
            outgoing: true,
            peerStates: states,
          );
      expect(msgWith({}).overall, FleetChatOverall.failed);
      expect(
          msgWith({_nodeB: FleetChatPeerState.acked}).overall,
          FleetChatOverall.sent);
      expect(
          msgWith({_nodeB: FleetChatPeerState.pending}).overall,
          FleetChatOverall.sending);
      expect(
          msgWith({
            _nodeB: FleetChatPeerState.acked,
            _nodeC: FleetChatPeerState.pending,
          }).overall,
          FleetChatOverall.sending);
      expect(
          msgWith({
            _nodeB: FleetChatPeerState.acked,
            _nodeC: FleetChatPeerState.failed,
          }).overall,
          FleetChatOverall.partial);
      expect(
          msgWith({
            _nodeB: FleetChatPeerState.failed,
            _nodeC: FleetChatPeerState.gone,
          }).overall,
          FleetChatOverall.failed);
      expect(
          msgWith({_nodeB: FleetChatPeerState.noSession}).overall,
          // No peer acked and none pending: failed. (While retries
          // are still scheduled the service reports SENDING… via
          // overallFor; the pure getter only sees the final state.)
          FleetChatOverall.failed);
    });

    test('thread helpers', () {
      expect(fleetChatThreadFleet, 'fleet');
      expect(fleetChatDmThread(_nodeB), 'dm:$_nodeB');
      expect(fleetChatIsDmThread('dm:$_nodeB'), isTrue);
      expect(fleetChatIsDmThread('fleet'), isFalse);
      expect(fleetChatDmPeer('dm:$_nodeB'), _nodeB);
      expect(fleetChatDmPeer('fleet'), isNull);
      expect(fleetChatRandomId(), matches(RegExp(r'^[0-9a-f]{32}$')));
    });
  });

  group('FleetChatService over a fake mesh', () {
    late DateTime now;
    late List<int> keyAB;
    late List<int> keyAC;
    late List<int> keyBC;
    late _FakeMesh mesh;
    late FleetChatService a;
    late FleetChatService b;
    late FleetChatService c;
    late Map<String, List<int>> sessionsA;
    late Map<String, List<int>> sessionsB;
    late Map<String, List<int>> sessionsC;

    setUp(() async {
      now = DateTime.utc(2026, 11, 19, 22);
      keyAB = List<int>.generate(32, (i) => i + 1);
      keyAC = List<int>.generate(32, (i) => i + 101);
      keyBC = List<int>.generate(32, (i) => i + 201);
      mesh = _FakeMesh({
        '$_nodeA>$_nodeB': keyAB,
        '$_nodeB>$_nodeA': keyAB,
        '$_nodeA>$_nodeC': keyAC,
        '$_nodeC>$_nodeA': keyAC,
        '$_nodeB>$_nodeC': keyBC,
        '$_nodeC>$_nodeB': keyBC,
      });
      sessionsA = {_nodeB: keyAB, _nodeC: keyAC};
      sessionsB = {_nodeA: keyAB, _nodeC: keyBC};
      sessionsC = {_nodeA: keyAC, _nodeB: keyBC};
      a = _makeService(
        nodeId: _nodeA,
        peers: [_peer(_nodeB, '10.0.0.2'), _peer(_nodeC, '10.0.0.3')],
        sessions: sessionsA,
        mesh: mesh,
        now: () => now,
      );
      b = _makeService(
        nodeId: _nodeB,
        peers: [_peer(_nodeA, '10.0.0.1'), _peer(_nodeC, '10.0.0.3')],
        sessions: sessionsB,
        mesh: mesh,
        now: () => now,
      );
      c = _makeService(
        nodeId: _nodeC,
        peers: [_peer(_nodeA, '10.0.0.1'), _peer(_nodeB, '10.0.0.2')],
        sessions: sessionsC,
        mesh: mesh,
        now: () => now,
      );
      mesh.register(_nodeA, '10.0.0.1', a);
      mesh.register(_nodeB, '10.0.0.2', b);
      mesh.register(_nodeC, '10.0.0.3', c);
      await a.start();
      await b.start();
      await c.start();
    });

    tearDown(() {
      a.dispose();
      b.dispose();
      c.dispose();
    });

    test('fleet broadcast reaches every peer and acks to SENT', () async {
      final result = await a.sendFleet('Hold at the treeline.');
      expect(result.ok, isTrue);
      expect(result.message, isNotNull);
      await a.pumpForTest();
      expect(b.messagesFor('fleet'), hasLength(1));
      expect(b.messagesFor('fleet').single.text, 'Hold at the treeline.');
      expect(c.messagesFor('fleet'), hasLength(1));
      expect(b.unreadCount('fleet'), 1);
      expect(c.unreadCount('fleet'), 1);
      // Acks flow back through the mesh on delivery.
      expect(a.overallFor(result.message!), FleetChatOverall.sent);
      expect(a.pendingCountForTest, 0);
    });

    test('DM reaches only its peer', () async {
      final result = await a.sendDm(_nodeB, 'Eyes on the north gate only.');
      expect(result.ok, isTrue);
      await a.pumpForTest();
      expect(b.messagesFor('dm:$_nodeA'), hasLength(1));
      expect(b.messagesFor('dm:$_nodeA').single.text,
          'Eyes on the north gate only.');
      expect(c.messagesFor('dm:$_nodeA'), isEmpty);
      expect(c.threadIdsWithMessages, isEmpty);
      expect(a.overallFor(result.message!), FleetChatOverall.sent);
    });

    test('DM to a peer who left the fleet fails honestly', () async {
      final svc = _makeService(
        nodeId: _nodeA,
        peers: [_peer(_nodeB, '10.0.0.2')],
        sessions: sessionsA,
        mesh: mesh,
        now: () => now,
      );
      await svc.start();
      addTearDown(svc.dispose);
      // Peer B is in the list but the test removes it before send:
      // emulate by sending to a node id that is not a peer at all.
      final result = await svc.sendDm(_nodeC, 'Are you there?');
      expect(result.ok, isFalse);
      expect(result.reason, contains('LEFT THE FLEET'));
      expect(result.message, isNotNull);
      expect(svc.overallFor(result.message!), FleetChatOverall.failed);
    });

    test('duplicate delivery is acked again but displayed once', () async {
      await a.sendFleet('Say again, over.');
      await a.pumpForTest();
      expect(b.messagesFor('fleet'), hasLength(1));
      // Re-deliver the exact envelope: a retry whose first copy
      // already landed.
      final envelope = mesh.delivered.first;
      await b.handleHubText(jsonEncode(envelope));
      expect(b.messagesFor('fleet'), hasLength(1));
      expect(b.unreadCount('fleet'), 1);
    });

    test('dropped ack retries, dedups, then lands as SENT', () async {
      mesh.dropAcks = true;
      final result = await a.sendFleet('Radio check.');
      await a.pumpForTest();
      expect(b.messagesFor('fleet'), hasLength(1));
      expect(c.messagesFor('fleet'), hasLength(1));
      expect(a.overallFor(result.message!), FleetChatOverall.sending);
      // First retry at +2 s: still dropped, still one copy each.
      now = now.add(const Duration(seconds: 2));
      await a.pumpForTest();
      expect(b.messagesFor('fleet'), hasLength(1));
      expect(c.messagesFor('fleet'), hasLength(1));
      expect(a.overallFor(result.message!), FleetChatOverall.sending);
      // Acks flow again: second retry at +4 s, acks land.
      mesh.dropAcks = false;
      now = now.add(const Duration(seconds: 4));
      await a.pumpForTest();
      expect(b.messagesFor('fleet'), hasLength(1));
      expect(c.messagesFor('fleet'), hasLength(1));
      expect(a.overallFor(result.message!), FleetChatOverall.sent);
      expect(a.pendingCountForTest, 0);
    });

    test('retries exhaust to FAILED; manual retry recovers to SENT',
        () async {
      mesh.dropAcks = true;
      final result = await a.sendFleet('Anybody copy?');
      await a.pumpForTest();
      // Retries at +2, +4, +8 s; the pump after the 3rd retry
      // finalizes the message.
      for (final gap in [2, 4, 8, 1]) {
        now = now.add(Duration(seconds: gap));
        await a.pumpForTest();
      }
      expect(a.overallFor(result.message!), FleetChatOverall.failed);
      expect(a.pendingCountForTest, 0);
      // Manual retry with acks flowing again. The retry job needs
      // its 500 ms pacing window before the pump drains it.
      mesh.dropAcks = false;
      await a.retryMessage('fleet', result.message!.id);
      now = now.add(const Duration(milliseconds: 500));
      await a.pumpForTest();
      expect(a.overallFor(result.message!), FleetChatOverall.sent);
      expect(b.messagesFor('fleet'), hasLength(1));
    });

    test('peer with no session yet is named, then delivers', () async {
      // B's session is missing on A at send time. The message still
      // goes out to C (reachable), and B is named no-session —
      // not silently dropped.
      sessionsA.remove(_nodeB);
      final result = await a.sendFleet('Joining late, copy?');
      expect(result.ok, isTrue);
      final msg = result.message!;
      expect(msg.peerStates[_nodeB], FleetChatPeerState.noSession);
      expect(msg.peerStates[_nodeC], FleetChatPeerState.pending);
      await a.pumpForTest();
      // C got it; B has nothing yet.
      expect(c.messagesFor('fleet'), hasLength(1));
      expect(b.messagesFor('fleet'), isEmpty);
      expect(a.overallFor(msg), FleetChatOverall.sending);
      // The exchange completes; the next retry delivers to B.
      // The +2 s pump enqueues the retry job; it drains on the
      // next pump, after its 500 ms pacing window.
      sessionsA[_nodeB] = keyAB;
      now = now.add(const Duration(seconds: 2));
      await a.pumpForTest();
      now = now.add(const Duration(milliseconds: 500));
      await a.pumpForTest();
      expect(b.messagesFor('fleet'), hasLength(1));
      expect(a.overallFor(msg), FleetChatOverall.sent);
    });

    test('inbound per-peer cap: 30/min, 31st dropped, window resets',
        () async {
      Future<Map<String, dynamic>> inboundFromB(String text, String id) async {
        final inner = fleetChatMessageToJson(
          msgId: id,
          channel: 'fleet',
          fromNode: _nodeB,
          fromCallsign: 'OUTRIDE-BBBB',
          seq: 1,
          tMs: now.millisecondsSinceEpoch,
          text: text,
        );
        return fleetEncryptEnvelope(
          sessionKey: keyAB,
          fleetId: _fleetId,
          fromNode: _nodeB,
          innerJson: inner,
        );
      }

      for (var i = 0; i < 30; i++) {
        final env = await inboundFromB(
            'msg $i', '0123456789abcdef0123456789abc${i.toString().padLeft(3, '0')}');
        await a.handleHubText(jsonEncode(env));
      }
      expect(a.messagesFor('fleet'), hasLength(30));
      final env31 = await inboundFromB(
          'msg 30', '0123456789abcdef0123456789abc030');
      await a.handleHubText(jsonEncode(env31));
      expect(a.messagesFor('fleet'), hasLength(30));
      // Next minute: the window resets and one more lands.
      now = now.add(const Duration(seconds: 61));
      final env32 = await inboundFromB(
          'msg 31', '0123456789abcdef0123456789abc031');
      await a.handleHubText(jsonEncode(env32));
      expect(a.messagesFor('fleet'), hasLength(31));
    });

    test('tampered, misaddressed and wrong-sender envelopes dropped',
        () async {
      // Tampered ciphertext: flip a character in the base64.
      final good = await fleetEncryptEnvelope(
        sessionKey: keyAB,
        fleetId: _fleetId,
        fromNode: _nodeB,
        innerJson: fleetChatMessageToJson(
          msgId: '0123456789abcdef0123456789abcdef',
          channel: 'fleet',
          fromNode: _nodeB,
          fromCallsign: 'OUTRIDE-BBBB',
          seq: 1,
          tMs: now.millisecondsSinceEpoch,
          text: 'tampered',
        ),
      );
      final tampered = Map<String, dynamic>.from(good);
      final ct = '${tampered['ct_b64'] ?? ''}';
      tampered['ct_b64'] =
          ct.isEmpty ? 'AAAA' : '${ct[0] == 'A' ? 'B' : 'A'}${ct.substring(1)}';
      await a.handleHubText(jsonEncode(tampered));
      expect(a.messagesFor('fleet'), isEmpty);

      // DM addressed to C, delivered to A: dropped.
      final dmForC = await fleetEncryptEnvelope(
        sessionKey: keyAB,
        fleetId: _fleetId,
        fromNode: _nodeB,
        innerJson: fleetChatMessageToJson(
          msgId: '1123456789abcdef0123456789abcdef',
          channel: 'dm',
          toNode: _nodeC,
          fromNode: _nodeB,
          fromCallsign: 'OUTRIDE-BBBB',
          seq: 2,
          tMs: now.millisecondsSinceEpoch,
          text: 'not for you',
        ),
      );
      await a.handleHubText(jsonEncode(dmForC));
      expect(a.messagesFor('fleet'), isEmpty);
      expect(a.threadIdsWithMessages, isEmpty);

      // Inner from_node disagrees with the envelope sender.
      final wrongSender = await fleetEncryptEnvelope(
        sessionKey: keyAB,
        fleetId: _fleetId,
        fromNode: _nodeB,
        innerJson: fleetChatMessageToJson(
          msgId: '2123456789abcdef0123456789abcdef',
          channel: 'fleet',
          fromNode: _nodeA,
          fromCallsign: 'OUTRIDE-AAAA',
          seq: 3,
          tMs: now.millisecondsSinceEpoch,
          text: 'spoofed',
        ),
      );
      await a.handleHubText(jsonEncode(wrongSender));
      expect(a.messagesFor('fleet'), isEmpty);

      // Garbage and non-chat datagrams never throw.
      await a.handleHubText('not json at all');
      await a.handleHubText('{}');
      await a.handleHubText('{"type":"fleet_data"}');
      await a.handleHubText(
          '{"type":"sensor","temperature":21.5}');
      expect(a.messagesFor('fleet'), isEmpty);
    });

    test('zero peers: send fails honestly, message filed as FAILED',
        () async {
      final solo = _makeService(
        nodeId: _nodeA,
        peers: const [],
        sessions: const {},
        mesh: mesh,
        now: () => now,
      );
      await solo.start();
      addTearDown(solo.dispose);
      final result = await solo.sendFleet('Hello? Anyone?');
      expect(result.ok, isFalse);
      expect(result.reason, contains('NO TEAM MEMBERS'));
      expect(result.message, isNotNull);
      expect(solo.overallFor(result.message!), FleetChatOverall.failed);
      expect(solo.messagesFor('fleet'), hasLength(1));
    });

    test('not in a fleet: send rejected, inbound ignored, no throw',
        () async {
      final outside = _makeService(
        nodeId: _nodeA,
        peers: [_peer(_nodeB, '10.0.0.2')],
        sessions: sessionsA,
        mesh: mesh,
        now: () => now,
        inFleet: false,
        fleetId: null,
      );
      await outside.start();
      addTearDown(outside.dispose);
      final result = await outside.sendFleet('Hello?');
      expect(result.ok, isFalse);
      expect(result.reason, contains('NOT IN A FLEET'));
      expect(result.message, isNull);
      final env = await fleetEncryptEnvelope(
        sessionKey: keyAB,
        fleetId: _fleetId,
        fromNode: _nodeB,
        innerJson: fleetChatMessageToJson(
          msgId: '0123456789abcdef0123456789abcdef',
          channel: 'fleet',
          fromNode: _nodeB,
          fromCallsign: 'OUTRIDE-BBBB',
          seq: 1,
          tMs: now.millisecondsSinceEpoch,
          text: 'ignored',
        ),
      );
      await outside.handleHubText(jsonEncode(env));
      expect(outside.messagesFor('fleet'), isEmpty);
    });

    test('outbound queue cap: 11th message rejected while 10 queued',
        () async {
      for (var i = 0; i < 10; i++) {
        final r = await a.sendFleet('queued $i');
        expect(r.ok, isTrue);
      }
      expect(a.queueLengthForTest, 10);
      final overflow = await a.sendFleet('one too many');
      expect(overflow.ok, isFalse);
      expect(overflow.reason, contains('SEND QUEUE FULL'));
      // Drain: one pump per 500 ms of clock.
      for (var i = 0; i < 10; i++) {
        await a.pumpForTest();
        now = now.add(const Duration(milliseconds: 500));
      }
      expect(a.queueLengthForTest, 0);
      expect(b.messagesFor('fleet'), hasLength(10));
    });

    test('outbound pacing: one fan-out per 500 ms', () async {
      await a.sendFleet('first');
      await a.sendFleet('second');
      expect(a.queueLengthForTest, 2);
      await a.pumpForTest();
      // First fan-out: 2 message deliveries + 2 acks back.
      expect(mesh.delivered.length, 4);
      await a.pumpForTest();
      expect(mesh.delivered.length, 4); // clock frozen: second waits
      now = now.add(const Duration(milliseconds: 500));
      await a.pumpForTest();
      expect(mesh.delivered.length, 8);
      expect(b.messagesFor('fleet'), hasLength(2));
    });

    test('unread clears when the thread opens', () async {
      await a.sendFleet('ping');
      await a.pumpForTest();
      expect(b.unreadCount('fleet'), 1);
      b.openThread('fleet');
      expect(b.unreadCount('fleet'), 0);
      await a.sendFleet('ping 2');
      // The second fan-out needs its 500 ms pacing window.
      now = now.add(const Duration(milliseconds: 500));
      await a.pumpForTest();
      // Thread still open: no unread increment.
      expect(b.unreadCount('fleet'), 0);
      expect(b.messagesFor('fleet'), hasLength(2));
    });

    test('fleet change clears history; same-fleet rejoin keeps it',
        () async {
      // Fleet id the service sees; mutated mid-test to simulate
      // forget/rejoin and joining a different fleet.
      String? currentFleetId = _fleetId;
      final svc = _makeService(
        nodeId: _nodeA,
        peers: [_peer(_nodeB, '10.0.0.2'), _peer(_nodeC, '10.0.0.3')],
        sessions: sessionsA,
        mesh: mesh,
        now: () => now,
        fleetIdFn: () => currentFleetId,
      );
      await svc.start();
      addTearDown(svc.dispose);

      // Inbound from B in fleet A: lands + unread badge.
      final inbound = await fleetEncryptEnvelope(
        sessionKey: keyAB,
        fleetId: _fleetId,
        fromNode: _nodeB,
        innerJson: fleetChatMessageToJson(
          msgId: '0123456789abcdef0123456789abcdef',
          channel: 'fleet',
          fromNode: _nodeB,
          fromCallsign: 'OUTRIDE-BBBB',
          seq: 1,
          tMs: now.millisecondsSinceEpoch,
          text: 'From B in fleet A.',
        ),
      );
      await svc.handleHubText(jsonEncode(inbound));
      expect(svc.messagesFor('fleet'), hasLength(1));
      expect(svc.unreadCount('fleet'), 1);
      expect(svc.seenIdsForTest, 1);

      // Outbound in fleet A: filed, queued, pending.
      final first = await svc.sendFleet('From A in fleet A.');
      expect(first.ok, isTrue);
      expect(first.message!.seq, 1);
      expect(svc.messagesFor('fleet'), hasLength(2));
      expect(svc.pendingCountForTest, 1);
      expect(svc.queueLengthForTest, 1);

      // Forget the fleet (id goes null), then rejoin the SAME
      // fleet: history, seq, and pending all survive — the reset
      // keys on fleet-id CHANGE, not on leaving.
      currentFleetId = null;
      final outside = await svc.sendFleet('Should not send.');
      expect(outside.ok, isFalse);
      expect(outside.reason, contains('NOT IN A FLEET'));
      expect(svc.messagesFor('fleet'), hasLength(2));
      currentFleetId = _fleetId;
      final second = await svc.sendFleet('Still fleet A.');
      expect(second.ok, isTrue);
      expect(second.message!.seq, 2);
      expect(svc.messagesFor('fleet'), hasLength(3));
      expect(svc.unreadCount('fleet'), 1);
      expect(svc.seenIdsForTest, 1);

      // Join a DIFFERENT fleet: old channel history, unread badge,
      // seen ids, pending, and queued jobs are all gone; the new
      // fleet starts clean (seq restarts at 1).
      currentFleetId = _fleetIdB;
      final third = await svc.sendFleet('Fleet B here.');
      expect(third.ok, isTrue);
      expect(third.message!.seq, 1);
      expect(svc.messagesFor('fleet'), hasLength(1));
      expect(svc.messagesFor('fleet').single.text, 'Fleet B here.');
      expect(svc.unreadCount('fleet'), 0);
      expect(svc.seenIdsForTest, 0);
      expect(svc.pendingCountForTest, 1);
      expect(svc.queueLengthForTest, 1);
    });
  });

  group('FleetChatScreen', () {
    void mockSecureStorage() {
      const channel =
          MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        switch (call.method) {
          case 'readAll':
            return <String, String>{};
          case 'containsKey':
            return false;
          case 'read':
          case 'write':
          case 'delete':
          case 'deleteAll':
            return null;
          default:
            return null;
        }
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
    }

    testWidgets('not in a fleet: shows the no-fleet state, no crash',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      mockSecureStorage();
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(home: FleetChatScreen(state: state)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      expect(find.text('FLEET CHAT'), findsOneWidget);
      expect(find.text('NOT IN A FLEET'), findsOneWidget);
      expect(find.text('FLEET CHAT — EXPERIMENTAL'), findsOneWidget);
      state.fleetChatService.dispose();
    });

    testWidgets('Fleet screen OPEN CHAT opens the thread list',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      mockSecureStorage();
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(home: FleetScreen(state: state)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('CREATE FLEET'));
      await tester.pump();
      await tester.ensureVisible(find.byType(FleetDialerPad));
      await tester.pump();
      // Dial 1-2-3-4: the 4th digit auto-submits (real Argon2id
      // KDF + socket bind). Pump fake time so the KDF progresses
      // inline; do NOT use pumpAndSettle (periodic beacon timer).
      for (final d in ['1', '2', '3', '4']) {
        await tester.tap(find.text(d));
        await tester.pump(const Duration(seconds: 8));
      }
      await tester.pump(const Duration(seconds: 2));
      expect(find.textContaining('IN FLEET'), findsWidgets);
      expect(find.text('OPEN CHAT — EXPERIMENTAL'), findsOneWidget);
      await tester.ensureVisible(find.text('OPEN CHAT — EXPERIMENTAL'));
      await tester.pump();
      await tester.tap(find.text('OPEN CHAT — EXPERIMENTAL'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      expect(find.text('FLEET CHAT'), findsOneWidget);
      expect(find.text('FLEET CHANNEL'), findsWidgets);
      expect(find.text('DIRECT MESSAGES'), findsOneWidget);
      // Open the fleet channel row (its subtitle is unique —
      // the section title shares the row's title text).
      await tester.tap(
          find.text('No messages yet — say hi to the team.'));
      await tester.pump();
      expect(find.text('Message the team…'), findsOneWidget);
      // Send with no team members: honest failure, no crash.
      await tester.enterText(
          find.byType(TextField), 'Radio check, anyone copy?');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('NO TEAM MEMBERS'), findsOneWidget);
      await state.fleetService.stop();
      state.fleetChatService.dispose();
    });
  });
}

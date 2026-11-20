/// v0.29.2 fleet-chat composer: the sent text must clear from the
/// composer after the message is accepted (the live verification
/// found it sticking). The send-error path is untouched — a failed
/// send keeps its error (covered by the no-peers case in
/// fleet_chat_test.dart).
///
/// The success path needs a real fleet peer with a session, so the
/// test creates a fleet through the real dialer (same flow as the
/// Fleet-screen widget test), then swaps the chat service for one
/// wired to a fake mesh with a peer that acks — via the
/// `fleetChatServiceForTest` hook.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:outride/screens/fleet_chat_screen.dart';
import 'package:outride/screens/fleet_screen.dart';
import 'package:outride/services/fleet_chat_service.dart';
import 'package:outride/services/fleet_dialer.dart';
import 'package:outride/services/fleet_service.dart';
import 'package:outride/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A fake mesh: delivers envelopes between services by address.
/// No sockets. (Same rig as fleet_chat_test.dart.)
class _FakeMesh {
  _FakeMesh(this.pairKeys);

  final Map<String, List<int>> pairKeys;
  final Map<String, FleetChatService> _byNode = {};
  final Map<String, String> _addressToNode = {};

  void register(String nodeId, String address, FleetChatService svc) {
    _byNode[nodeId] = svc;
    _addressToNode[address] = nodeId;
  }

  Future<void> deliver(
      Map<String, dynamic> envelope, String address) async {
    final toNode = _addressToNode[address];
    final svc = toNode == null ? null : _byNode[toNode];
    if (svc == null) return;
    await svc.handleHubText(jsonEncode(envelope));
  }
}

FleetPeer _peer(String nodeId, String address, String fleetId) =>
    FleetPeer(
      nodeId: nodeId,
      callsign: 'OUTRIDE-${nodeId.substring(0, 4).toUpperCase()}',
      fleetId: fleetId,
      hasSilvus: false,
      memberCount: 2,
      lastSeen: DateTime.utc(2026, 11, 20, 12),
      address: address,
    );

void main() {
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

  testWidgets('composer clears after a successful fleet send',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    mockSecureStorage();
    final state = AppState();
    addTearDown(state.dispose);

    // Create a fleet through the real dialer (real Argon2id KDF;
    // pump fake time so it progresses inline).
    await tester.pumpWidget(
      MaterialApp(home: FleetScreen(state: state)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('CREATE FLEET'));
    await tester.pump();
    await tester.ensureVisible(find.byType(FleetDialerPad));
    await tester.pump();
    for (final d in ['1', '2', '3', '4']) {
      await tester.tap(find.text(d));
      await tester.pump(const Duration(seconds: 8));
    }
    await tester.pump(const Duration(seconds: 2));
    expect(state.inFleet, isTrue);
    final ownNodeId = state.fleetService.record!.nodeId;
    final fleetId = state.fleetService.record!.fleetId;

    // Fake-mesh peer that acks: the injected chat service's send
    // must succeed for the composer to clear.
    const peerNodeId = 'bbbbbbbbbbbbbbbb';
    final keyAB = List<int>.generate(32, (i) => i + 1);
    final mesh = _FakeMesh({
      '$ownNodeId>$peerNodeId': keyAB,
      '$peerNodeId>$ownNodeId': keyAB,
    });
    final now = DateTime.utc(2026, 11, 20, 12);
    final svcA = FleetChatService(
      ownNodeId: () async => ownNodeId,
      ownCallsign: () => state.fleetService.callsign,
      fleetId: () => fleetId,
      inFleet: () => true,
      peers: () => [_peer(peerNodeId, '10.0.0.2', fleetId)],
      sessions: () => {peerNodeId: keyAB},
      now: () => now,
      sendEnvelope: (envelope, address) => mesh.deliver(envelope, address),
    );
    final svcB = FleetChatService(
      ownNodeId: () async => peerNodeId,
      ownCallsign: () => 'OUTRIDE-BBBB',
      fleetId: () => fleetId,
      inFleet: () => true,
      peers: () => [_peer(ownNodeId, '10.0.0.1', fleetId)],
      sessions: () => {ownNodeId: keyAB},
      now: () => now,
      sendEnvelope: (envelope, address) => mesh.deliver(envelope, address),
    );
    mesh.register(ownNodeId, '10.0.0.1', svcA);
    mesh.register(peerNodeId, '10.0.0.2', svcB);
    await svcA.start();
    await svcB.start();
    addTearDown(() {
      svcA.dispose();
      svcB.dispose();
    });
    state.fleetChatServiceForTest = svcA;

    await tester.pumpWidget(
      MaterialApp(home: FleetChatScreen(state: state)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(find.text('FLEET CHANNEL'), findsWidgets);
    await tester.tap(find.text('No messages yet — say hi to the team.'));
    await tester.pump();
    expect(find.text('Message the team…'), findsOneWidget);

    const sent = 'Radio check, anyone copy?';
    await tester.enterText(find.byType(TextField), sent);
    await tester.pump();
    expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        sent);
    await tester.tap(find.byIcon(Icons.send));
    // Let the paced send + the peer's ack land (fake time).
    for (var i = 0;
        i < 12 &&
            find.text(sent).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
    await tester.pump();
    expect(tester.takeException(), isNull);
    // The message is on the thread…
    expect(find.text(sent), findsOneWidget);
    // …and the composer is empty.
    expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty);

    // Dispose in the body, not just in tearDown: flutter_test
    // fails on pending timers when the body ends, and the pump
    // timer is only cancelled by dispose.
    svcA.dispose();
    svcB.dispose();
    await state.fleetService.stop();
  });
}

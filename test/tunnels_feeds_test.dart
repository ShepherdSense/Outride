/// Tunnels & Feeds widget tests (v0.30.1): the new section rows on
/// Radios & Networks, row taps pushing each detail screen, and smoke
/// tests for the detail screens. All probes are injected fakes —
/// never a real network, never a real socket.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:outride/screens/radios_networks_screen.dart';
import 'package:outride/screens/tunnels_feeds_detail_screens.dart';
import 'package:outride/state/app_state.dart';
import 'package:outride/theme.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'rf_sentry_zmeta_v1': jsonEncode({'simulatedMode': true}),
    });
  });

  Future<void> pumpScreen(WidgetTester tester, AppState state) async {
    // Tall enough for all five sections: the ListView only builds
    // what is in the viewport, and the GL.iNet section sits last.
    tester.view.physicalSize = const Size(360, 4800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
          theme: buildDarkTheme(),
          home: Scaffold(body: RadiosNetworksScreen(state: state))),
    );
    await tester.pump();
  }

  Future<void> pumpDetail(
      WidgetTester tester, Widget detail) async {
    tester.view.physicalSize = const Size(360, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: buildDarkTheme(), home: detail),
    );
    await tester.pump();
  }

  group('Tunnels & Feeds section', () {
    testWidgets('rows render with names and status pills',
        (tester) async {
      final state = AppState(
        wireguardProbe: () async => false,
        cloudflareProbe: (_) async => false,
        zerotierProbe: () async => false,
      );
      addTearDown(state.dispose);
      await pumpScreen(tester, state);
      expect(tester.takeException(), isNull);
      expect(find.text('TUNNELS & FEEDS'), findsOneWidget);
      for (final name in [
        'WireGuard',
        'Cloudflare',
        'Tailscale',
        'ZeroTier',
        'Predator-RF',
        'ZMeta',
      ]) {
        expect(find.text(name), findsOneWidget, reason: name);
      }
      // Statuses with nothing configured and no tunnel up.
      expect(find.text('DOWN'), findsOneWidget);
      // Cloudflare AND ZeroTier both report 'not configured' unjoined.
      expect(find.text('NOT CONFIGURED'), findsWidgets);
      expect(find.text('OFF'), findsWidgets);
    });

    testWidgets('tapping each row pushes its detail screen',
        (tester) async {
      final state = AppState(
        wireguardProbe: () async => false,
        cloudflareProbe: (_) async => false,
        zerotierProbe: () async => false,
      );
      addTearDown(state.dispose);
      const pushes = {
        'WireGuard': 'WIREGUARD',
        'Cloudflare': 'CLOUDFLARE',
        'Tailscale': 'TAILSCALE',
        'ZeroTier': 'ZEROTIER',
        'Predator-RF': 'PREDATOR-RF',
        'ZMeta': 'ZMETA',
      };
      for (final entry in pushes.entries) {
        await pumpScreen(tester, state);
        await tester.ensureVisible(find.text(entry.key));
        await tester.pumpAndSettle();
        await tester.tap(find.text(entry.key));
        await tester.pumpAndSettle();
        expect(find.text(entry.value), findsOneWidget,
            reason: '${entry.key} must open ${entry.value}');
        // Back to the list for the next row.
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
    });
  });

  group('WireGuard detail', () {
    testWidgets('shows tunnel up + local address from injected probes',
        (tester) async {
      final state = AppState(
        wireguardProbe: () async => true,
        wireguardAddressProbe: () async => '10.99.0.5',
        zerotierProbe: () async => false,
        cloudflareProbe: (_) async => false,
      );
      addTearDown(state.dispose);
      await pumpDetail(tester, WireguardDetailScreen(state: state));
      await tester.pump();
      expect(find.text('WIREGUARD'), findsOneWidget);
      expect(find.text('UP'), findsOneWidget);
      expect(find.text('10.99.0.5'), findsOneWidget);
      expect(find.text('Re-check tunnel'), findsOneWidget);
      expect(find.textContaining('WIREGUARD APP'), findsWidgets);
    });

    testWidgets('Re-check picks up a tunnel that comes up later',
        (tester) async {
      var up = false;
      final state = AppState(
        wireguardProbe: () async => up,
        wireguardAddressProbe: () async => up ? '10.99.0.5' : null,
        zerotierProbe: () async => false,
        cloudflareProbe: (_) async => false,
      );
      addTearDown(state.dispose);
      await pumpDetail(tester, WireguardDetailScreen(state: state));
      await tester.pump();
      expect(find.text('DOWN'), findsOneWidget);
      up = true;
      await tester.tap(find.text('Re-check tunnel'));
      await tester.pumpAndSettle();
      expect(find.text('UP'), findsOneWidget);
      expect(find.text('10.99.0.5'), findsOneWidget);
    });
  });

  group('Cloudflare detail', () {
    testWidgets('renders with no URL stored and states what is needed',
        (tester) async {
      final state = AppState(
        cloudflareProbe: (_) async => false,
        zerotierProbe: () async => false,
        wireguardProbe: () async => false,
      );
      addTearDown(state.dispose);
      await pumpDetail(tester, CloudflareDetailScreen(state: state));
      expect(tester.takeException(), isNull);
      expect(find.text('CLOUDFLARE'), findsOneWidget);
      expect(find.text('NOT CONFIGURED'), findsOneWidget);
      expect(find.text('— (NONE STORED)'), findsWidgets);
      expect(find.text('Re-check'), findsOneWidget);
      expect(find.textContaining('NEEDS A DOMAIN'), findsOneWidget);
      expect(find.textContaining('NO DOMAIN IS CONFIGURED YET'), findsOneWidget);
    });
  });

  group('Tailscale detail', () {
    testWidgets('shows detection + address + experimental guidance',
        (tester) async {
      final state = AppState(
        cloudflareProbe: (_) async => false,
        zerotierProbe: () async => false,
        wireguardProbe: () async => false,
      );
      addTearDown(state.dispose);
      await pumpDetail(
          tester,
          TailscaleDetailScreen(
            state: state,
            tunnelProbe: () async => true,
            addressProbe: () async => '100.64.0.5',
          ));
      await tester.pump();
      expect(find.text('TAILSCALE'), findsOneWidget);
      expect(find.text('UP'), findsOneWidget);
      expect(find.text('100.64.0.5'), findsOneWidget);
      expect(find.text('EXPERIMENTAL'), findsOneWidget);
      expect(find.textContaining('NO TAILSCALE'), findsOneWidget);
      expect(find.textContaining('JOIN THE TAILNET'), findsOneWidget);
    });

    testWidgets('not detected reads as guidance, not a failure',
        (tester) async {
      final state = AppState(
        cloudflareProbe: (_) async => false,
        zerotierProbe: () async => false,
        wireguardProbe: () async => false,
      );
      addTearDown(state.dispose);
      await pumpDetail(
          tester,
          TailscaleDetailScreen(
            state: state,
            tunnelProbe: () async => false,
            addressProbe: () async => null,
          ));
      await tester.pump();
      expect(find.text('NOT DETECTED'), findsOneWidget);
    });
  });

  group('ZeroTier detail', () {
    testWidgets('shows tunnel down + gateway + network-ID needed',
        (tester) async {
      final state = AppState(
        zerotierProbe: () async => false,
        cloudflareProbe: (_) async => false,
        wireguardProbe: () async => false,
      );
      addTearDown(state.dispose);
      await pumpDetail(
          tester,
          ZerotierDetailScreen(
            state: state,
            addressProbe: () async => null,
          ));
      await tester.pump();
      expect(find.text('ZEROTIER'), findsOneWidget);
      expect(find.text('DOWN'), findsOneWidget);
      expect(find.text('10.99.1.1'), findsOneWidget);
      expect(find.text('— (NONE STORED)'), findsOneWidget);
      expect(find.textContaining('NETWORK ID IS'), findsOneWidget);
      expect(find.text('Re-check tunnel'), findsOneWidget);
    });
  });

  group('Predator-RF detail', () {
    testWidgets('shows CoT status and the existing enable controls',
        (tester) async {
      final state = AppState(
        cloudflareProbe: (_) async => false,
        zerotierProbe: () async => false,
        wireguardProbe: () async => false,
      );
      addTearDown(state.dispose);
      await pumpDetail(tester, PredatorRfDetailScreen(state: state));
      expect(tester.takeException(), isNull);
      expect(find.text('PREDATOR-RF'), findsOneWidget);
      expect(find.text('239.2.3.1:6969'), findsOneWidget);
      expect(find.text('LISTEN FOR EMITTER TRACKS'), findsOneWidget);
      expect(find.text('EMIT COT TRACKS'), findsOneWidget);
      expect(find.textContaining('BOTH PATHS OFF'), findsOneWidget);
    });
  });

  group('ZMeta detail', () {
    testWidgets(
        'shows core fields inline and the join button (no Settings move)',
        (tester) async {
      final state = AppState(
        cloudflareProbe: (_) async => false,
        zerotierProbe: () async => false,
        wireguardProbe: () async => false,
      );
      addTearDown(state.dispose);
      await pumpDetail(tester, ZmetaDetailScreen(state: state));
      expect(tester.takeException(), isNull);
      expect(find.text('ZMETA'), findsOneWidget);
      expect(find.text('JOIN VIA INVITE CODE'), findsOneWidget);
      expect(find.text('Save gateway'), findsOneWidget);
      expect(find.text('EMIT ZMETA EVENTS'), findsOneWidget);
      expect(find.text('UDP'), findsOneWidget);
    });

    testWidgets('enable toggle persists through the AppState setter',
        (tester) async {
      final state = AppState(
        cloudflareProbe: (_) async => false,
        zerotierProbe: () async => false,
        wireguardProbe: () async => false,
      );
      await pumpDetail(tester, ZmetaDetailScreen(state: state));
      expect(state.settings.zmetaEnabled, isFalse);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.pump();
      expect(state.settings.zmetaEnabled, isTrue);
      // Explicit dispose (not addTearDown): enabling export starts
      // the periodic timers, and the framework fails a test that
      // ends with a timer still pending.
      state.dispose();
    });

    testWidgets('applyZmetaJoin lands a wireguard join like Settings',
        (tester) async {
      final state = AppState(
        cloudflareProbe: (_) async => false,
        zerotierProbe: () async => false,
        wireguardProbe: () async => false,
      );
      await state.applyZmetaJoin(
        platformId: 'outride-mesh-1',
        linkMode: 'wireguard',
        host: '10.99.0.5',
        port: 5555,
      );
      expect(state.settings.zmetaTransport, 'wireguard');
      expect(state.settings.zmetaHost, '10.99.0.5');
      expect(state.settings.zmetaPort, 5555);
      expect(state.settings.zmetaJoinedPlatformId, 'outride-mesh-1');
      expect(state.settings.zmetaEnabled, isFalse,
          reason: 'a join never enables export by itself');
      state.dispose();
    });

    testWidgets('applyZmetaJoin lands a zerotier join like Settings',
        (tester) async {
      final state = AppState(
        cloudflareProbe: (_) async => false,
        zerotierProbe: () async => false,
        wireguardProbe: () async => false,
      );
      await state.applyZmetaJoin(
        platformId: 'outride-mesh-1',
        linkMode: 'zerotier',
        host: '10.99.0.5',
        port: 5555,
        ingestUrl: 'https://hub.example.com/ingest',
        ingestFp: '-',
        zerotierNetworkId: 'abc123',
        zerotierNodeId: 'node1',
        zerotierIp: '10.99.1.11',
        zerotierIpStatus: 'OK',
        zerotierIpConfirmed: true,
        zerotierTarget: '10.99.1.1:5555',
      );
      expect(state.settings.zmetaTransport, 'zerotier');
      // ZeroTier: host/port come from the hub's ZT target, not the args.
      expect(state.settings.zmetaHost, '10.99.1.1');
      expect(state.settings.zmetaPort, 5555);
      expect(state.settings.zerotierNetworkId, 'abc123');
      expect(state.settings.zerotierNodeId, 'node1');
      expect(state.settings.zerotierIp, '10.99.1.11');
      expect(state.settings.zerotierIpConfirmed, isTrue);
      // The Cloudflare-mode URL/fp are KEPT as a fallback.
      expect(state.settings.zmetaIngestUrl,
          'https://hub.example.com/ingest');
      expect(state.settings.zmetaIngestFp, '-');
      expect(state.settings.zmetaEnabled, isFalse,
          reason: 'a join never enables export by itself');
      state.dispose();
    });

    testWidgets('applyZmetaJoin lands an https join like Settings',
        (tester) async {
      final state = AppState(
        cloudflareProbe: (_) async => false,
        zerotierProbe: () async => false,
        wireguardProbe: () async => false,
      );
      // A stale ZeroTier join must be cleared by the HTTPS join.
      state.settings.zerotierNetworkId = 'old-network';
      state.settings.zerotierNodeId = 'old-node';
      state.settings.zerotierIp = '10.99.1.99';
      await state.applyZmetaJoin(
        platformId: 'outride-mesh-1',
        linkMode: 'https',
        host: '10.99.0.5',
        port: 5555,
        ingestUrl: 'https://hub.example.com/ingest',
        ingestFp: '-',
      );
      expect(state.settings.zmetaTransport, 'https');
      expect(state.settings.zmetaIngestUrl,
          'https://hub.example.com/ingest');
      expect(state.settings.zmetaIngestFp, '-');
      expect(state.settings.zerotierNetworkId, isEmpty);
      expect(state.settings.zerotierNodeId, isEmpty);
      expect(state.settings.zerotierIp, isEmpty);
      expect(state.settings.zmetaJoinedPlatformId, 'outride-mesh-1');
      expect(state.settings.zmetaEnabled, isFalse,
          reason: 'a join never enables export by itself');
      state.dispose();
    });

    testWidgets('setZmetaHost keeps the current host on blank input',
        (tester) async {
      final state = AppState(
        cloudflareProbe: (_) async => false,
        zerotierProbe: () async => false,
        wireguardProbe: () async => false,
      );
      await state.setZmetaHost('10.99.0.5');
      expect(state.settings.zmetaHost, '10.99.0.5');
      await state.setZmetaHost('   ');
      expect(state.settings.zmetaHost, '10.99.0.5',
          reason: 'blank input keeps the current host');
      await state.setZmetaHost('  10.99.0.9  ');
      expect(state.settings.zmetaHost, '10.99.0.9',
          reason: 'input is trimmed');
      state.dispose();
    });

    testWidgets('setZmetaPort clamps to 1..65535', (tester) async {
      final state = AppState(
        cloudflareProbe: (_) async => false,
        zerotierProbe: () async => false,
        wireguardProbe: () async => false,
      );
      await state.setZmetaPort(0);
      expect(state.settings.zmetaPort, 1);
      await state.setZmetaPort(70000);
      expect(state.settings.zmetaPort, 65535);
      await state.setZmetaPort(5555);
      expect(state.settings.zmetaPort, 5555);
      state.dispose();
    });
  });
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:outride/screens/radios_networks_screen.dart';
import 'package:outride/services/discovery.dart';
import 'package:outride/state/app_state.dart';
import 'package:outride/theme.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'rf_sentry_zmeta_v1': jsonEncode({'simulatedMode': true}),
    });
  });

  Finder fieldByLabel(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );

  Future<void> pumpScreen(WidgetTester tester, AppState state,
      {SensorScanFn? scanRadios}) async {
    // Tall enough for all five sections: the ListView only builds
    // what is in the viewport, and the GL.iNet section sits last.
    tester.view.physicalSize = const Size(360, 4800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
          theme: buildDarkTheme(),
          home: Scaffold(
              body: RadiosNetworksScreen(
                  state: state, scanRadios: scanRadios))),
    );
    await tester.pump();
  }

  group('RadiosNetworksScreen (v0.30.1)', () {
    testWidgets('renders all five sections', (tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await pumpScreen(tester, state);
      expect(tester.takeException(), isNull);
      expect(find.text('RADIOS'), findsOneWidget);
      expect(find.text('FIND RADIOS ON LAN'), findsOneWidget);
      expect(find.text('NETWORKS'), findsOneWidget);
      expect(find.text('TUNNELS & FEEDS'), findsOneWidget);
      expect(find.text('GL.INET FIELD HUB'), findsOneWidget);
      expect(find.text('NO RADIOS CONFIGURED.'), findsOneWidget);
      expect(find.text('Wi-Fi'), findsOneWidget);
      expect(find.text('Bluetooth'), findsOneWidget);
      expect(find.text('WireGuard'), findsOneWidget);
      expect(find.text('Cloudflare'), findsOneWidget);
      expect(find.text('Tailscale'), findsOneWidget);
      expect(find.text('ZeroTier'), findsOneWidget);
      expect(find.text('Predator-RF'), findsOneWidget);
      expect(find.text('ZMeta'), findsOneWidget);
      expect(find.text('EXPERIMENTAL'), findsOneWidget);
      expect(find.textContaining('NEVER STORED'), findsOneWidget);
      expect(find.text('Probe'), findsOneWidget);
      expect(find.text('Connect'), findsOneWidget);
    });

    testWidgets('add radio form adds a radio', (tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await pumpScreen(tester, state);
      await tester.enterText(
          fieldByLabel('ADDRESS (IP)'), '172.17.97.182');
      await tester.tap(find.text('Add radio'));
      await tester.pump();
      await tester.pump();
      expect(state.radioConfigs.length, 1);
      expect(state.radioConfigs.first.address, '172.17.97.182');
      expect(find.text('SILVUS · 172.17.97.182'), findsOneWidget);
      expect(find.text('NOT POLLING'), findsOneWidget);
    });

    testWidgets(
        'scan finds a radio; tapping it adds it and persists the subnet',
        (tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await pumpScreen(tester, state,
          scanRadios: (_) async => [
                const DiscoveredRadio(
                  ip: '172.17.97.182',
                  nodeIds: ['node90550'],
                  nodeNames: ['Test radio'],
                ),
              ]);
      await tester.enterText(
          fieldByLabel('DISCOVERY SUBNET (CIDR)'), '10.0.0.0/24');
      await tester.tap(find.text('Scan subnet'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('172.17.97.182 (Test radio)'), findsOneWidget);
      await tester.tap(find.text('172.17.97.182 (Test radio)'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(state.radioConfigs.length, 1);
      expect(state.radioConfigs.first.address, '172.17.97.182');
      // The added radio now shows in the Radios section above,
      // under the found tile's label (label wins over the
      // driver · address fallback).
      expect(find.text('NOT POLLING'), findsOneWidget);
      // The subnet field now lives on this screen: a changed subnet
      // is persisted after a scan proves the CIDR parses.
      expect(state.settings.subnet, '10.0.0.0/24');
    });

    testWidgets('GL.iNet: Connect with no password shows the error',
        (tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await pumpScreen(tester, state);
      await tester.tap(find.text('Connect'));
      await tester.pump();
      expect(
          find.textContaining('Enter the router admin password'),
          findsOneWidget);
    });

    testWidgets('GL.iNet: Probe against an unreachable host reports it',
        (tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await pumpScreen(tester, state);
      await tester.enterText(fieldByLabel('ROUTER ADDRESS'), '127.0.0.1:1');
      await tester.tap(find.text('Probe'));
      // Bounded wait: connection-refused fails fast, but never let a
      // hung socket hold the suite — poll for the result line.
      for (var i = 0;
          i < 20 && find.textContaining('NOT A GL.INET').evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.textContaining('NOT A GL.INET'), findsOneWidget);
    });
  });
}

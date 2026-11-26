import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:outride/screens/tracking.dart';
import 'package:outride/services/ble_scan.dart';
import 'package:outride/services/wifi_sense.dart';
import 'package:outride/state/app_state.dart';
import 'package:outride/theme.dart';

/// Empty Wi-Fi source for tests: polls return nothing, so the only
/// readings in the panel are the ones the test ingests. The simulated
/// source would merge in its own four APs (including a second
/// connected one) and make chip counts non-deterministic.
class _EmptyWifiSource extends WifiRssiSource {
  @override
  Future<List<WifiApReading>> pollFast() async => [];

  @override
  Future<List<WifiApReading>> pollSurvey() async => [];
}

/// Tripwire layers on the fusion map (v0.30.1): the map shows what
/// tripwires are available — Wi-Fi APs (handshook + tripped) and
/// BLE advertisers — as panels under the map, toggled by the exact
/// labels "Wi-Fi tripwires" / "BLE tripwires".
void main() {
  Future<AppState> pumpMap(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'rf_sentry_zmeta_v1': jsonEncode({'simulatedMode': true}),
    });
    final state = AppState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
          theme: buildDarkTheme(),
          home: Scaffold(body: TrackingScreen(state: state))),
    );
    await tester.pump();
    // Let the async settings load land, then pin simulated mode the
    // way the app does — a direct field write races the load.
    state.applySettings(AppSettings(simulatedMode: true));
    await tester.pump();
    return state;
  }

  group('Fusion-map tripwire layers (v0.30.1)', () {
    testWidgets('toggles render with exact labels; panels hidden by default',
        (tester) async {
      await pumpMap(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Wi-Fi tripwires'), findsOneWidget);
      expect(find.text('BLE tripwires'), findsOneWidget);
      expect(find.text('WI-FI TRIPWIRES'), findsNothing);
      expect(find.text('BLUETOOTH TRIPWIRES'), findsNothing);
    });

    testWidgets('Wi-Fi panel lists APs with HANDSHOOK + TRIPPED tags',
        (tester) async {
      final state = await pumpMap(tester);
      // Empty source, not the simulated one: deterministic rows.
      state.wifi.start(simulate: true, sourceOverride: _EmptyWifiSource());
      state.wifi.ingest([
        WifiApReading(
            ssid: 'HomeNet',
            bssid: 'aa:bb:cc:dd:ee:11',
            rssiDbm: -55,
            isConnected: true),
        WifiApReading(
            ssid: 'NeighborNet',
            bssid: 'aa:bb:cc:dd:ee:12',
            rssiDbm: -72,
            isConnected: false),
      ]);
      state.wifi.disturbedBssids.add('aa:bb:cc:dd:ee:12');
      await tester.pump();
      await tester.tap(find.text('Wi-Fi tripwires'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('WI-FI TRIPWIRES'), findsOneWidget);
      expect(find.textContaining('HomeNet'), findsOneWidget);
      expect(find.textContaining('NeighborNet'), findsOneWidget);
      expect(find.text('HANDSHOOK'), findsOneWidget);
      expect(find.text('TRIPPED'), findsOneWidget);
      expect(find.text('2 APS'), findsOneWidget);
      // Stop in the body, not tearDown: the framework's pending-
      // timer check runs before addTearDown callbacks (same pattern
      // as wifi_vision_header_test).
      state.wifi.stop();
    });

    testWidgets('Wi-Fi panel offers START when vision is off',
        (tester) async {
      final state = await pumpMap(tester);
      expect(state.wifi.running, isFalse);
      await tester.tap(find.text('Wi-Fi tripwires'));
      await tester.pump();
      expect(find.textContaining('WI-FI VISION IS OFF'), findsOneWidget);
      expect(find.text('START WI-FI VISION'), findsOneWidget);
      await tester.tap(find.text('START WI-FI VISION'));
      await tester.pump();
      expect(state.wifi.running, isTrue);
      expect(find.textContaining('WI-FI VISION IS OFF'), findsNothing);
      // Stop in the body: see the note in the HANDSHOOK test.
      state.toggleWifiVision(false);
    });

    testWidgets('Bluetooth panel lists scanned devices', (tester) async {
      await pumpMap(tester);
      await tester.tap(find.text('BLE tripwires'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('BLUETOOTH TRIPWIRES'), findsOneWidget);
      expect(find.text('NO BLE DEVICES SEEN YET — TAP SCAN.'),
          findsOneWidget);
      expect(find.text('SCAN FOR BLE'), findsOneWidget);
      await tester.tap(find.text('SCAN FOR BLE'));
      await tester.pump();
      // The simulated BLE scan takes ~800 ms.
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump();
      expect(find.textContaining('Phone-7A2'), findsOneWidget);
      expect(find.textContaining('FitBand Pro'), findsOneWidget);
      expect(find.textContaining('4 DEVICE'), findsOneWidget);
    });

    testWidgets('toggling a layer off hides its panel again',
        (tester) async {
      final state = await pumpMap(tester);
      state.toggleWifiVision(true);
      await tester.pump();
      await tester.tap(find.text('Wi-Fi tripwires'));
      await tester.pump();
      expect(find.text('WI-FI TRIPWIRES'), findsOneWidget);
      await tester.tap(find.text('Wi-Fi tripwires'));
      await tester.pump();
      expect(find.text('WI-FI TRIPWIRES'), findsNothing);
      // Stop in the body: see the note in the HANDSHOOK test.
      state.toggleWifiVision(false);
    });

    testWidgets('BLE devices can be shown without Wi-Fi vision running',
        (tester) async {
      final state = await pumpMap(tester);
      // A manual BLE scan does not need Wi-Fi vision: seed one
      // device directly and show the panel lists it.
      state.wifi.ble.devices.add(BleNearbyDevice(
        id: 'aa:bb:cc:dd:ee:99',
        name: 'Test Beacon',
        rssiDbm: -66,
        lastSeen: DateTime.now(),
      ));
      await tester.tap(find.text('BLE tripwires'));
      await tester.pump();
      expect(find.textContaining('Test Beacon'), findsOneWidget);
      // Chip shows the bucket word only; the panel note carries
      // the (est.) caveat.
      expect(find.text('NEARBY'), findsOneWidget);
      expect(find.text('VERY CLOSE'), findsNothing);
    });
  });
}

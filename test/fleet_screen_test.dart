/// Fleet screen tests (spec §7).
///
/// The screen renders NOT IN A FLEET with a Create fleet button
/// and a dialer pad, and dialing 4 digits creates a fleet (status
/// flips to IN FLEET). The create path runs the real Argon2id KDF
/// and binds the real 6970 socket in the test VM, so the test
/// advances fake time rather than using pumpAndSettle (the 5 s
/// beacon timer is periodic, and the KDF yields on 1µs fake
/// timers — see the note in the create test).
///
/// A full two-EUD join is covered at message level in
/// fleet_service_test.dart; this file covers the screen contract
/// only.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:outride/screens/fleet_screen.dart';
import 'package:outride/services/fleet_dialer.dart';
import 'package:outride/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mock the flutter_secure_storage channel (the fleet key store):
/// without a handler, secure-storage calls in the fake-async zone
/// never resolve, stalling fleet init/create. The fleet service
/// tests use in-memory persistence and never touch this channel.
void _mockSecureStorage() {
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
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

void main() {
  group('FleetScreen', () {
    testWidgets('not in a fleet: status, create button, dialer keys',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // AppState's constructor fires SharedPreferences.getInstance()
      // (settings/radios load); without mock initial values the
      // first call never resolves in widget tests and poisons the
      // cached singleton for every later prefs call, including the
      // fleet service's (same pattern as gui_bundle_test.dart).
      SharedPreferences.setMockInitialValues({});
      _mockSecureStorage();
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(home: FleetScreen(state: state)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      expect(find.text('NOT IN A FLEET'), findsOneWidget);
      expect(find.text('CREATE FLEET'), findsOneWidget);
      // Role badge appears twice: status panel + self row.
      expect(find.text('FUSION PEER'), findsNWidgets(2));
      // The dialer appears after tapping Create fleet.
      await tester.tap(find.text('CREATE FLEET'));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
      expect(find.byIcon(Icons.backspace_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Stop the fleet service explicitly: its 5 s beacon timer is
      // periodic, and AppState.dispose only stops it fire-and-forget
      // — a pending timer at teardown fails the test.
      await state.fleetService.stop();
    });

    testWidgets('dialing 4 digits creates the fleet', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // Mock prefs before AppState: see the note in the test above.
      SharedPreferences.setMockInitialValues({});
      _mockSecureStorage();
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(home: FleetScreen(state: state)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('CREATE FLEET'));
      await tester.pump();
      // The dialer sits below the fold in the 800 px viewport —
      // scroll it into view before tapping, or the taps land on
      // empty space.
      await tester.ensureVisible(find.byType(FleetDialerPad));
      await tester.pump();
      // Dial 1-2-3-4: the 4th digit auto-submits (real Argon2id KDF
      // + socket bind). The KDF yields via Future.delayed(1µs) per
      // chunk (package:cryptography), so in the fake-async zone it
      // only progresses while fake time advances — pump 30 s of
      // fake time, which runs the whole KDF inline (about 1–2 s of
      // real CPU on this VM). Do NOT use pumpAndSettle: the 5 s
      // beacon timer is periodic.
      for (final d in ['1', '2', '3', '4']) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(tester.takeException(), isNull);
      // 'IN FLEET' appears twice: status panel + member-count line.
      expect(find.textContaining('IN FLEET'), findsNWidgets(2));
      expect(find.text('FORGET FLEET'), findsOneWidget);
      await state.fleetService.stop();
    });
  });
}

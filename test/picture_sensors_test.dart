import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:outride/main.dart';
import 'package:outride/models/link_sample.dart';
import 'package:outride/models/tracking.dart';
import 'package:outride/screens/picture_screen.dart';
import 'package:outride/screens/sensors_screen.dart';
import 'package:outride/services/experimental_sensors.dart';
import 'package:outride/state/app_state.dart';
import 'package:outride/theme.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    // The experimental toggle is a process-wide singleton: leave it
    // OFF for the next test, whatever this one did.
    await experimentalSensors.set(false);
  });

  group('PictureScreen', () {
    testWidgets('idle: PAUSED banner, START action, fleet chip, no events',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
            theme: buildDarkTheme(),
            home: Scaffold(body: PictureScreen(state: state))),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('PAUSED'), findsOneWidget);
      expect(find.text('PRESS START TO BEGIN MONITORING'), findsOneWidget);
      expect(find.text('START'), findsOneWidget);
      expect(find.text('NOT IN A FLEET'), findsOneWidget);
      expect(find.text('NO CROSSINGS DETECTED YET'), findsOneWidget);
      expect(find.text('LATEST EVENTS'), findsOneWidget);
      expect(find.text('NO EVENTS YET'), findsOneWidget);
      // The tired-operator question: with no polling and no events,
      // nothing on the screen claims a detection.
      expect(find.text('POSSIBLE MOVEMENT'), findsNothing);
      expect(find.text('TRACK'), findsNothing);
    });

    testWidgets('POSSIBLE MOVEMENT with disturbed links and no track',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      // Disturbed link: dip above the 6.0 default threshold, fresh
      // enough to count as live.
      state.polling = true;
      state.history['nodeA → nodeB'] = [
        LinkSample(
          timestamp: DateTime.now(),
          fromNode: 'nodeA',
          toNode: 'nodeB',
          dip: 12.0,
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
            theme: buildDarkTheme(),
            home: Scaffold(body: PictureScreen(state: state))),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('POSSIBLE MOVEMENT'), findsOneWidget);
      expect(find.text('1 LINK DIRECTION(S) DISTURBED'), findsOneWidget);
      expect(find.text('TRACK'), findsNothing);
      // The radios/links row reflects the disturbance too.
      expect(find.textContaining('1 DISTURBED'), findsOneWidget);
    });

    testWidgets('TRACK (red) with an INBOUND track', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      state.polling = true;
      state.history['nodeA → nodeB'] = [
        LinkSample(
          timestamp: DateTime.now(),
          fromNode: 'nodeA',
          toNode: 'nodeB',
          dip: 12.0,
        ),
      ];
      state.track = TrackEstimate(
        timestamp: DateTime.now(),
        x: 50,
        y: 50,
        sizeClass: 'M',
        typeGuess: 'Fast small object — possible small drone',
        typeConfidence: 0.3,
        linksUsed: 3,
        relation: 'INBOUND',
        headingDeg: 45.0,
        speedMps: 1.2,
      );
      await tester.pumpWidget(
        MaterialApp(
            theme: buildDarkTheme(),
            home: Scaffold(body: PictureScreen(state: state))),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('TRACK'), findsOneWidget);
      expect(find.textContaining('TRACK — INBOUND'), findsOneWidget);
      expect(find.text('POSSIBLE MOVEMENT'), findsNothing);
      // Red: banner title text and banner icon both carry it.
      final title = tester.widget<Text>(find.text('TRACK'));
      expect(title.style?.color, OutrideColors.red);
      final icon = tester.widget<Icon>(find.byIcon(Icons.flight_takeoff));
      expect(icon.color, OutrideColors.red);
    });

    testWidgets('SEE ALL opens the full crossing-events list with triage',
        (tester) async {
      // Taller than the 800 px default: the nearest-event card is
      // full-height with an event in it, and ListView builds lazily
      // — the tail sits below the fold at phone height.
      tester.view.physicalSize = const Size(360, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      state.events.add(CrossingEvent(
        timestamp: DateTime.now(),
        linkKey: 'nodeA → nodeB',
        dipDepth: 12.0,
        durationSecs: 4.5,
        sizeEstimate: 'M',
      ));
      await tester.pumpWidget(
        MaterialApp(
            theme: buildDarkTheme(),
            home: Scaffold(body: PictureScreen(state: state))),
      );
      await tester.pump();
      expect(find.text('SEE ALL'), findsOneWidget);
      await tester.tap(find.text('SEE ALL'));
      await tester.pump();
      await tester.pump();
      // AppBar title + card header both read CROSSING EVENTS.
      expect(find.text('CROSSING EVENTS'), findsNWidgets(2));
      expect(find.text('ACK 0 · FA 0 · NEW 1'), findsOneWidget);
      expect(find.text('ACK'), findsOneWidget);
      expect(find.text('FALSE ALARM'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('radios/links row opens RADIOS & MESH LINKS',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
            theme: buildDarkTheme(),
            home: Scaffold(body: PictureScreen(state: state))),
      );
      await tester.pump();
      expect(find.text('RADIOS 0 · LINKS 0'), findsOneWidget);
      await tester.tap(find.text('RADIOS 0 · LINKS 0'));
      await tester.pump();
      await tester.pump();
      expect(find.text('MESH LINKS'), findsOneWidget);
      expect(find.text('NOT POLLING — PRESS START.'), findsOneWidget);
      expect(find.text('NO LINK DATA YET'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('SensorsScreen experimental filter', () {
    testWidgets('OFF by default: 4 of 6 rows, no EXPERIMENTAL tags',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
            theme: buildDarkTheme(),
            home: Scaffold(body: SensorsScreen(state: state))),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('FIELD MAP'), findsOneWidget);
      expect(find.text('BEAM'), findsOneWidget);
      expect(find.text('WIFI'), findsOneWidget);
      expect(find.text('DRONE'), findsOneWidget);
      expect(find.text('FETCH'), findsNothing);
      expect(find.text('SPECTRUM'), findsNothing);
      expect(find.textContaining('4 OF 6 SHOWN'), findsOneWidget);
      expect(find.text('EXPERIMENTAL'), findsNothing);
    });

    testWidgets('ON: all 6 rows with EXPERIMENTAL tags on Fetch/Spectrum',
        (tester) async {
      // Taller than the 800 px default: all six rows must be built,
      // and ListView builds lazily — the last row sits below the
      // fold at phone height.
      tester.view.physicalSize = const Size(360, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
            theme: buildDarkTheme(),
            home: Scaffold(body: SensorsScreen(state: state))),
      );
      await tester.pump();
      expect(find.text('FETCH'), findsNothing);
      await experimentalSensors.set(true);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('FETCH'), findsOneWidget);
      expect(find.text('SPECTRUM'), findsOneWidget);
      expect(find.text('EXPERIMENTAL'), findsNWidgets(2));
      expect(find.textContaining('6 OF 6 SHOWN'), findsOneWidget);
    });
  });

  group('WifiWebGateScreen', () {
    testWidgets('gate card renders, no live-looking gauges',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
            theme: buildDarkTheme(),
            home: const WifiWebGateScreen()),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('WiFi scanning is not available on web'),
          findsOneWidget);
      expect(find.text('NOT ON WEB'), findsOneWidget);
    });
  });

  group('Transparent purple buttons', () {
    test('OutrideButtons.primary is translucent purple, never solid', () {
      final style = OutrideButtons.primary;
      final bg = style.backgroundColor!.resolve({})!;
      expect(bg, OutrideColors.purple.withAlpha(31));
      expect((bg.a * 255).round(), lessThan(64));
      expect(style.foregroundColor!.resolve({}), OutrideColors.purple);
      expect(style.side!.resolve({})!.color,
          OutrideColors.purple.withAlpha(110));
      // The outline sibling: same purple, fully transparent fill.
      final outlineBg = OutrideButtons.outline.backgroundColor!.resolve({})!;
      expect((outlineBg.a * 255).round(), 0);
      expect(OutrideButtons.outline.foregroundColor!.resolve({}),
          OutrideColors.purple);
    });

    test('theme gives every ElevatedButton the transparent purple style',
        () {
      final style = buildDarkTheme().elevatedButtonTheme.style!;
      expect(style.backgroundColor!.resolve({}),
          OutrideColors.purple.withAlpha(31));
      expect(style.foregroundColor!.resolve({}), OutrideColors.purple);
    });
  });

  group('Three-destination nav', () {
    testWidgets('bottom nav has Picture / Sensors / Settings only',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const OutrideApp());
      await tester.pump();
      expect(tester.takeException(), isNull);
      final nav = tester.widget<BottomNavigationBar>(
          find.byType(BottomNavigationBar));
      expect(nav.items.length, 3);
      expect(find.text('Picture'), findsOneWidget);
      expect(find.text('Sensors'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      // The old eight-tab bar is gone.
      expect(find.text('Alerts'), findsNothing);
      expect(find.text('Beam'), findsNothing);
      expect(find.text('Spectrum'), findsNothing);
    });
  });
}

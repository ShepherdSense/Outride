import 'dart:convert';

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
    // These tests exercise the sim-fed Picture/Sensors screens, so
    // they store a simulated choice: the fresh-install default is
    // now LIVE (see simulated_mode), and the async settings load
    // would otherwise flip the screens to LIVE mid-test.
    SharedPreferences.setMockInitialValues({
      'rf_sentry_zmeta_v1': jsonEncode({'simulatedMode': true}),
    });
  });

  tearDown(() async {
    // The experimental toggle is a process-wide singleton: leave it
    // OFF for the next test, whatever this one did.
    await experimentalSensors.set(false);
  });

  group('PictureScreen', () {
    testWidgets('idle: PAUSED banner, START action, fleet chip, no events',
        (tester) async {
      // v0.29.2: Picture is taller now (live GPS map card + readout
      // grid + callout above the tail), so the viewport is taller
      // than a phone — ListView builds lazily and the tail must be
      // built for the finds below.
      tester.view.physicalSize = const Size(360, 2000);
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
      // v0.29.2: the quiet state is the callout card now, mock
      // sentence case instead of the old shouty panel line. Idle
      // (not polling) shows the paused callout; polling with no
      // events shows the quiet callout.
      expect(find.text('Monitoring paused'), findsOneWidget);
      state.polling = true;
      state.notifyListeners();
      await tester.pump();
      expect(find.text('Perimeter quiet'), findsOneWidget);
      expect(find.text('LATEST EVENTS'), findsOneWidget);
      expect(find.text('NO EVENTS YET'), findsOneWidget);
      // The tired-operator question: with no polling and no events,
      // nothing on the screen claims a detection.
      expect(find.text('POSSIBLE MOVEMENT'), findsNothing);
      expect(find.text('TRACK'), findsNothing);
    });

    testWidgets('POSSIBLE MOVEMENT with disturbed links and no track',
        (tester) async {
      // v0.29.2: taller viewport — the radios/links row sits below
      // the map + grid + callout and ListView builds lazily.
      tester.view.physicalSize = const Size(360, 2000);
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
      // Red: the banner title carries it (v0.29.2 banner is
      // text-only per the mock — no icon widget is rendered).
      final title = tester.widget<Text>(find.text('TRACK'));
      expect(title.style?.color, OutrideColors.red);
    });

    testWidgets('SEE ALL opens the full crossing-events list with triage',
        (tester) async {
      // Taller than the 800 px default: the nearest-event card is
      // full-height with an event in it, and ListView builds lazily
      // — the tail sits below the fold at phone height. v0.29.2:
      // the live GPS map card + readout grid + callout sit above
      // the tail, so this needs 2400 px now.
      tester.view.physicalSize = const Size(360, 2400);
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
      // v0.29.2: the radios row sits below the map card + readout
      // grid + callout, so the viewport is taller than a phone.
      tester.view.physicalSize = const Size(360, 1600);
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

    testWidgets('status banner never overflows at 360 px in LIVE or SIM',
        (tester) async {
      // Regression test for the Flexible + FittedBox(scaleDown) fix
      // around 'PERIMETER STATUS': the LIVE chip is one character
      // wider than SIM, and without the shrink-wrap the row overflowed
      // a 360 px phone in LIVE mode (11 px) — the default since
      // v0.29.7. The SIM rendering must stay exactly as before: the
      // label at full size, never scaled down.
      addTearDown(tester.view.reset);
      Future<AppState> pumpBanner({required bool simulated}) async {
        SharedPreferences.setMockInitialValues({
          'rf_sentry_zmeta_v1': jsonEncode({'simulatedMode': simulated}),
        });
        final state = AppState();
        addTearDown(state.dispose);
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        await tester.pumpWidget(
          MaterialApp(
              theme: buildDarkTheme(),
              home: Scaffold(body: PictureScreen(state: state))),
        );
        // Let the async settings load land so the mode under test is
        // the mode asserted, not the constructor default.
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 500)));
        await tester.pump();
        return state;
      }

      // LIVE first: the wider chip is the overflowing case.
      final liveState = await pumpBanner(simulated: false);
      expect(liveState.settings.simulatedMode, isFalse);
      expect(find.text('PERIMETER STATUS'), findsOneWidget);
      expect(find.text('LIVE'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));

      // SIM: same width, no overflow, and the label at full size.
      final simState = await pumpBanner(simulated: true);
      expect(simState.settings.simulatedMode, isTrue);
      expect(find.text('PERIMETER STATUS'), findsOneWidget);
      expect(find.text('SIM'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final labelBox =
          tester.renderObject<RenderBox>(find.text('PERIMETER STATUS'));
      final painter = TextPainter(
        text: TextSpan(
            text: 'PERIMETER STATUS', style: OutrideType.section()),
        textDirection: TextDirection.ltr,
      )..layout();
      expect(labelBox.size.width, closeTo(painter.width, 0.5),
          reason: 'SIM label renders at full size, never scaled down');
    });
  });

  group('SensorsScreen experimental filter', () {
    testWidgets('OFF by default: 4 of 7 rows, no EXPERIMENTAL tags',
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
      // v0.29.2: mock title-case names, sentence-case count line.
      expect(find.text('Field map'), findsOneWidget);
      expect(find.text('Beam'), findsOneWidget);
      expect(find.text('WiFi'), findsOneWidget);
      expect(find.text('Drone'), findsOneWidget);
      expect(find.text('Fetch'), findsNothing);
      expect(find.text('Spectrum'), findsNothing);
      expect(find.text('Bench'), findsNothing);
      expect(find.textContaining('4 of 7 shown'), findsOneWidget);
      expect(find.text('EXPERIMENTAL'), findsNothing);
    });

    testWidgets('ON: all 7 rows with EXPERIMENTAL tags on Fetch/Spectrum/Bench',
        (tester) async {
      // Taller than the 800 px default: all seven rows must be built,
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
      expect(find.text('Fetch'), findsOneWidget);
      expect(find.text('Spectrum'), findsOneWidget);
      expect(find.text('Bench'), findsOneWidget);
      expect(find.text('EXPERIMENTAL'), findsNWidgets(3));
      expect(find.textContaining('7 of 7 shown'), findsOneWidget);
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

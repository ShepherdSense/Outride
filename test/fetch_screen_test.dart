/// Tests for the Fetch view (S4, review 2026-11-12): the gauge
/// threshold fractions and the no-driver setup hint.
///
/// A full widget test with a live driver is deliberately not here:
/// getting a Fetch driver into AppState requires start(), which
/// starts polling and binds the UDP hub — too heavy for a unit
/// test. What IS covered: the gauge math the screen actually
/// renders (both threshold markers must sit at exactly 50% of
/// their bars) and the setup hint the view degrades to when no
/// driver is added, including the "press Start" step (S5) — the
/// one step that makes anything listen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:outride/models/fetch_event.dart';
import 'package:outride/screens/fetch_screen.dart';
import 'package:outride/state/app_state.dart';

void main() {
  group('fetchGaugeFraction', () {
    test('mag_g rest marker sits at exactly half the bar', () {
      // Gauge: max 2.0, rest marker 1.0 g.
      expect(fetchGaugeFraction(1.0, 2.0), 0.5);
    });

    test('mic trip line sits at exactly half the bar', () {
      // Gauge: max 300000, trip line FetchEvent.micTripThreshold.
      expect(
          fetchGaugeFraction(FetchEvent.micTripThreshold, 300000), 0.5);
    });

    test('no reading is an empty bar', () {
      expect(fetchGaugeFraction(null, 2.0), 0.0);
    });

    test('values clamp to the bar', () {
      expect(fetchGaugeFraction(5.0, 2.0), 1.0); // over max
      expect(fetchGaugeFraction(-1.0, 2.0), 0.0); // below zero
      expect(fetchGaugeFraction(0.0, 2.0), 0.0);
    });
  });

  group('FetchScreen without a driver', () {
    testWidgets('setup hint renders, names the Start step, no overflow',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: FetchScreen(state: state))),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('NO FETCH DRIVER'), findsOneWidget);
      expect(find.text('THE FETCH'), findsOneWidget);
      expect(find.text('EXPERIMENTAL'), findsOneWidget);
      // S5: the hint must name the step that makes anything listen
      // — the driver only binds the UDP hub while polling runs.
      expect(find.textContaining('press Start'), findsOneWidget);
      expect(find.textContaining('Settings'), findsOneWidget);
      // The scope note is always present, driver or not.
      expect(find.textContaining('never identifies anyone'),
          findsOneWidget);
    });
  });
}

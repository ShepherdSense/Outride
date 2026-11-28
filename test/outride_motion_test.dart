/// Widget tests for the v0.30.0 motion layer (refinement brief):
/// state transitions crossfade instead of flipping, value changes
/// fade, new alert rows slide in on mount, the mode pill flips with
/// animation, and the live dot pulses. Durations/curves are read
/// from [OutrideMotion] — these tests assert the behaviour, not the
/// exact numbers, so a cue-list refinement of the constants does
/// not break them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/tripwire.dart';
import 'package:outride/widgets/animated_value_text.dart';
import 'package:outride/widgets/app_top_bar.dart';
import 'package:outride/widgets/live_dot.dart';
import 'package:outride/widgets/outride_motion.dart';
import 'package:outride/widgets/slide_in_row.dart';
import 'package:outride/widgets/trip_state_indicator.dart';

void main() {
  group('TripStateIndicator', () {
    testWidgets('walks armed → tripped → confirmed → cleared',
        (tester) async {
      Widget frame(TripState phase) => MaterialApp(
            home: Scaffold(
              body: Center(child: TripStateIndicator(phase: phase)),
            ),
          );
      // Timed pumps, not pumpAndSettle: the tripped phase mounts a
      // slowly pulsing LiveDot (a repeating controller), which never
      // "settles". A 300 ms pump runs the 250 ms crossfade through.
      await tester.pumpWidget(frame(TripState.armed));
      expect(find.text('ARMED'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing);

      await tester.pumpWidget(frame(TripState.tripped));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('TRIPPED'), findsOneWidget);

      await tester.pumpWidget(frame(TripState.confirmed));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('CONFIRMED'), findsOneWidget);
      // Confirmed swaps the dot for the short check.
      expect(find.byIcon(Icons.check), findsOneWidget);

      await tester.pumpWidget(frame(TripState.cleared));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('CLEARED'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing);
    });
  });

  group('AnimatedValueText', () {
    testWidgets('fades to the new value', (tester) async {
      Widget frame(String v) => MaterialApp(
            home: Scaffold(body: Center(child: AnimatedValueText(value: v))),
          );
      await tester.pumpWidget(frame('SNR 10'));
      expect(find.text('SNR 10'), findsOneWidget);
      await tester.pumpWidget(frame('SNR 12'));
      await tester.pumpAndSettle();
      expect(find.text('SNR 12'), findsOneWidget);
      expect(find.text('SNR 10'), findsNothing);
    });
  });

  group('LiveDot', () {
    testWidgets('pulsing and static dots render', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                LiveDot(pulsing: true),
                LiveDot(pulsing: false),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 800));
      expect(tester.takeException(), isNull);
    });
  });

  group('SlideInRow', () {
    testWidgets('mounts its child and settles', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SlideInRow(child: Text('NEW ALERT')),
          ),
        ),
      );
      expect(find.text('NEW ALERT'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('NEW ALERT'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('AppTopBar', () {
    testWidgets('mode pill flips SIMULATED → LIVE', (tester) async {
      Widget frame(bool simulated) => MaterialApp(
            home: Scaffold(
              appBar: AppBar(title: AppTopBar(simulated: simulated)),
              body: const SizedBox(),
            ),
          );
      await tester.pumpWidget(frame(true));
      expect(find.text('SIMULATED'), findsOneWidget);
      await tester.pumpWidget(frame(false));
      await tester.pumpAndSettle();
      expect(find.text('LIVE'), findsOneWidget);
      expect(find.text('SIMULATED'), findsNothing);
    });
  });

  group('OutrideMotion.fadeSlideTransition', () {
    testWidgets('tab-style switch crossfades to the new child',
        (tester) async {
      var tab = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: AnimatedSwitcher(
                duration: OutrideMotion.standard,
                switchInCurve: OutrideMotion.curve,
                switchOutCurve: OutrideMotion.curve,
                transitionBuilder: OutrideMotion.fadeSlideTransition,
                child: Text('TAB $tab', key: ValueKey(tab)),
              ),
              floatingActionButton: FloatingActionButton(
                onPressed: () => setState(() => tab = 1),
                child: const Icon(Icons.swap_horiz),
              ),
            ),
          ),
        ),
      );
      expect(find.text('TAB 0'), findsOneWidget);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('TAB 1'), findsOneWidget);
      expect(find.text('TAB 0'), findsNothing);
    });
  });
}

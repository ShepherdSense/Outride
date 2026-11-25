/// Bench screen widget tests: every IMPLEMENT row has a RUN
/// button; every QUEUED row has none (registry test covers the
/// data; this covers the affordance in the rendered screen).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:outride/screens/bench_screen.dart';
import 'package:outride/services/bench_registry.dart';
import 'package:outride/state/app_state.dart';

void main() {
  group('BenchScreen affordances', () {
    testWidgets('IMPLEMENT rows have Run buttons; QUEUED rows do not',
        (tester) async {
      // Tall viewport: the screen is a long ListView and slivers only
      // mount visible children — 30000 px mounts the whole screen so
      // every row's affordance is findable.
      tester.view.physicalSize = const Size(400, 30000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: BenchScreen(state: state))),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Header identity.
      expect(find.text('BENCH — EXPERIMENTAL / UNTESTED'), findsOneWidget);
      // The exact pending string is visible on empty input.
      expect(find.textContaining('measurement pending'), findsWidgets);

      // Record section at the top.
      expect(find.text('RECORD — FIELD SESSIONS FOR THE BENCHES'),
          findsOneWidget);
      expect(find.text('START RECORDING'), findsOneWidget);

      // Fleet-health panel: unreadable, never green.
      expect(find.text('FLEET HEALTH (B3 PENDING)'), findsOneWidget);
      expect(find.text('UNREADABLE'), findsOneWidget);

      // Run-all is present.
      expect(find.text('RUN ALL'), findsOneWidget);

      // Every non-grouped IMPLEMENT entry has a Run button; every
      // QUEUED entry has none. The B5 arms share one harness: the
      // group header owns the single run-B5 button, never one per
      // arm row.
      for (final e in benchRegistry.where((e) =>
          e.kind == BenchVerdictKind.implement && e.group == null)) {
        expect(find.byKey(ValueKey('run-${e.id}')), findsOneWidget,
            reason: '${e.id} should have a Run button');
      }
      expect(find.byKey(const ValueKey('run-B5')), findsOneWidget);
      for (final e in benchRegistry
          .where((e) => e.group == 'B5 — CI bench arms')) {
        expect(find.byKey(ValueKey('run-${e.id}')), findsNothing,
            reason: '${e.id} must NOT have its own Run button');
      }
      for (final e in benchRegistry
          .where((e) => e.kind == BenchVerdictKind.queuedBlocked)) {
        expect(find.byKey(ValueKey('run-${e.id}')), findsNothing,
            reason: '${e.id} must NOT have a Run button');
        // Blocker text is shown.
        expect(find.textContaining('BLOCKED'), findsWidgets);
      }

      // Every QUEUED entry shows its WHAT WOULD UNBLOCK THIS line.
      expect(find.textContaining('WHAT WOULD UNBLOCK THIS'),
          findsNWidgets(15));
    });
  });
}

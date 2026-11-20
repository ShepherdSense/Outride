import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:outride/models/link_sample.dart';
import 'package:outride/screens/events_list_screen.dart';
import 'package:outride/state/app_state.dart';
import 'package:outride/theme.dart';

CrossingEvent _ev(String link, int secs) => CrossingEvent(
      timestamp: DateTime.utc(2026, 10, 16, 12, 0, secs),
      linkKey: link,
      dipDepth: 8.0,
      durationSecs: 2.0,
      sizeEstimate: 'M',
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('EventsListScreen triage', () {
    testWidgets(
        'tapping ACK / FALSE ALARM updates the counters live on the '
        'pushed route', (tester) async {
      // 600px wide: the header row ('CROSSING EVENTS' + the ACK/FA/
      // NEW counts, both letterspaced mono) is exactly at the edge
      // at 360px in the test font, which overflows and masks the
      // assertion below. The width is incidental to triage; the
      // point is the route rebuilds with no listening ancestor.
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      state.events.addAll([_ev('a → b', 1), _ev('c → d', 2)]);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(),
          home: EventsListScreen(state: state),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('ACK 0 · FA 0 · NEW 2'), findsOneWidget);

      // ACK the first event. The screen is pumped bare, exactly as a
      // pushed route is live: no listening ancestor above it. The
      // v0.29.0 live bug was that this tap updated the triage record
      // but the route never rebuilt, so the counters stayed at zero.
      await tester.tap(find.text('ACK').first);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('ACK 1 · FA 0 · NEW 1'), findsOneWidget);

      // FALSE ALARM the second event.
      await tester.tap(find.text('FALSE ALARM').last);
      await tester.pump();
      expect(find.text('ACK 1 · FA 1 · NEW 0'), findsOneWidget);

      // Tapping the same verdict again clears it.
      await tester.tap(find.text('ACK').first);
      await tester.pump();
      expect(find.text('ACK 0 · FA 1 · NEW 1'), findsOneWidget);
    });
  });
}

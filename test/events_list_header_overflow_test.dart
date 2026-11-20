/// v0.29.1 review follow-up: EventsListCard's header Row was a
/// plain Text('CROSSING EVENTS') + Spacer() + counts Text — it fit
/// 360 px but overflowed at 320 px or with double-digit counts.
/// The header now has Flexible/ellipsis protection: at 320 px with
/// double-digit counts it must render with no overflow.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:outride/models/link_sample.dart';
import 'package:outride/screens/events_list_screen.dart';
import 'package:outride/state/app_state.dart';
import 'package:outride/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

CrossingEvent _ev(int secs) => CrossingEvent(
      timestamp: DateTime.utc(2026, 10, 16, 12, 0, secs),
      linkKey: 'a → b',
      dipDepth: 8.0,
      durationSecs: 2.0,
      sizeEstimate: 'M',
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('header with double-digit counts fits 320 px, no overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState();
    addTearDown(state.dispose);
    final events = List.generate(12, (i) => _ev(i));
    state.events.addAll(events);
    // ACK 10, FA 1, NEW 1 — double-digit counts.
    for (var i = 0; i < 10; i++) {
      state.triageEvent(events[i], AppState.triageAcked);
    }
    state.triageEvent(events[10], AppState.triageFalseAlarm);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: EventsListScreen(state: state),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('ACK 10 · FA 1 · NEW 1'), findsOneWidget);
    // find.text matches the widget's full string even when the
    // paragraph is ellipsized, so also assert neither header
    // paragraph actually exceeded its max lines (v0.29.2 review:
    // the old 50/50 Row truncated the counts to "N…" at 320 px
    // with no exception). The AppBar title is a second
    // 'CROSSING EVENTS' paragraph — check every match.
    for (final el in find.text('CROSSING EVENTS').evaluate()) {
      final rp = el.renderObject as RenderParagraph;
      expect(rp.didExceedMaxLines, isFalse);
    }
    final countsEl =
        find.text('ACK 10 · FA 1 · NEW 1').evaluate().single;
    final countsRp = countsEl.renderObject as RenderParagraph;
    expect(countsRp.didExceedMaxLines, isFalse);
  });
}

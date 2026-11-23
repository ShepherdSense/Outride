/// Top-bar overflow test (2026-11-23 review fix S15): the
/// EXPERIMENTAL pill + SIMULATED/LIVE pill + OUTRIDE wordmark
/// overflowed a 360 px bar by 81 px before the pill cluster was
/// wrapped in a scale-down FittedBox. The overflow fix previously
/// rested on code reading only — this test pumps the real top bar
/// at 360 px and asserts no overflow and the EXPERIMENTAL pill
/// present.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:outride/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'rf_sentry_zmeta_v1': jsonEncode({'simulatedMode': true}),
    });
  });

  testWidgets('top bar fits 360 px with the EXPERIMENTAL pill present',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const OutrideApp());
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('EXPERIMENTAL'), findsOneWidget);
    expect(find.text('SIMULATED'), findsOneWidget);
    // The wordmark is a RichText ('OUT' + 'RIDE' spans), not a Text
    // widget — find.text does not match it. Match the RichText by
    // its plain text instead.
    final wordmark = find.byWidgetPredicate(
      (w) =>
          w is RichText &&
          w.text.toPlainText() == 'OUTRIDE',
    );
    expect(wordmark, findsOneWidget);
  });
}

/// Desktop-viewport top-bar pill clipping (v0.30.0, item 6).
///
/// The top bar — the OUTRIDE wordmark + SIMULATED / LIVE pill
/// ([AppTopBar]), and the PERIMETER STATUS + LIVE / SIM pill in the
/// Picture banner — must render with no overflow or clipping at
/// desktop viewport sizes (1280×800 and wider). A Row that fits a
/// phone can still clip on desktop when a pill's label, the
/// wordmark, or the banner title competes for the bar's width.
///
/// Both modes are covered: SIMULATED (the default) and LIVE (the
/// one-character-wider label that overflowed a 360 px phone in
/// v0.29.7). The bar is pumped directly ([AppTopBar] is extracted
/// from main.dart precisely so it is testable on its own — main.dart
/// transitively imports the Settings screen and the whole app state).
///
/// Beyond "no RenderFlex overflow", the test also asserts the pill
/// rect sits fully inside the viewport — a pill can be visually cut
/// at the bar's edge without tripping a layout overflow.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:outride/screens/picture_screen.dart';
import 'package:outride/state/app_state.dart';
import 'package:outride/theme.dart';
import 'package:outride/widgets/app_top_bar.dart';

/// The mode pill's rect must sit fully inside [size].
void _expectPillInBounds(WidgetTester tester, Size size) {
  final pill = find.text('SIMULATED').evaluate().isNotEmpty
      ? find.text('SIMULATED')
      : find.text('LIVE');
  expect(pill, findsOneWidget);
  final rect = tester.getRect(pill);
  expect(rect.left, greaterThanOrEqualTo(0));
  expect(rect.right, lessThanOrEqualTo(size.width),
      reason: 'pill must not be cut at the right edge');
  expect(rect.top, greaterThanOrEqualTo(0));
  expect(rect.bottom, lessThanOrEqualTo(size.height));
}

Future<void> _pumpTopBar(
  WidgetTester tester, {
  required Size size,
  required bool simulated,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildDarkTheme(),
      home: Scaffold(
        appBar: AppBar(title: AppTopBar(simulated: simulated)),
        body: const SizedBox(),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _pumpPicture(
  WidgetTester tester, {
  required Size size,
  required bool simulated,
}) async {
  SharedPreferences.setMockInitialValues({
    'rf_sentry_zmeta_v1': jsonEncode({'simulatedMode': simulated}),
  });
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final state = AppState();
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildDarkTheme(),
      home: Scaffold(
        appBar: AppBar(title: AppTopBar(simulated: simulated)),
        body: PictureScreen(state: state),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('top-bar pills at desktop viewports', () {
    testWidgets('1280x800 simulated: no overflow, pill in bounds',
        (tester) async {
      await _pumpTopBar(tester,
          size: const Size(1280, 800), simulated: true);
      expect(tester.takeException(), isNull);
      expect(find.text('SIMULATED'), findsOneWidget);
      _expectPillInBounds(tester, const Size(1280, 800));
    });

    testWidgets('1280x800 live: no overflow, pill in bounds',
        (tester) async {
      await _pumpTopBar(tester,
          size: const Size(1280, 800), simulated: false);
      expect(tester.takeException(), isNull);
      expect(find.text('LIVE'), findsOneWidget);
      _expectPillInBounds(tester, const Size(1280, 800));
    });

    testWidgets('1920x1080 simulated: no overflow, pill in bounds',
        (tester) async {
      await _pumpTopBar(tester,
          size: const Size(1920, 1080), simulated: true);
      expect(tester.takeException(), isNull);
      expect(find.text('SIMULATED'), findsOneWidget);
      _expectPillInBounds(tester, const Size(1920, 1080));
    });

    testWidgets('2560x1440 live: no overflow, pill in bounds',
        (tester) async {
      await _pumpTopBar(tester,
          size: const Size(2560, 1440), simulated: false);
      expect(tester.takeException(), isNull);
      expect(find.text('LIVE'), findsOneWidget);
      _expectPillInBounds(tester, const Size(2560, 1440));
    });

    testWidgets('1280x800 Picture screen: banner pill in bounds',
        (tester) async {
      await _pumpPicture(tester,
          size: const Size(1280, 800), simulated: true);
      expect(tester.takeException(), isNull);
      expect(find.text('PERIMETER STATUS'), findsOneWidget);
      expect(find.text('SIM'), findsOneWidget);
      final rect = tester.getRect(find.text('SIM'));
      expect(rect.right, lessThanOrEqualTo(1280),
          reason: 'banner pill must not be cut at the right edge');
    });

    testWidgets('1920x1080 Picture screen, live: banner pill in bounds',
        (tester) async {
      await _pumpPicture(tester,
          size: const Size(1920, 1080), simulated: false);
      expect(tester.takeException(), isNull);
      expect(find.text('PERIMETER STATUS'), findsOneWidget);
      expect(find.text('LIVE'), findsWidgets);
      final rect = tester.getRect(find.text('LIVE').first);
      expect(rect.right, lessThanOrEqualTo(1920),
          reason: 'banner pill must not be cut at the right edge');
    });
  });
}

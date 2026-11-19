/// Fleet dialer tests (spec §10 item 8).
///
/// PIN state machine (4 digits ⇒ complete, 5th digit ignored,
/// backspace clears one dot, non-digit input impossible) plus a
/// widget test that the pad reports taps and renders four dots.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/fleet_dialer.dart';

void main() {
  group('FleetDialerState', () {
    test('starts empty and incomplete', () {
      final d = FleetDialerState();
      expect(d.digits, '');
      expect(d.length, 0);
      expect(d.isEmpty, isTrue);
      expect(d.isComplete, isFalse);
    });

    test('4 digits ⇒ complete (auto-submit point)', () {
      final d = FleetDialerState();
      expect(d.addDigit('1'), isTrue);
      expect(d.addDigit('2'), isTrue);
      expect(d.addDigit('3'), isTrue);
      expect(d.isComplete, isFalse);
      expect(d.addDigit('4'), isTrue);
      expect(d.digits, '1234');
      expect(d.isComplete, isTrue);
    });

    test('5th digit ignored', () {
      final d = FleetDialerState();
      for (final c in '1234'.split('')) {
        d.addDigit(c);
      }
      expect(d.addDigit('5'), isFalse);
      expect(d.digits, '1234');
    });

    test('backspace clears one dot at a time', () {
      final d = FleetDialerState();
      for (final c in '123'.split('')) {
        d.addDigit(c);
      }
      d.backspace();
      expect(d.digits, '12');
      d.backspace();
      d.backspace();
      expect(d.digits, '');
      expect(d.isEmpty, isTrue);
      d.backspace(); // no-op when empty, never throws
      expect(d.digits, '');
    });

    test('clear empties the PIN', () {
      final d = FleetDialerState();
      for (final c in '1234'.split('')) {
        d.addDigit(c);
      }
      d.clear();
      expect(d.digits, '');
      expect(d.isComplete, isFalse);
    });

    test('non-digit input impossible', () {
      final d = FleetDialerState();
      expect(d.addDigit('a'), isFalse);
      expect(d.addDigit('*'), isFalse);
      expect(d.addDigit(''), isFalse);
      expect(d.addDigit('12'), isFalse);
      expect(d.digits, '');
    });
  });

  group('FleetDialerPad widget', () {
    testWidgets('taps report digits; dots fill; backspace works',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      var digits = '';
      var backspaces = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FleetDialerPad(
              digits: digits,
              onDigit: (d) => digits += d,
              onBackspace: () => backspaces++,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
      expect(find.text('9'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
      expect(find.byIcon(Icons.backspace_outlined), findsOneWidget);
      await tester.tap(find.text('1'));
      await tester.tap(find.text('2'));
      await tester.tap(find.text('3'));
      await tester.tap(find.text('4'));
      expect(digits, '1234');
      await tester.tap(find.byIcon(Icons.backspace_outlined));
      expect(backspaces, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('disabled pad ignores taps', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      var digits = '';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FleetDialerPad(
              digits: digits,
              enabled: false,
              onDigit: (d) => digits += d,
              onBackspace: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('1'));
      await tester.pump();
      expect(digits, '');
      expect(tester.takeException(), isNull);
    });
  });
}

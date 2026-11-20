/// v0.29.2 Settings help tile: all inline explanatory copy moved
/// into a single tile at the bottom of Settings, collapsed by
/// default, tap to expand/collapse. Nothing deleted — the long copy
/// is inside the tile; rows keep at most a short one-line desc.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:outride/screens/settings.dart';
import 'package:outride/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Same drained-exception rig as fetch_voice_settings_test.dart:
/// pumping the whole Settings screen trips two pre-existing debug
/// assertions that have nothing to do with the help tile — the
/// radios driver dropdown overflowing at 360 px ("FETCH (throwable
/// sensor ball)" is wider than the screen) and every SwitchListTile
/// inside an OutridePanel tripping the "ListTile background / ink
/// splashes may be invisible" assertion. They are counted per
/// symptom so a NEW failure mode still shows up in `other`.
class _Drained {
  int radiosOverflow = 0;
  int listTileBackground = 0;
  int other = 0;
}

class _ErrorTrap {
  final List<FlutterErrorDetails> captured = [];
  FlutterExceptionHandler? _old;

  void install() {
    _old = FlutterError.onError;
    final old = _old;
    FlutterError.onError = (details) {
      captured.add(details);
      old?.call(details);
    };
  }

  void uninstall() {
    FlutterError.onError = _old;
  }

  _Drained get counts {
    final out = _Drained();
    for (final d in captured) {
      final msg = '${d.exception}';
      if (msg.contains('overflowed')) {
        out.radiosOverflow++;
      } else if (msg.contains('ink splashes')) {
        out.listTileBackground++;
      } else {
        out.other++;
        debugPrint('settings help tile test: unexpected error: '
            '${d.exception}');
      }
    }
    return out;
  }
}

int _drainExceptions(WidgetTester tester) {
  var n = 0;
  while (tester.takeException() != null) {
    n++;
  }
  return n;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> scrollToHelpTile(WidgetTester tester) async {
    for (var i = 0;
        i < 30 && find.text('SETTINGS HELP').evaluate().isEmpty;
        i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -800));
      await tester.pump();
    }
    await tester.ensureVisible(find.text('SETTINGS HELP'));
    await tester.pump();
  }

  testWidgets('help tile is collapsed by default, expands on tap, '
      'contains the explanations', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState();
    addTearDown(state.dispose);
    final trap = _ErrorTrap()..install();
    addTearDown(trap.uninstall);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SettingsScreen(state: state))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    _drainExceptions(tester);

    await scrollToHelpTile(tester);
    _drainExceptions(tester);
    expect(find.text('SETTINGS HELP'), findsOneWidget);
    expect(find.text('TAP TO EXPAND'), findsOneWidget);
    // Collapsed: the long copy is not in the tree.
    expect(find.textContaining('EACH RADIO IS POLLED INDEPENDENTLY'),
        findsNothing);
    expect(
        find.textContaining('DOWNLOAD A MAP BEFORE YOU LEAVE WI-FI'),
        findsNothing);

    await tester.tap(find.text('SETTINGS HELP'));
    await tester.pump();
    _drainExceptions(tester);
    expect(find.text('TAP TO COLLAPSE'), findsOneWidget);
    // Expanded: every moved explanation is present, verbatim.
    expect(find.textContaining('EACH RADIO IS POLLED INDEPENDENTLY'),
        findsOneWidget);
    expect(
        find.textContaining('DOWNLOAD A MAP BEFORE YOU LEAVE WI-FI'),
        findsOneWidget);
    expect(
        find.textContaining(
            'GUIDED "DIAL IT IN" ROUTINE — EMPLACE NODES'),
        findsOneWidget);
    expect(find.textContaining('Spoken Fetch trip alerts through the EUD'),
        findsOneWidget);
    expect(find.textContaining('A FLEET WITH A LIVE SILVUS RADIO SENSES'),
        findsOneWidget);

    // Tap again: collapses, copy leaves the tree.
    await tester.tap(find.text('SETTINGS HELP'));
    await tester.pump();
    _drainExceptions(tester);
    expect(find.text('TAP TO EXPAND'), findsOneWidget);
    expect(find.textContaining('EACH RADIO IS POLLED INDEPENDENTLY'),
        findsNothing);
    // Only the two known pre-existing Settings issues occurred.
    final counts = trap.counts;
    expect(counts.other, 0,
        reason: 'a new failure mode appeared — see debugPrint above');
    expect(counts.radiosOverflow, greaterThan(0));
    expect(counts.listTileBackground, greaterThan(0));
  });

  testWidgets('rows keep only a short one-line desc', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState();
    addTearDown(state.dispose);
    final trap = _ErrorTrap()..install();
    addTearDown(trap.uninstall);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SettingsScreen(state: state))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    _drainExceptions(tester);

    // The Mode section is near the top: the simulated-mode row now
    // carries one short line; the 'CLEARLY LABELED ON THE
    // DASHBOARD' tail lives in the help tile, not on the row.
    for (var i = 0;
        i < 10 &&
            find
                .text('GENERATE SYNTHETIC LINK DATA — NO HARDWARE NEEDED.')
                .evaluate()
                .isEmpty;
        i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -800));
      await tester.pump();
    }
    expect(
        find.text('GENERATE SYNTHETIC LINK DATA — NO HARDWARE NEEDED.'),
        findsOneWidget);
    expect(find.textContaining('CLEARLY LABELED ON THE DASHBOARD'),
        findsNothing);
    _drainExceptions(tester);
    expect(trap.counts.other, 0,
        reason: 'a new failure mode appeared — see debugPrint above');
  });

  // v0.29.2 review: the old spot-checks (5 strings) let the
  // missing Remote ID entry slip through. This test enumerates
  // EVERY help-tile heading — it fails if any entry is missing.
  testWidgets('help tile contains all 23 entries, including Remote ID',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState();
    addTearDown(state.dispose);
    final trap = _ErrorTrap()..install();
    addTearDown(trap.uninstall);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SettingsScreen(state: state))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    _drainExceptions(tester);

    await scrollToHelpTile(tester);
    await tester.tap(find.text('SETTINGS HELP'));
    await tester.pump();
    _drainExceptions(tester);

    const headings = [
      'Radios',
      'Detector — poll interval',
      'Detector — confirm polls',
      'Wi-Fi sensing — dip threshold',
      'Mesh calibration',
      'SDR station',
      'Simulated mode',
      'Wi-Fi vision',
      'Camera confirmation',
      'Experimental sensors',
      'Fetch voice alerts',
      'Phone-only tier',
      'Device signature library',
      'Offline map packs',
      'Record & replay',
      'Emit CoT tracks',
      'Listen for emitter tracks',
      'Drones — friendly fleet',
      'Remote ID',
      'Drone tab streams',
      'ZMeta export',
      'Fleet',
      'Auto-connect Silvus USB',
    ];
    for (final h in headings) {
      await tester.ensureVisible(find.text(h));
      await tester.pump();
      expect(find.text(h), findsOneWidget, reason: 'missing entry: $h');
    }
    // The Remote ID entry carries the substance of the old inline
    // copy, and the row itself is now one short line.
    expect(
        find.textContaining(
            'MILITARY D-MODEL AIRFRAMES (X10D) MAY BROADCAST NOTHING'),
        findsOneWidget);
    expect(find.textContaining('WI-FI NAN REMOTE ID UNAVAILABLE'),
        findsOneWidget);
    expect(find.textContaining('BLE 5 EXTENDED ADVERTISING'),
        findsOneWidget);
    // The Remote ID row lives above the help tile and the ListView
    // builds rows lazily, so scroll up to it before asserting on it.
    for (var i = 0;
        i < 30 && find.text('REMOTE ID RECEIVER').evaluate().isEmpty;
        i++) {
      await tester.drag(find.byType(ListView), const Offset(0, 800));
      await tester.pump();
    }
    expect(find.text('REMOTE ID RECEIVER'), findsOneWidget);
    expect(
        find.text('DECODE FAA REMOTE ID BROADCASTS (ASTM F3411) — '
            'RECEIVE-ONLY. DEFAULT OFF.'),
        findsOneWidget);
    _drainExceptions(tester);
    expect(trap.counts.other, 0,
        reason: 'a new failure mode appeared — see debugPrint above');
  });
}

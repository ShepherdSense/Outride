/// Settings RADIOS section overflow (reported 2026-11-23 with a phone
/// screenshot): on a 360 px screen the DRIVER dropdown + ADDRESS (IP)
/// row overflowed horizontally by 254 px — Flutter's debug overflow
/// banner painted vertically across the section, covering the DRIVER
/// dropdown (showing "SILVUS") and clipping the "NO RADIOS
/// CONFIGURED." line. The LABEL (OPTIONAL) + "Add radio" row below
/// it fit.
///
/// Root cause: the driver dropdown's longest item, "FETCH (throwable
/// sensor ball)", is wider than the screen, and without `isExpanded`
/// the DropdownButton sizes its button to the widest menu item, so
/// the button insisted on ~570 px inside its ~99 px flex share and
/// overflowed the Row (465 px in the test harness). The fix is
/// `isExpanded: true` on that DropdownButtonFormField — the same
/// pattern as the session-template dropdown in bench_screen — so the
/// button takes its flexed share instead. Same options, same address
/// field, same add-radio behavior; nothing else on the screen
/// changed.
///
/// This test pumps the real Settings screen at 360 px and asserts no
/// overflow, with the dropdown and the address field both present and
/// usable — including with the longest driver label selected.
///
/// NOTE on drained exceptions: pumping the whole Settings screen
/// trips one other pre-existing debug assertion that has nothing to
/// do with the radios row — every SwitchListTile inside an
/// OutridePanel trips the "ListTile background / ink splashes may be
/// invisible" assertion. It is counted per symptom (same rig as
/// fetch_voice_settings_test.dart and settings_help_tile_test.dart)
/// so a NEW failure mode still shows up in `other`. The radios
/// overflow count is asserted to be ZERO here — that is the point
/// of this test.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:outride/screens/settings.dart';
import 'package:outride/state/app_state.dart';
import 'package:outride/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Counts of framework exceptions, by symptom. A NEW failure mode
/// lands in `other` (and is printed) instead of being drained
/// silently. Same rig as fetch_voice_settings_test.dart.
class _Drained {
  int radiosOverflow = 0;
  int listTileBackground = 0;
  int other = 0;
}

/// Captures every FlutterError as it arrives, by wrapping the
/// binding's [FlutterError.onError] handler and forwarding to it.
/// [WidgetTester.takeException] collapses a whole pump batch into
/// one "Multiple exceptions (N)" wrapper object and the individual
/// errors are lost to it, so counting takeException results can
/// never classify a batch. The trap sees each error before any
/// batching. Draining via takeException is still required (an
/// un-taken pending exception fails the test at teardown) — the
/// trap only observes, it never consumes.
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
        debugPrint(
            'settings radios 360 test: unexpected error: ${d.exception}');
      }
    }
    return out;
  }
}

/// Consume all pending framework exceptions (see the file doc) and
/// return how many takeException objects there were. The objects
/// themselves are NOT classified here — see [_ErrorTrap].
int _drainExceptions(WidgetTester tester) {
  var n = 0;
  while (tester.takeException() != null) {
    n++;
  }
  return n;
}

/// Assert the trapped error counts: no RenderFlex overflow at all,
/// no new failure mode, and the known pre-existing SwitchListTile
/// background assertion still occurred (so the counts are live,
/// not vacuous).
void _expectNoRadiosOverflow(_Drained counts) {
  expect(counts.other, 0,
      reason: 'a new failure mode appeared — see debugPrint above');
  expect(counts.radiosOverflow, 0,
      reason: 'the RADIOS driver/address row overflowed at 360 px');
  expect(counts.listTileBackground, greaterThan(0),
      reason: 'expected the known pre-existing SwitchListTile '
          'background assertion — if it is gone, the rig is stale');
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<_ErrorTrap> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState();
    addTearDown(state.dispose);
    final trap = _ErrorTrap()..install();
    addTearDown(trap.uninstall);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: Scaffold(
          body: SettingsScreen(state: state),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    _drainExceptions(tester);
    return trap;
  }

  testWidgets('RADIOS section fits 360 px: no overflow, dropdown + '
      'address field visible', (tester) async {
    final trap = await pumpSettings(tester);
    expect(find.text('NO RADIOS CONFIGURED.'), findsOneWidget);
    // The selected driver shown in the dropdown button.
    expect(find.text('SILVUS'), findsOneWidget);
    // The address field's label (uppercased by the screen's _field).
    expect(find.text('ADDRESS (IP)'), findsOneWidget);
    expect(find.text('Add radio'), findsOneWidget);
    _expectNoRadiosOverflow(trap.counts);
  });

  testWidgets('RADIOS row still fits with the longest driver label '
      'selected', (tester) async {
    final trap = await pumpSettings(tester);
    // Open the driver dropdown and pick the longest label — the
    // item whose width used to drive the overflow. Scoped to the
    // radios dropdown by its current value so a same-typed
    // dropdown further down the screen can never be tapped.
    await tester.tap(
        find.widgetWithText(DropdownButtonFormField<String>, 'SILVUS'));
    await tester.pump();
    await tester.tap(find.text('FETCH (throwable sensor ball)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    _drainExceptions(tester);
    expect(find.text('FETCH (throwable sensor ball)'), findsOneWidget);
    expect(find.text('ADDRESS (IP)'), findsOneWidget);
    expect(find.text('Add radio'), findsOneWidget);
    _expectNoRadiosOverflow(trap.counts);
  });
}

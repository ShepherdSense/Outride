/// Widget tests for the Fetch voice alerts settings: the toggle
/// flips the persisted setting, the speech-rate slider is present,
/// and "Test voice" is disabled while the feature is off or muted.
///
/// The fake synthesizer is never needed here — the toggle path does
/// not touch TTS — but the test proves the Settings screen never
/// constructs the real flutter_tts channel on toggle.
///
/// NOTE on drained exceptions: pumping the whole Settings screen in
/// the test harness trips pre-existing debug assertions that have
/// nothing to do with the voice section. They are drained here
/// (and counted per symptom — see [_Drained] and [_ErrorTrap] — so
/// a NEW failure mode still shows up as a count in `other`, or a
/// change in the known counts) rather than fixed, because the
/// layout is out of scope for the voice-alerts feature; the voice
/// assertions below are what this test owns.
///
/// KNOWN PRE-EXISTING ISSUES (filed here, not fixed in this pass —
/// layout is out of scope):
/// 1. Radios driver dropdown overflows at 360 px: its longest item,
///    "FETCH (throwable sensor ball)", is wider than the screen —
///    a RenderFlex overflow ("A RenderFlex overflowed by … pixels").
/// 2. Every SwitchListTile inside a OutridePanel trips the
///    "ListTile background / ink splashes may be invisible"
///    assertion (OutridePanel is a DecoratedBox, so the tile's ink
///    has no Material background to draw on).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:outride/screens/settings.dart';
import 'package:outride/state/app_state.dart';

/// Counts of framework exceptions, by symptom. A NEW failure mode
/// lands in `other` (and is printed) instead of being drained
/// silently.
class _Drained {
  int radiosOverflow = 0;
  int listTileBackground = 0;
  int other = 0;

  int get total => radiosOverflow + listTileBackground + other;

  void add(_Drained o) {
    radiosOverflow += o.radiosOverflow;
    listTileBackground += o.listTileBackground;
    other += o.other;
  }
}

/// Captures every FlutterError as it arrives, by wrapping the
/// binding's [FlutterError.onError] handler and forwarding to it.
/// This is what makes per-symptom counting possible:
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
            'Fetch voice settings test: unexpected error: ${d.exception}');
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

Future<int> _pumpSettings(
    WidgetTester tester, AppState state) async {
  var drained = 0;
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: SettingsScreen(state: state))),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  drained += _drainExceptions(tester);
  // Scroll to the voice section in steps: scrollUntilVisible trips
  // on this screen (its internal single-element lookup races the
  // ListView's lazy build), so drag until the switch is built.
  final target =
      find.widgetWithText(SwitchListTile, 'FETCH VOICE ALERTS');
  for (var i = 0; i < 20 && target.evaluate().isEmpty; i++) {
    await tester.drag(find.byType(ListView), const Offset(0, -800));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    drained += _drainExceptions(tester);
  }
  await tester.ensureVisible(target.first);
  await tester.pump(const Duration(milliseconds: 100));
  drained += _drainExceptions(tester);
  return drained;
}

/// Assert the trapped error counts: only the two known pre-existing
/// failure modes occurred — a new one would land in `other` — and
/// both known ones did occur, so the counts are live, not vacuous.
void _expectOnlyKnownErrors(_Drained counts) {
  expect(counts.other, 0,
      reason: 'a new failure mode appeared — see debugPrint above');
  expect(counts.radiosOverflow, greaterThan(0));
  expect(counts.listTileBackground, greaterThan(0));
}

void main() {
  testWidgets('voice toggle flips enabled and persists it',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState();
    addTearDown(state.dispose);
    final trap = _ErrorTrap()..install();
    addTearDown(trap.uninstall);
    var drained = await _pumpSettings(tester, state);

    expect(state.fetchVoiceEnabled, isFalse);
    expect(find.text('FETCH VOICE ALERTS'), findsOneWidget);
    // "Test voice" is disabled while the feature is off.
    final testButton = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Test voice'));
    expect(testButton.onPressed, isNull);

    await tester.tap(
        find.widgetWithText(SwitchListTile, 'FETCH VOICE ALERTS').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    drained += _drainExceptions(tester);

    expect(state.fetchVoiceEnabled, isTrue);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('rf_sentry_fetch_voice_v1');
    expect(raw, isNotNull);
    expect(raw, contains('"enabled":true'));

    // "Test voice" is enabled once the feature is on…
    expect(
        tester
            .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Test voice'))
            .onPressed,
        isNotNull);
    // …but disabled while muted (muting must silence the sample too).
    await tester.tap(
        find.widgetWithText(SwitchListTile, 'MUTE').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    drained += _drainExceptions(tester);
    expect(state.fetchVoiceMuted, isTrue);
    expect(
        tester
            .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Test voice'))
            .onPressed,
        isNull);
    // …and enabled again on unmute.
    await tester.tap(
        find.widgetWithText(SwitchListTile, 'MUTE').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    drained += _drainExceptions(tester);
    expect(state.fetchVoiceMuted, isFalse);
    expect(
        tester
            .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Test voice'))
            .onPressed,
        isNotNull);

    // A fresh AppState loads the persisted value.
    final state2 = AppState();
    addTearDown(state2.dispose);
    await tester.pump(const Duration(milliseconds: 200));
    expect(state2.fetchVoiceEnabled, isTrue);
    drained += _drainExceptions(tester);
    expect(drained, greaterThan(0));
    _expectOnlyKnownErrors(trap.counts);
  });

  testWidgets('speech-rate slider and honest-scope copy render',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState();
    addTearDown(state.dispose);
    final trap = _ErrorTrap()..install();
    addTearDown(trap.uninstall);
    var drained = await _pumpSettings(tester, state);

    expect(find.byType(Slider), findsWidgets);
    expect(find.textContaining('SPEECH RATE'), findsOneWidget);
    // v0.29.2: the honest-scope copy moved from the Fetch section
    // into the help tile at the bottom of Settings (collapsed by
    // default) — expand it first, then the copy must be there.
    for (var i = 0;
        i < 20 && find.text('SETTINGS HELP').evaluate().isEmpty;
        i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -800));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.ensureVisible(find.text('SETTINGS HELP'));
    await tester.pump();
    await tester.tap(find.text('SETTINGS HELP'));
    await tester.pump();
    expect(find.textContaining('Direction comes from GPS positions only'),
        findsOneWidget);
    expect(find.textContaining('never identifies anyone as an enemy'),
        findsOneWidget);
    drained += _drainExceptions(tester);
    expect(drained, greaterThan(0));
    _expectOnlyKnownErrors(trap.counts);
  });
}

/// Default-LIVE tests (v0.29.7): fresh installs on real apps open LIVE,
/// a stored operator choice wins on non-web, and the Settings toggle
/// still flips and persists.
///
/// EXPERIMENTAL-BRANCH NOTE: the "web sim always runs simulated" lock
/// is a MAIN-branch invariant (the public sim is built from main, where
/// kIsExperimentalBuild is false). In THIS branch the web artifact is
/// the live-feed experimental build (default LIVE, simulated mode an
/// explicit labeled toggle only), so the AppState/Settings web tests
/// below assert the experimental rule, not the sim lock. The pure
/// resolveSimulatedMode unit tests keep the main behavior (default
/// isExperimentalBuild: false) and are unchanged.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:outride/screens/settings.dart';
import 'package:outride/services/simulated_mode.dart';
import 'package:outride/state/app_state.dart';

void main() {
  group('resolveSimulatedMode', () {
    test('web always simulated, even with a stored false', () {
      expect(resolveSimulatedMode(stored: false, isWeb: true), isTrue);
    });

    test('web always simulated, even with a stored true', () {
      expect(resolveSimulatedMode(stored: true, isWeb: true), isTrue);
    });

    test('web always simulated with no stored value', () {
      expect(resolveSimulatedMode(stored: null, isWeb: true), isTrue);
    });

    test('non-web respects a stored true', () {
      expect(resolveSimulatedMode(stored: true, isWeb: false), isTrue);
    });

    test('non-web respects a stored false', () {
      expect(resolveSimulatedMode(stored: false, isWeb: false), isFalse);
    });

    test('non-web with no stored value defaults to LIVE', () {
      expect(resolveSimulatedMode(stored: null, isWeb: false), isFalse);
      expect(kSimulatedModeFreshDefault, isFalse);
    });
  });

  group('AppSettings simulatedMode default + persistence', () {
    test('fresh AppSettings defaults to LIVE', () {
      expect(AppSettings().simulatedMode, isFalse);
    });

    test('toJson carries the choice and applyJson restores it', () {
      final saved = AppSettings(simulatedMode: true).toJson();
      expect(saved['simulatedMode'], isTrue);
      final restored = AppSettings()..applyJson(saved);
      expect(restored.simulatedMode, isTrue);

      final savedLive = AppSettings(simulatedMode: false).toJson();
      expect(savedLive['simulatedMode'], isFalse);
      final restoredLive = AppSettings()..applyJson(savedLive);
      expect(restoredLive.simulatedMode, isFalse);
    });

    test('applyJson ignores a missing or malformed key', () {
      final missing = AppSettings()..applyJson({});
      expect(missing.simulatedMode, isFalse,
          reason: 'no stored value keeps the fresh default');
      final malformed = AppSettings()..applyJson({'simulatedMode': 'yes'});
      expect(malformed.simulatedMode, isFalse);
      final storedTrue = AppSettings(simulatedMode: true)
        ..applyJson({'simulatedMode': 'yes'});
      expect(storedTrue.simulatedMode, isTrue,
          reason: 'a malformed stored value must not clobber the field');
    });
  });

  group('AppState simulated-mode boot (stored prefs)', () {
    // The boot evals are unawaited and the re-check timers are periodic,
    // so each test disposes its AppState explicitly at the end of the
    // body (not via addTearDown): a timer still pending fails the test.
    // Fake probes keep the boot evals off real sockets.
    Future<bool?> noProbe(String url) async => false;
    Future<bool?> noTunnel() async => false;

    Future<AppState> bootWith(
      WidgetTester tester,
      Map<String, dynamic>? settingsJson, {
      bool isWeb = false,
    }) async {
      SharedPreferences.setMockInitialValues(settingsJson == null
          ? {}
          : {'rf_sentry_zmeta_v1': jsonEncode(settingsJson)});
      final state = AppState(
        cloudflareProbe: noProbe,
        zerotierProbe: noTunnel,
        isWebOverride: isWeb,
      );
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      // Let the async settings load run.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.pump();
      return state;
    }

    testWidgets('fresh install on a real app opens LIVE', (tester) async {
      final state = await bootWith(tester, null);
      expect(state.settings.simulatedMode, isFalse);
      state.dispose();
    });

    testWidgets('fresh install on web opens LIVE in the experimental build',
        (tester) async {
      final state = await bootWith(tester, null, isWeb: true);
      expect(state.settings.simulatedMode, isFalse);
      state.dispose();
    });

    testWidgets('web does NOT force simulated in the experimental build',
        (tester) async {
      SharedPreferences.setMockInitialValues(
          {'rf_sentry_zmeta_v1': jsonEncode({'simulatedMode': false})});
      final state = AppState(
        cloudflareProbe: noProbe,
        zerotierProbe: noTunnel,
        isWebOverride: true,
      );
      // Synchronous: the constructor-body web force is skipped for the
      // experimental build, so a web AppState starts LIVE.
      expect(state.settings.simulatedMode, isFalse);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.pump();
      expect(state.settings.simulatedMode, isFalse,
          reason: 'the load must not force simulated on web in this build');
      state.dispose();
    });

    testWidgets('stored true is respected on a real app', (tester) async {
      final state =
          await bootWith(tester, {'simulatedMode': true});
      expect(state.settings.simulatedMode, isTrue);
      state.dispose();
    });

    testWidgets('stored false is respected on a real app', (tester) async {
      final state =
          await bootWith(tester, {'simulatedMode': false});
      expect(state.settings.simulatedMode, isFalse);
      state.dispose();
    });

    testWidgets('stored false is respected on web in the experimental build',
        (tester) async {
      final state = await bootWith(tester, {'simulatedMode': false},
          isWeb: true);
      expect(state.settings.simulatedMode, isFalse);
      state.dispose();
    });

    testWidgets('no stored key keeps the fresh default on a real app',
        (tester) async {
      // Stored settings exist, but carry no simulatedMode (every
      // install saved before v0.29.7): the fresh default applies.
      final state = await bootWith(tester, {'zmetaEnabled': false});
      expect(state.settings.simulatedMode, isFalse);
      state.dispose();
    });

    testWidgets('applySettings flips and persists the choice',
        (tester) async {
      final state = await bootWith(tester, null);
      expect(state.settings.simulatedMode, isFalse);
      state.applySettings(AppSettings(simulatedMode: true));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
      expect(state.settings.simulatedMode, isTrue);
      // The choice survived the async save to SharedPreferences.
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('rf_sentry_zmeta_v1');
      expect(raw, isNotNull);
      expect(
          (jsonDecode(raw!) as Map<String, dynamic>)['simulatedMode'],
          isTrue);
      // And a fresh boot with those prefs loads it back.
      final state2 = await bootWith(
          tester, jsonDecode(raw) as Map<String, dynamic>);
      expect(state2.settings.simulatedMode, isTrue);
      state.dispose();
      state2.dispose();
    });

    testWidgets('applySettings can set simulated mode on web in the experimental build',
        (tester) async {
      // Experimental-branch rule (the web sim lock lives on main): the
      // experimental web build is a live-feed client, so the toggle
      // works on web and applySettings must not force simulated.
      final state = await bootWith(tester, null, isWeb: true);
      expect(state.settings.simulatedMode, isFalse);
      state.applySettings(AppSettings(simulatedMode: true));
      expect(state.settings.simulatedMode, isTrue);
      state.applySettings(AppSettings(simulatedMode: false));
      expect(state.settings.simulatedMode, isFalse,
          reason: 'applySettings must not force simulated on web here');
      // The choice persists, so a reload keeps it too.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('rf_sentry_zmeta_v1');
      expect(raw, isNotNull);
      expect(
          (jsonDecode(raw!) as Map<String, dynamic>)['simulatedMode'],
          isFalse);
      state.dispose();
    });
  });

  group('Settings SIMULATED MODE toggle', () {
    testWidgets('flipping the switch and saving persists simulated mode',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState(
        cloudflareProbe: (_) async => false,
        zerotierProbe: () async => false,
      );
      expect(state.settings.simulatedMode, isFalse,
          reason: 'a fresh install starts LIVE');

      // The screen carries pre-existing debug-only layout warnings
      // (ListTile ink under a DecoratedBox; a dropdown wider than its
      // slot) that the test framework records as exceptions on any
      // pump of this screen, before and after this fix. Drain them so
      // the test asserts on the toggle behavior, not on the screen's
      // layout — the expects below still fail if the toggle misbehaves.
      void drainLayoutWarnings() {
        while (tester.takeException() != null) {}
      }

      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: SettingsScreen(state: state))));
      await tester.pump();
      drainLayoutWarnings();

      // The screen is a long lazily-built ListView: the switch does
      // not exist until scrolled to. (The scrollable must be named:
      // the screen's multiline text fields build their own internal
      // Scrollables — so target the ListView's own one, the first
      // Scrollable under it.)
      await tester.scrollUntilVisible(find.text('SIMULATED MODE'), 500,
          scrollable: find
              .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable))
              .first);
      await tester.pump();
      drainLayoutWarnings();
      await tester.tap(find.text('SIMULATED MODE'));
      await tester.pump();
      drainLayoutWarnings();
      await tester.scrollUntilVisible(find.text('Save settings'), 500,
          scrollable: find
              .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable))
              .first);
      await tester.pump();
      drainLayoutWarnings();
      await tester.tap(find.text('Save settings'));
      await tester.pump();
      drainLayoutWarnings();
      expect(state.settings.simulatedMode, isTrue,
          reason: 'saving with the switch on must flip the mode');
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('rf_sentry_zmeta_v1');
      expect(
          (jsonDecode(raw!) as Map<String, dynamic>)['simulatedMode'],
          isTrue,
          reason: 'the flipped choice must persist');
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      state.dispose();
    });

    testWidgets('on web the switch is ENABLED in the experimental build',
        (tester) async {
      // Experimental-branch rule (the web sim lock lives on main): the
      // experimental web build is a live-feed client, default LIVE, so
      // the SIMULATED MODE switch works on web. It starts LIVE; tapping
      // the row and saving flips it to simulated and persists.
      SharedPreferences.setMockInitialValues({});
      final state = AppState(
        cloudflareProbe: (_) async => false,
        zerotierProbe: () async => false,
        isWebOverride: true,
      );
      expect(state.settings.simulatedMode, isFalse,
          reason: 'a web AppState starts LIVE in this build');

      void drainLayoutWarnings() {
        while (tester.takeException() != null) {}
      }

      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: SettingsScreen(state: state))));
      await tester.pump();
      drainLayoutWarnings();

      await tester.scrollUntilVisible(find.text('SIMULATED MODE'), 500,
          scrollable: find
              .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable))
              .first);
      await tester.pump();
      drainLayoutWarnings();
      // Enabled on web in this build: the toggle works, and the web
      // sim lock note is absent.
      final tile = tester.widget<SwitchListTile>(find.ancestor(
          of: find.text('SIMULATED MODE'),
          matching: find.byType(SwitchListTile)));
      expect(tile.onChanged, isNotNull);
      expect(find.text('THE WEB SIM ALWAYS RUNS SIMULATED.'),
          findsNothing);
      // Tapping the row and saving flips it to simulated and persists.
      await tester.tap(find.text('SIMULATED MODE'));
      await tester.pump();
      drainLayoutWarnings();
      await tester.scrollUntilVisible(find.text('Save settings'), 500,
          scrollable: find
              .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable))
              .first);
      await tester.pump();
      drainLayoutWarnings();
      await tester.tap(find.text('Save settings'));
      await tester.pump();
      drainLayoutWarnings();
      expect(state.settings.simulatedMode, isTrue);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      state.dispose();
    });
  });
}

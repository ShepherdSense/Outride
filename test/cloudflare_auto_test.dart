/// Cloudflare auto-path tests: the pure transport selection, the
/// ingest-host probe (loopback only — no internet needed), and the
/// AppState boot/toggle/manual wiring (stored fake ingest URL, never a
/// real Cloudflare hostname — the hub is not behind Cloudflare yet).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:outride/screens/settings.dart';
import 'package:outride/services/cloudflare_auto.dart';
import 'package:outride/state/app_state.dart';

const _cfUrl = 'https://hub.example.com/ingest';
const _fpCloudflare = '-';
const _fpPinned =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  group('isCloudflareIngestUrl', () {
    test('https URL + Cloudflare certfp is a Cloudflare path', () {
      expect(isCloudflareIngestUrl(_cfUrl, _fpCloudflare), isTrue);
    });

    test('same URL with a pinned certfp is not a Cloudflare path', () {
      expect(isCloudflareIngestUrl(_cfUrl, _fpPinned), isFalse);
    });

    test('plain HTTP loopback is not a Cloudflare path', () {
      expect(
          isCloudflareIngestUrl('http://127.0.0.1:8080/ingest', _fpCloudflare),
          isFalse);
    });

    test('empty URL is not a Cloudflare path', () {
      expect(isCloudflareIngestUrl('', _fpCloudflare), isFalse);
    });

    test('malformed URL is not a Cloudflare path', () {
      expect(isCloudflareIngestUrl('not a url', _fpCloudflare), isFalse);
    });

    test('URL without a host is not a Cloudflare path', () {
      expect(isCloudflareIngestUrl('https://', _fpCloudflare), isFalse);
    });

    test('scheme match is case-insensitive', () {
      expect(isCloudflareIngestUrl('HTTPS://hub.example.com/x', _fpCloudflare),
          isTrue);
    });
  });

  group('selectZmetaTransport', () {
    ({String transport, String reason}) select({
      String current = 'udp',
      String joined = '',
      String url = _cfUrl,
      String fp = _fpCloudflare,
      bool? reachable,
      bool auto = true,
    }) =>
        selectZmetaTransport(
          currentTransport: current,
          joinedPlatformId: joined,
          ingestUrl: url,
          ingestFp: fp,
          internetReachable: reachable,
          autoEnabled: auto,
        );

    test('online + Cloudflare URL + auto on selects https', () {
      final d = select(reachable: true);
      expect(d.transport, 'https');
      expect(d.reason, 'active');
    });

    test('online + Cloudflare URL + auto on keeps https', () {
      final d = select(current: 'https', reachable: true);
      expect(d.transport, 'https');
      expect(d.reason, 'active');
    });

    test('online + Cloudflare URL + auto off stays put (auto-off)', () {
      final d = select(reachable: true, auto: false);
      expect(d.transport, 'udp');
      expect(d.reason, 'auto-off');
    });

    test('online + Cloudflare URL + auto off keeps a manual https', () {
      final d = select(current: 'https', reachable: true, auto: false);
      expect(d.transport, 'https');
      expect(d.reason, 'active');
    });

    test('offline + Cloudflare URL leaves udp alone', () {
      final d = select(reachable: false);
      expect(d.transport, 'udp');
      expect(d.reason, 'offline');
    });

    test('offline + Cloudflare URL never flips https away', () {
      final d = select(current: 'https', reachable: false);
      expect(d.transport, 'https');
      expect(d.reason, 'offline');
    });

    test('probe failure leaves udp alone', () {
      final d = select(reachable: false, auto: false);
      expect(d.transport, 'udp');
      expect(d.reason, 'offline');
    });

    test('WireGuard joined is never overridden, online or offline', () {
      for (final reachable in [true, false, null]) {
        final d = select(
            current: 'wireguard', joined: 'outride-mesh-1', reachable: reachable);
        expect(d.transport, 'wireguard', reason: 'reachable=$reachable');
        expect(d.reason, 'wireguard', reason: 'reachable=$reachable');
      }
    });

    test('no stored URL leaves the transport alone', () {
      for (final reachable in [true, false, null]) {
        final d = select(url: '', reachable: reachable);
        expect(d.transport, 'udp', reason: 'reachable=$reachable');
        expect(d.reason, 'not configured', reason: 'reachable=$reachable');
      }
    });

    test('pinned-certfp URL leaves the transport alone', () {
      final d = select(fp: _fpPinned, reachable: true);
      expect(d.transport, 'udp');
      expect(d.reason, 'not configured');
    });

    test('malformed URL leaves the transport alone', () {
      final d = select(url: 'not a url', reachable: true);
      expect(d.transport, 'udp');
      expect(d.reason, 'not configured');
    });

    test('probe unavailable (web) leaves the transport alone', () {
      final d = select(reachable: null);
      expect(d.transport, 'udp');
      expect(d.reason, 'unavailable');
    });

    test('wireguard transport without a joined id is not a join', () {
      // Rule (a) protects a WireGuard JOIN (transport + stored joined
      // platform id). A bare 'wireguard' transport with no joined id
      // (e.g. the legacy 10.99. migration) is not a join, so the
      // auto-path may still select https.
      final d = select(current: 'wireguard', joined: '', reachable: true);
      expect(d.transport, 'https');
      expect(d.reason, 'active');
    });
  });

  group('probeCloudflareIngest (loopback only)', () {
    late ServerSocket server;

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async {
      await server.close();
    });

    test('answering host returns true', () async {
      final url = 'https://127.0.0.1:${server.port}/ingest';
      expect(await probeCloudflareIngest(url,
          timeout: const Duration(seconds: 2)), isTrue);
    });

    test('closed port returns false', () async {
      final port = server.port;
      await server.close();
      final url = 'https://127.0.0.1:$port/ingest';
      expect(await probeCloudflareIngest(url,
          timeout: const Duration(seconds: 2)), isFalse);
    });

    test('malformed URL returns false', () async {
      expect(await probeCloudflareIngest('not a url',
          timeout: const Duration(seconds: 2)), isFalse);
    });
  });

  group('AppState Cloudflare wiring (stored fake ingest URL)', () {
    // The widget tests inject a fake probe: the real probe opens a
    // real socket, whose refused-connect error never delivers inside
    // flutter_test's fake-async zone (a closed-port probe hangs the
    // widget test instead of failing fast). The real probe is covered
    // by the loopback group above; here the fake also records the URL
    // it was asked to probe, proving the eval targets the stored hub.
    const cfUrl = 'https://127.0.0.1:9/ingest';

    Map<String, dynamic> settings({
      String transport = 'udp',
      String joined = '',
      bool auto = true,
    }) =>
        {
          'zmetaEnabled': true,
          'zmetaTransport': transport,
          'zmetaJoinedPlatformId': joined,
          'zmetaIngestUrl': cfUrl,
          'zmetaIngestFp': '-',
          'zmetaCloudflareAuto': auto,
        };

    Future<AppState> bootWith(
      WidgetTester tester,
      Map<String, dynamic> settingsJson, {
      required Future<bool?> Function(String url) probe,
      required List<String> probedUrls,
    }) async {
      SharedPreferences.setMockInitialValues({
        'rf_sentry_zmeta_v1': jsonEncode(settingsJson),
      });
      final state = AppState(cloudflareProbe: (url) async {
        probedUrls.add(url);
        return probe(url);
      });
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      // Let the async settings load + boot evaluation run.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.pump();
      return state;
    }

    // NOTE: each test disposes its AppState explicitly at the end of
    // the body (not via addTearDown): the boot evaluation starts a
    // 5-minute periodic re-check timer, and the framework fails a
    // test that ends with a timer still pending — tearDown runs too
    // late for that check.

    testWidgets('boot with hub up flips udp to https and records the fallback',
        (tester) async {
      final probedUrls = <String>[];
      final state = await bootWith(tester, settings(),
          probe: (_) async => true, probedUrls: probedUrls);
      expect(probedUrls, [cfUrl],
          reason: 'the probe must target the stored ingest host');
      expect(state.settings.zmetaTransport, 'https');
      expect(state.cloudflarePathActive, isTrue);
      expect(state.cloudflarePathReason, 'active');
      expect(state.settings.zmetaPreCloudflareTransport, 'udp');
      state.dispose();
    });

    testWidgets('boot with hub down stays on udp and reports offline',
        (tester) async {
      final probedUrls = <String>[];
      final state = await bootWith(tester, settings(),
          probe: (_) async => false, probedUrls: probedUrls);
      expect(probedUrls, [cfUrl]);
      expect(state.settings.zmetaTransport, 'udp');
      expect(state.cloudflarePathActive, isFalse);
      expect(state.cloudflarePathReason, 'offline');
      state.dispose();
    });

    testWidgets('boot with WireGuard joined never flips, hub up or not',
        (tester) async {
      var probes = 0;
      final state = await bootWith(
          tester,
          settings(transport: 'wireguard', joined: 'outride-mesh-1'),
          probe: (_) async {
            probes++;
            return true;
          },
          probedUrls: <String>[]);
      expect(probes, 0,
          reason: 'WireGuard joined must skip the probe entirely');
      expect(state.settings.zmetaTransport, 'wireguard');
      expect(state.cloudflarePathActive, isFalse);
      expect(state.cloudflarePathReason, 'wireguard');
      state.dispose();
    });

    testWidgets('turning auto off falls back to the pre-flip transport',
        (tester) async {
      final state = await bootWith(tester, settings(),
          probe: (_) async => true, probedUrls: <String>[]);
      expect(state.settings.zmetaTransport, 'https');
      await state.setCloudflareAuto(false);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
      expect(state.settings.zmetaTransport, 'udp',
          reason: 'auto-off must restore the transport from before the flip');
      expect(state.cloudflarePathActive, isFalse);
      expect(state.cloudflarePathReason, 'auto-off');
      expect(state.settings.zmetaPreCloudflareTransport, isEmpty,
          reason: 'the recorded fallback is consumed on restore');
      state.dispose();
    });

    testWidgets('manual connect works with auto off when the hub is up',
        (tester) async {
      final state = await bootWith(tester, settings(auto: false),
          probe: (_) async => true, probedUrls: <String>[]);
      expect(state.settings.zmetaTransport, 'udp');
      expect(state.cloudflarePathReason, 'auto-off');
      final connected = await state.connectCloudflarePathManually();
      await tester.pump();
      expect(connected, isTrue);
      expect(state.settings.zmetaTransport, 'https');
      expect(state.cloudflarePathActive, isTrue);
      expect(state.cloudflarePathReason, 'active');
      state.dispose();
    });

    testWidgets('manual connect with the hub down changes nothing',
        (tester) async {
      final state = await bootWith(tester, settings(auto: false),
          probe: (_) async => false, probedUrls: <String>[]);
      final connected = await state.connectCloudflarePathManually();
      await tester.pump();
      expect(connected, isFalse);
      expect(state.settings.zmetaTransport, 'udp');
      expect(state.cloudflarePathActive, isFalse);
      expect(state.cloudflarePathReason, 'offline');
      state.dispose();
    });

    testWidgets(
        'Settings save keeps the recorded pre-flip transport (review fix 1)',
        (tester) async {
      final state = await bootWith(tester, settings(),
          probe: (_) async => true, probedUrls: <String>[]);
      expect(state.settings.zmetaTransport, 'https');
      expect(state.settings.zmetaPreCloudflareTransport, 'udp');
      // Open the real Settings screen and save exactly as the operator
      // would: the save rebuilds the whole AppSettings object, and the
      // recorded fallback must survive it. (The screen is a Scaffold
      // body in the app, so the test wraps it the same way, at a
      // desktop-sized surface.)
      //
      // The screen carries pre-existing debug-only layout warnings
      // (ListTile ink under a DecoratedBox; a dropdown wider than its
      // slot) that the test framework records as exceptions on any
      // pump of this screen, before and after this fix. Drain them so
      // the test asserts on the save behavior, not on the screen's
      // layout — the expects below still fail if the save misbehaves.
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
      // The screen is a long lazily-built ListView: the save button
      // at the bottom does not exist until scrolled to. (The scrollable
      // must be named: the screen's multiline text fields build their
      // own internal Scrollables — so target the ListView's own one,
      // the first Scrollable under it.)
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
      expect(state.settings.zmetaPreCloudflareTransport, 'udp',
          reason: 'a routine Settings save must not wipe the recorded fallback');
      // Unmount the screen first (it holds an AppState listener),
      // then turn auto-use off: the fallback must still be there.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await state.setCloudflareAuto(false);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
      expect(state.settings.zmetaTransport, 'udp',
          reason: 'auto-off must still fall back after a Settings save');
      state.dispose();
    });

    testWidgets(
        'a WireGuard join landing mid-probe is never flipped away (review fix 2)',
        (tester) async {
      final probedUrls = <String>[];
      late AppState state;
      SharedPreferences.setMockInitialValues({
        'rf_sentry_zmeta_v1': jsonEncode(settings()),
      });
      state = AppState(cloudflareProbe: (url) async {
        probedUrls.add(url);
        // The operator joins WireGuard while the probe is in flight.
        state.settings.zmetaTransport = 'wireguard';
        state.settings.zmetaJoinedPlatformId = 'outride-mesh-1';
        return true;
      });
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.pump();
      expect(probedUrls, contains(cfUrl),
          reason: 'the probe started before the join landed');
      expect(state.settings.zmetaTransport, 'wireguard',
          reason: 'a mid-probe WireGuard join must never be flipped to https');
      expect(state.settings.zmetaJoinedPlatformId, 'outride-mesh-1');
      expect(state.cloudflarePathActive, isFalse);
      expect(state.cloudflarePathReason, 'wireguard');
      expect(state.settings.zmetaPreCloudflareTransport, isEmpty,
          reason: 'no flip happened, so no fallback was recorded');
      state.dispose();
    });

    testWidgets('toggle-off after a manual connect leaves transport on https',
        (tester) async {
      final state = await bootWith(tester, settings(auto: false),
          probe: (_) async => true, probedUrls: <String>[]);
      expect(state.settings.zmetaTransport, 'udp');
      expect(state.cloudflarePathReason, 'auto-off');
      final connected = await state.connectCloudflarePathManually();
      await tester.pump();
      expect(connected, isTrue);
      expect(state.settings.zmetaTransport, 'https');
      expect(state.settings.zmetaPreCloudflareTransport, isEmpty,
          reason: 'a manual flip records no fallback');
      // Turning auto-use off must not fall back: the operator chose
      // this transport by hand, the auto-path never flipped it.
      await state.setCloudflareAuto(false);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
      expect(state.settings.zmetaTransport, 'https');
      expect(state.cloudflarePathReason, 'active');
      state.dispose();
    });

    testWidgets('re-check timer at boot connects a hub that comes up later',
        (tester) async {
      var hubUp = false;
      final probedUrls = <String>[];
      final state = await bootWith(tester, settings(),
          probe: (_) async => hubUp, probedUrls: probedUrls);
      expect(state.settings.zmetaTransport, 'udp');
      expect(state.cloudflarePathReason, 'offline');
      expect(probedUrls, [cfUrl]);
      // The hub comes up later — no one opens Settings.
      hubUp = true;
      await tester.pump(kCloudflareRecheckInterval);
      await tester.pump();
      expect(probedUrls, [cfUrl, cfUrl],
          reason: 'the 5-minute re-check must probe again on its own');
      expect(state.settings.zmetaTransport, 'https');
      expect(state.cloudflarePathActive, isTrue);
      expect(state.cloudflarePathReason, 'active');
      expect(state.settings.zmetaPreCloudflareTransport, 'udp');
      state.dispose();
    });

    testWidgets('a settings save restarts the re-check timer',
        (tester) async {
      final probedUrls = <String>[];
      final state = await bootWith(tester, settings(),
          probe: (_) async => false, probedUrls: probedUrls);
      expect(probedUrls, [cfUrl]);
      expect(state.settings.zmetaTransport, 'udp');
      // 4 minutes pass with the hub still down — no re-check yet.
      await tester.pump(const Duration(minutes: 4));
      await tester.pump();
      expect(probedUrls, [cfUrl]);
      // A routine save: it re-evaluates once now (probe 2) and
      // restarts the 5-minute timer from the save, not from boot.
      state.applySettings(state.settings);
      await tester.pump();
      await tester.pump();
      expect(probedUrls, [cfUrl, cfUrl]);
      // 4 more minutes — still no re-check: the timer restarted at
      // the save.
      await tester.pump(const Duration(minutes: 4));
      await tester.pump();
      expect(probedUrls, [cfUrl, cfUrl]);
      // 1 more minute — 5 minutes after the save — the re-check fires.
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      expect(probedUrls, [cfUrl, cfUrl, cfUrl]);
      expect(state.settings.zmetaTransport, 'udp');
      expect(state.cloudflarePathReason, 'offline');
      state.dispose();
    });
  });
}

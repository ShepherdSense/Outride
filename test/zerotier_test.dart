/// ZeroTier compatibility tests: the tunnel detector, the node-ID
/// validation, the hub-error mappings, the Cloudflare never-overrides-
/// ZeroTier guard, the 10.99.0/10.99.1 migration split, and the
/// AppState auto-connect wiring (stored fake join, never a real
/// ZeroTier network — no real network ID exists yet; the only 16-hex
/// ID in the workspace is the hub suite's TEST id, which is never used
/// here: the fake network ID below is a different made-up value).
///
/// Live-hub items from ZEROTIER_JOIN_SPEC.md §6 that CANNOT run here
/// (no real network, hub liveness unknown): the actual redeem against
/// a hub (items 3, 5, 6, 9) and a real tunnel coming up (item 6's "no
/// events flow" half). Those need Draco's real network + a live hub.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:outride/services/cloudflare_auto.dart';
import 'package:outride/services/zmeta_pairing.dart';
import 'package:outride/services/zerotier_detect.dart';
import 'package:outride/state/app_state.dart';

const _ztNetworkId = '0123456789abcdef';
const _ztNodeId = '1a2b3c4d5e';
const _ztIp = '10.99.1.11';
const _ztTarget = '10.99.1.1:5555';
const _cfUrl = 'https://127.0.0.1:9/ingest';

void main() {
  group('isZerotierAddress', () {
    test('mesh addresses in 10.99.1.0/24 match', () {
      expect(isZerotierAddress('10.99.1.1'), isTrue);
      expect(isZerotierAddress('10.99.1.11'), isTrue);
      expect(isZerotierAddress('10.99.1.254'), isTrue);
    });

    test('the WireGuard pool 10.99.0.0/24 does not match', () {
      expect(isZerotierAddress('10.99.0.1'), isFalse);
      expect(isZerotierAddress('10.99.0.11'), isFalse);
    });

    test('other subnets and malformed text do not match', () {
      expect(isZerotierAddress('10.99.2.1'), isFalse);
      expect(isZerotierAddress('192.168.1.5'), isFalse);
      expect(isZerotierAddress('127.0.0.1'), isFalse);
      expect(isZerotierAddress('10.99.1.256'), isFalse);
      expect(isZerotierAddress('10.99.1.01'), isFalse);
      expect(isZerotierAddress('10.99.1'), isFalse);
      expect(isZerotierAddress(''), isFalse);
      expect(isZerotierAddress('not an address'), isFalse);
    });
  });

  group('zerotierTunnelUp (injected interfaces)', () {
    test('true when a 10.99.1.x address is present', () async {
      expect(
          await zerotierTunnelUp(listAddresses: () async =>
              ['192.168.1.5', '10.99.1.11', '172.17.97.10']),
          isTrue);
    });

    test('false when only other addresses are present', () async {
      expect(
          await zerotierTunnelUp(listAddresses: () async =>
              ['192.168.1.5', '10.99.0.11', '127.0.0.1']),
          isFalse);
    });

    test('false on an empty interface list', () async {
      expect(
          await zerotierTunnelUp(listAddresses: () async => []),
          isFalse);
    });

    test('local address helper returns the ZeroTier address', () async {
      expect(
          await zerotierLocalAddress(listAddresses: () async =>
              ['192.168.1.5', '10.99.1.11']),
          '10.99.1.11');
      expect(
          await zerotierLocalAddress(listAddresses: () async =>
              ['192.168.1.5']),
          isNull);
    });
  });

  group('zmetaValidateZerotierNodeId', () {
    test('accepts exactly 10 hex chars, lower-cased', () {
      expect(zmetaValidateZerotierNodeId('1a2b3c4d5e'), '1a2b3c4d5e');
      expect(zmetaValidateZerotierNodeId('1A2B3C4D5E'), '1a2b3c4d5e');
      expect(zmetaValidateZerotierNodeId('  1a2b3c4d5e  '), '1a2b3c4d5e');
    });

    test('rejects anything else with the plain operator message', () {
      for (final bad in [
        '',
        '1a2b3c4d5',
        '1a2b3c4d5e6f',
        '1a2b3c4d5g',
        'zzzzzzzzzz',
        '1a2b 3c4d5e',
      ]) {
        expect(
          () => zmetaValidateZerotierNodeId(bad),
          throwsA(isA<ZmetaPairingException>().having(
              (e) => e.message, 'message', contains('10 hex characters'))),
          reason: 'node ID "$bad" must be rejected',
        );
      }
    });
  });

  group('zmetaIsValidIpv4', () {
    test('accepts plain dotted quads', () {
      expect(zmetaIsValidIpv4('10.99.1.11'), isTrue);
      expect(zmetaIsValidIpv4('0.0.0.0'), isTrue);
      expect(zmetaIsValidIpv4('255.255.255.255'), isTrue);
    });

    test('rejects leading zeros, out-of-range, and junk', () {
      expect(zmetaIsValidIpv4('10.99.1.01'), isFalse);
      expect(zmetaIsValidIpv4('10.99.1.256'), isFalse);
      expect(zmetaIsValidIpv4('10.99.1'), isFalse);
      expect(zmetaIsValidIpv4('10.99.1.1\n'), isFalse);
      expect(zmetaIsValidIpv4(''), isFalse);
    });
  });

  group('zmetaHumanizeHubError — ZeroTier refusals (spec §2)', () {
    test('every ZeroTier error maps to the spec wording', () {
      expect(zmetaHumanizeHubError('bad_zerotier_node_id'),
          'Node ID format is wrong — 10 hex characters.');
      expect(zmetaHumanizeHubError('zerotier_not_configured'),
          contains('ZeroTier turned off'));
      expect(zmetaHumanizeHubError('zt_node_taken'),
          contains('already paired to another mesh'));
      expect(zmetaHumanizeHubError('zerotier_not_authorized'),
          contains('not approved in the ZeroTier controller'));
      expect(zmetaHumanizeHubError('zerotier_no_managed_ip'),
          contains('no managed IP'));
      expect(zmetaHumanizeHubError('zerotier_controller_error'),
          contains('could not reach the ZeroTier controller'));
      expect(zmetaHumanizeHubError('zerotier_ip_taken'),
          contains('already allocated to another mesh'));
      expect(zmetaHumanizeHubError('zerotier_gateway_ip_mismatch'),
          contains('does not hold its ZeroTier gateway IP'));
      expect(zmetaHumanizeHubError('pool_exhausted', zerotier: true),
          'The hub is out of ZeroTier addresses. Tell the hub operator.');
    });

    test('pool_exhausted keeps the WireGuard wording off ZeroTier', () {
      expect(zmetaHumanizeHubError('pool_exhausted'),
          contains('out of tunnel addresses'));
    });

    test('non-ZeroTier errors still map as before', () {
      expect(zmetaHumanizeHubError('expired'),
          contains('has expired'));
      expect(zmetaHumanizeHubError('bad_platform_id'),
          contains('platform ID is invalid'));
    });
  });

  group('selectZmetaTransport — never override ZeroTier (rule 3)', () {
    test('ZeroTier joined stays ZeroTier with the hub up and auto on', () {
      final d = selectZmetaTransport(
        currentTransport: 'zerotier',
        joinedPlatformId: 'outride-mesh-1',
        ingestUrl: _cfUrl,
        ingestFp: '-',
        internetReachable: true,
        autoEnabled: true,
      );
      expect(d.transport, 'zerotier');
      expect(d.reason, 'zerotier');
    });

    test('ZeroTier without a stored join falls through to https', () {
      final d = selectZmetaTransport(
        currentTransport: 'zerotier',
        joinedPlatformId: '',
        ingestUrl: _cfUrl,
        ingestFp: '-',
        internetReachable: true,
        autoEnabled: true,
      );
      expect(d.transport, 'https');
      expect(d.reason, 'active');
    });

    test('WireGuard guard still holds', () {
      final d = selectZmetaTransport(
        currentTransport: 'wireguard',
        joinedPlatformId: 'outride-mesh-1',
        ingestUrl: _cfUrl,
        ingestFp: '-',
        internetReachable: true,
        autoEnabled: true,
      );
      expect(d.transport, 'wireguard');
      expect(d.reason, 'wireguard');
    });
  });

  group('zmetaJoinLinkMode — malformed ZeroTier target never pops zerotier',
      () {
    test('network ID with a usable target pops zerotier', () {
      expect(
          zmetaJoinLinkMode(
              zerotierReturned: true,
              zerotierTarget: _ztTarget,
              ingestMode: false),
          'zerotier');
    });

    test('network ID with a missing target falls back to wireguard', () {
      expect(
          zmetaJoinLinkMode(
              zerotierReturned: true, zerotierTarget: '', ingestMode: false),
          'wireguard');
    });

    test('network ID with a malformed target falls back to wireguard', () {
      // Hub with ZeroTier on but the target unset or mistyped in
      // pairing.conf: a bare host, garbage, and out-of-range ports
      // all drop the join to the WireGuard path instead of popping a
      // ZeroTier join with an empty target — which would point the
      // emitter at whatever host was stored before the join while the
      // UI claims the mesh joined over ZeroTier.
      for (final bad in [
        '10.99.1.1',
        'garbage',
        '10.99.1.1:0',
        '10.99.1.1:99999',
      ]) {
        expect(
            zmetaJoinLinkMode(
                zerotierReturned: true,
                zerotierTarget: bad,
                ingestMode: false),
            'wireguard',
            reason: 'target "$bad" must never pop as zerotier');
      }
    });

    test('malformed target with ingest mode falls back to https', () {
      expect(
          zmetaJoinLinkMode(
              zerotierReturned: true, zerotierTarget: '', ingestMode: true),
          'https');
    });

    test('no ZeroTier fields is the predate-ZeroTier fallback', () {
      expect(
          zmetaJoinLinkMode(
              zerotierReturned: false,
              zerotierTarget: '',
              ingestMode: false),
          'wireguard');
      expect(
          zmetaJoinLinkMode(
              zerotierReturned: false,
              zerotierTarget: '',
              ingestMode: true),
          'https');
    });
  });

  group('AppState migration — 10.99.0 vs 10.99.1 split', () {
    Map<String, dynamic> stored({
      String transport = 'udp',
      String host = '127.0.0.1',
    }) =>
        {
          'zmetaEnabled': false,
          'zmetaTransport': transport,
          'zmetaHost': host,
          'zmetaPort': 5555,
          'zmetaJoinedPlatformId': '',
        };

    Future<AppState> bootWith(
      WidgetTester tester,
      Map<String, dynamic> settingsJson,
    ) async {
      SharedPreferences.setMockInitialValues({
        'rf_sentry_zmeta_v1': jsonEncode(settingsJson),
      });
      final state = AppState(zerotierProbe: () async => false);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.pump();
      return state;
    }

    testWidgets('udp + 10.99.1.x host migrates to zerotier',
        (tester) async {
      final state = await bootWith(
          tester, stored(host: '10.99.1.1'));
      expect(state.settings.zmetaTransport, 'zerotier');
      state.dispose();
    });

    testWidgets('udp + 10.99.0.x host migrates to wireguard',
        (tester) async {
      final state = await bootWith(
          tester, stored(host: '10.99.0.5'));
      expect(state.settings.zmetaTransport, 'wireguard');
      state.dispose();
    });

    testWidgets('stored wireguard + 10.99.1.x host is corrected to zerotier',
        (tester) async {
      final state = await bootWith(tester,
          stored(transport: 'wireguard', host: '10.99.1.11'));
      expect(state.settings.zmetaTransport, 'zerotier');
      state.dispose();
    });

    testWidgets('udp + loopback host stays udp', (tester) async {
      final state = await bootWith(tester, stored());
      expect(state.settings.zmetaTransport, 'udp');
      state.dispose();
    });
  });

  group('AppState ZeroTier wiring (stored fake join)', () {
    Map<String, dynamic> settings({
      String transport = 'udp',
      String joined = 'outride-mesh-1',
      String ztNetworkId = _ztNetworkId,
      String ztTarget = _ztTarget,
      String cfUrl = '',
      String cfFp = '',
    }) =>
        {
          'zmetaEnabled': true,
          'zmetaTransport': transport,
          'zmetaHost': '127.0.0.1',
          'zmetaPort': 5555,
          'zmetaPlatformId': 'outride-mesh-1',
          'zmetaJoinedPlatformId': joined,
          'zmetaIngestUrl': cfUrl,
          'zmetaIngestFp': cfFp,
          'zerotierNetworkId': ztNetworkId,
          'zerotierNodeId': _ztNodeId,
          'zerotierIp': _ztIp,
          'zerotierIpStatus': 'reserved',
          'zerotierIpConfirmed': false,
          'zmetaTargetZt': ztTarget,
        };

    Future<AppState> bootWith(
      WidgetTester tester,
      Map<String, dynamic> settingsJson, {
      required Future<bool?> Function() ztProbe,
      Future<bool?> Function(String url)? cfProbe,
    }) async {
      SharedPreferences.setMockInitialValues({
        'rf_sentry_zmeta_v1': jsonEncode(settingsJson),
      });
      final state = AppState(
        zerotierProbe: ztProbe,
        cloudflareProbe: cfProbe ?? (_) async => false,
      );
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      // Let the async settings load + boot evaluations run.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.pump();
      return state;
    }

    // NOTE: each test disposes its AppState explicitly at the end of
    // the body (not via addTearDown): the boot evaluation starts a
    // 1-minute periodic re-check timer, and the framework fails a
    // test that ends with a timer still pending — tearDown runs too
    // late for that check.

    testWidgets('boot with tunnel up flips udp to zerotier and sets target',
        (tester) async {
      final state = await bootWith(tester, settings(),
          ztProbe: () async => true);
      expect(state.settings.zmetaTransport, 'zerotier');
      expect(state.settings.zmetaHost, '10.99.1.1');
      expect(state.settings.zmetaPort, 5555);
      expect(state.zerotierPathActive, isTrue);
      expect(state.zerotierPathReason, 'active');
      expect(state.zerotierTunnelDetected, isTrue);
      state.dispose();
    });

    testWidgets('boot with tunnel down stays on udp and reports down',
        (tester) async {
      final state = await bootWith(tester, settings(),
          ztProbe: () async => false);
      expect(state.settings.zmetaTransport, 'udp');
      expect(state.zerotierPathActive, isFalse);
      expect(state.zerotierPathReason, 'down');
      expect(state.zerotierTunnelDetected, isFalse);
      state.dispose();
    });

    testWidgets('no stored join means not configured and no probe',
        (tester) async {
      var probes = 0;
      final state = await bootWith(
          tester,
          settings(ztNetworkId: '', ztTarget: ''),
          ztProbe: () async {
            probes++;
            return true;
          });
      expect(probes, 0,
          reason: 'no ZeroTier join stored means nothing to connect');
      expect(state.settings.zmetaTransport, 'udp');
      expect(state.zerotierPathReason, 'not configured');
      state.dispose();
    });

    testWidgets('WireGuard joined is never flipped by the ZeroTier eval',
        (tester) async {
      final state = await bootWith(
          tester,
          settings(transport: 'wireguard'),
          ztProbe: () async => true);
      expect(state.settings.zmetaTransport, 'wireguard');
      expect(state.zerotierTunnelDetected, isTrue,
          reason: 'the local probe still reports the tunnel');
      expect(state.zerotierPathReason, 'wireguard');
      expect(state.zerotierPathActive, isFalse);
      state.dispose();
    });

    testWidgets('manual connect works when the tunnel is up',
        (tester) async {
      var tunnelUp = false;
      final state = await bootWith(tester, settings(),
          ztProbe: () async => tunnelUp);
      expect(state.settings.zmetaTransport, 'udp');
      expect(state.zerotierPathReason, 'down');
      tunnelUp = true;
      final connected = await state.connectZerotierPathManually();
      await tester.pump();
      expect(connected, isTrue);
      expect(state.settings.zmetaTransport, 'zerotier');
      expect(state.zerotierPathActive, isTrue);
      expect(state.zerotierPathReason, 'active');
      state.dispose();
    });

    testWidgets('manual connect with the tunnel down changes nothing',
        (tester) async {
      final state = await bootWith(tester, settings(),
          ztProbe: () async => false);
      final connected = await state.connectZerotierPathManually();
      await tester.pump();
      expect(connected, isFalse);
      expect(state.settings.zmetaTransport, 'udp');
      expect(state.zerotierPathReason, 'down');
      state.dispose();
    });

    testWidgets('re-check timer connects a tunnel that comes up later',
        (tester) async {
      var tunnelUp = false;
      var probes = 0;
      final state = await bootWith(tester, settings(), ztProbe: () async {
        probes++;
        return tunnelUp;
      });
      expect(state.settings.zmetaTransport, 'udp');
      expect(probes, 1);
      // The tunnel comes up later — no one opens Settings.
      tunnelUp = true;
      await tester.pump(kZerotierRecheckInterval);
      await tester.pump();
      expect(probes, 2,
          reason: 'the 1-minute re-check must probe again on its own');
      expect(state.settings.zmetaTransport, 'zerotier');
      expect(state.zerotierPathActive, isTrue);
      expect(state.zerotierPathReason, 'active');
      state.dispose();
    });

    testWidgets('Cloudflare never overrides a live ZeroTier link',
        (tester) async {
      final state = await bootWith(
          tester,
          settings(
              transport: 'zerotier', cfUrl: _cfUrl, cfFp: '-'),
          ztProbe: () async => true,
          cfProbe: (_) async => true);
      expect(state.settings.zmetaTransport, 'zerotier',
          reason: 'the Cloudflare path must never flip ZeroTier to https');
      expect(state.cloudflarePathReason, 'zerotier');
      expect(state.zerotierPathActive, isTrue);
      state.dispose();
    });

    testWidgets(
        'ZeroTier eval flips an active HTTPS link when the tunnel comes up; Cloudflare never flips it back',
        (tester) async {
      final state = await bootWith(
          tester,
          settings(transport: 'https', cfUrl: _cfUrl, cfFp: '-'),
          ztProbe: () async => true,
          cfProbe: (_) async => true);
      expect(state.settings.zmetaTransport, 'zerotier',
          reason: 'tunnel up with a stored ZT join must win over HTTPS');
      expect(state.settings.zmetaHost, '10.99.1.1',
          reason: 'the flip sets host/port from the stored ZT target, '
              'not the stale pre-join host');
      expect(state.settings.zmetaPort, 5555);
      expect(state.zerotierPathActive, isTrue);
      expect(state.zerotierPathReason, 'active');
      expect(state.cloudflarePathReason, 'zerotier',
          reason: 'the Cloudflare path never overrides a ZeroTier join');
      // Let both re-check timers fire: neither may flip it back.
      await tester.pump(kCloudflareRecheckInterval);
      await tester.pump(kZerotierRecheckInterval);
      await tester.pump();
      expect(state.settings.zmetaTransport, 'zerotier');
      expect(state.cloudflarePathReason, 'zerotier');
      state.dispose();
    });

    testWidgets('S4 platform mismatch covers zerotier', (tester) async {
      final state = await bootWith(
          tester,
          settings(transport: 'zerotier'),
          ztProbe: () async => true);
      // Joined id matches the platform id: no mismatch.
      expect(state.zmetaPlatformMismatch, isFalse);
      // Operator edits the platform ID after joining: mismatch.
      state.settings.zmetaPlatformId = 'outride-mesh-2';
      expect(state.zmetaPlatformMismatch, isTrue);
      state.dispose();
    });
  });
}

/// Tailscale compatibility tests: the CGNAT address check and the
/// tunnel detector (injected interfaces only — no real tailnet
/// exists here).
///
/// Web note: the detector returns null on web (kIsWeb guard, "not
/// probed", never "down"), the same as zerotier_detect.dart. That
/// branch is not directly testable in flutter_test — kIsWeb is false
/// on the VM — so, mirroring the ZeroTier tests, there is no web test
/// here; the guard is the same one-line check in both services.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/tailscale_detect.dart';

void main() {
  group('isTailscaleAddress', () {
    test('addresses in 100.64.0.0/10 match', () {
      expect(isTailscaleAddress('100.64.0.1'), isTrue);
      expect(isTailscaleAddress('100.64.0.5'), isTrue);
      expect(isTailscaleAddress('100.100.1.2'), isTrue);
      expect(isTailscaleAddress('100.127.255.254'), isTrue);
      expect(isTailscaleAddress('100.99.1.1'), isTrue,
          reason: '100.99 is inside 64-127, so it IS in the block');
    });

    test('the edges of the /10 block match, outside it does not', () {
      expect(isTailscaleAddress('100.64.0.0'), isTrue);
      expect(isTailscaleAddress('100.127.255.255'), isTrue);
      expect(isTailscaleAddress('100.63.255.255'), isFalse);
      expect(isTailscaleAddress('100.128.0.1'), isFalse);
    });

    test('other subnets and malformed text do not match', () {
      expect(isTailscaleAddress('192.168.1.5'), isFalse);
      expect(isTailscaleAddress('10.99.0.5'), isFalse);
      expect(isTailscaleAddress('10.99.1.11'), isFalse);
      expect(isTailscaleAddress('127.0.0.1'), isFalse);
      expect(isTailscaleAddress('100.64.0.256'), isFalse);
      expect(isTailscaleAddress('100.64.0.01'), isFalse);
      expect(isTailscaleAddress('100.64.0'), isFalse);
      expect(isTailscaleAddress(''), isFalse);
      expect(isTailscaleAddress('not an address'), isFalse);
      expect(isTailscaleAddress(' 100.64.0.5 '), isTrue,
          reason: 'surrounding whitespace is trimmed, like zerotier');
    });
  });

  group('tailscaleTunnelUp (injected interfaces)', () {
    test('true when a 100.64.x.x address is present', () async {
      expect(
          await tailscaleTunnelUp(listAddresses: () async =>
              ['192.168.1.5', '100.64.0.5', '172.17.97.10']),
          isTrue);
    });

    test('false when only other addresses are present', () async {
      expect(
          await tailscaleTunnelUp(listAddresses: () async =>
              ['192.168.1.5', '100.63.0.5', '127.0.0.1']),
          isFalse);
    });

    test('false on an empty interface list', () async {
      expect(
          await tailscaleTunnelUp(listAddresses: () async => []),
          isFalse);
    });

    test('local address helper returns the Tailscale address', () async {
      expect(
          await tailscaleLocalAddress(listAddresses: () async =>
              ['192.168.1.5', '100.100.1.2']),
          '100.100.1.2');
      expect(
          await tailscaleLocalAddress(listAddresses: () async =>
              ['192.168.1.5']),
          isNull);
    });
  });
}

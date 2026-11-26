/// WireGuard compatibility tests: the tunnel-pool address check and
/// the tunnel detector (injected interfaces only — no real WireGuard
/// tunnel exists here). Mirrors zerotier_test.dart's detector groups.
///
/// Web note: the detector returns null on web (kIsWeb guard, "not
/// probed", never "down"), the same as zerotier_detect.dart. That
/// branch is not directly testable in flutter_test — kIsWeb is false
/// on the VM — so, mirroring the ZeroTier tests, there is no web test
/// here; the guard is the same one-line check in both services.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/wireguard_detect.dart';

void main() {
  group('isWireguardAddress', () {
    test('tunnel addresses in 10.99.0.0/24 match', () {
      expect(isWireguardAddress('10.99.0.1'), isTrue);
      expect(isWireguardAddress('10.99.0.5'), isTrue);
      expect(isWireguardAddress('10.99.0.254'), isTrue);
    });

    test('the ZeroTier pool 10.99.1.0/24 does not match', () {
      expect(isWireguardAddress('10.99.1.1'), isFalse);
      expect(isWireguardAddress('10.99.1.11'), isFalse);
    });

    test('other subnets and malformed text do not match', () {
      expect(isWireguardAddress('10.99.2.1'), isFalse);
      expect(isWireguardAddress('192.168.1.5'), isFalse);
      expect(isWireguardAddress('127.0.0.1'), isFalse);
      expect(isWireguardAddress('10.99.0.256'), isFalse);
      expect(isWireguardAddress('10.99.0.01'), isFalse);
      expect(isWireguardAddress('10.99.0'), isFalse);
      expect(isWireguardAddress(''), isFalse);
      expect(isWireguardAddress('not an address'), isFalse);
    });
  });

  group('wireguardTunnelUp (injected interfaces)', () {
    test('true when a 10.99.0.x address is present', () async {
      expect(
          await wireguardTunnelUp(listAddresses: () async =>
              ['192.168.1.5', '10.99.0.5', '172.17.97.10']),
          isTrue);
    });

    test('false when only other addresses are present', () async {
      expect(
          await wireguardTunnelUp(listAddresses: () async =>
              ['192.168.1.5', '10.99.1.11', '127.0.0.1']),
          isFalse);
    });

    test('false on an empty interface list', () async {
      expect(
          await wireguardTunnelUp(listAddresses: () async => []),
          isFalse);
    });

    test('local address helper returns the WireGuard address', () async {
      expect(
          await wireguardLocalAddress(listAddresses: () async =>
              ['192.168.1.5', '10.99.0.5']),
          '10.99.0.5');
      expect(
          await wireguardLocalAddress(listAddresses: () async =>
              ['192.168.1.5']),
          isNull);
    });
  });
}

/// WireGuard tunnel detection — does this device currently hold a
/// WireGuard address in the hub's tunnel pool (10.99.0.0/24)?
///
/// The tunnel itself comes from the external WireGuard app — Outride
/// cannot embed it, same relationship as ZeroTier (see
/// zerotier_detect.dart). This service only RECOGNIZES that the tunnel
/// is up: any local address in 10.99.0.0/24 means the WireGuard app
/// has activated a tunnel and the interface is live. Detection is
/// read-only status: it never flips the transport (a stored WireGuard
/// join already owns it — see AppState.evaluateWireguardPath).
/// Detection is a local interface list — no packets, no new
/// destination.
///
/// Pure Dart (dart:io) — no Flutter widgets — so it stays unit-testable.
/// The interface list is an injectable seam (same pattern as
/// zerotier_detect.dart): production lists the real interfaces, tests
/// inject address lists. On web, dart:io has no interfaces, so the
/// probe returns null ("not probed", never "down").
library wireguard_detect;

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

/// The hub's WireGuard tunnel pool. The ZeroTier mesh is the
/// SEPARATE 10.99.1.0/24 — never confuse them.
const String kWireguardSubnetPrefix = '10.99.0.';

/// True when [ip] is a plain IPv4 address inside 10.99.0.0/24. Pure;
/// no network. Rejects leading zeros, whitespace, and non-quad text
/// (same bar as the WireGuard tunnel-IP check in zmeta_pairing.dart).
bool isWireguardAddress(String ip) {
  final t = ip.trim();
  if (!t.startsWith(kWireguardSubnetPrefix)) return false;
  final octets = t.split('.');
  if (octets.length != 4) return false;
  return octets.every((o) {
    final n = int.tryParse(o);
    return n != null && n >= 0 && n <= 255 && o == '$n';
  });
}

/// Default interface-list seam: every local address, loopback included
/// (a loopback address is never in 10.99.0.0/24, so it cannot false-
/// positive). Never throws — a failure to list interfaces reads as
/// "no WireGuard address", never a crash.
Future<List<String>> wireguardListAddresses() async {
  try {
    final ifs = await NetworkInterface.list();
    return [for (final i in ifs) for (final a in i.addresses) a.address];
  } catch (_) {
    return const <String>[];
  }
}

/// Is the WireGuard tunnel up on this device?
///
/// Returns true when any local address is in 10.99.0.0/24, false when
/// none is, and null on web, where dart:io interfaces do not exist —
/// null means "not probed", never "down". [listAddresses] is the
/// injectable seam (tests only); production passes nothing.
Future<bool?> wireguardTunnelUp({
  Future<List<String>> Function()? listAddresses,
}) async {
  if (kIsWeb) return null;
  final addrs = await (listAddresses ?? wireguardListAddresses)();
  return addrs.any(isWireguardAddress);
}

/// The device's own WireGuard tunnel address when the tunnel is up,
/// else null. Null on web.
Future<String?> wireguardLocalAddress({
  Future<List<String>> Function()? listAddresses,
}) async {
  if (kIsWeb) return null;
  final addrs = await (listAddresses ?? wireguardListAddresses)();
  for (final a in addrs) {
    if (isWireguardAddress(a)) return a;
  }
  return null;
}

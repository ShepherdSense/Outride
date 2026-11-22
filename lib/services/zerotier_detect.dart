/// ZeroTier tunnel detection — does this device currently hold a
/// ZeroTier address in the hub's mesh subnet (10.99.1.0/24)?
///
/// The tunnel itself comes from the external ZeroTier One app (or the
/// ZeroTier One service on Windows) — Outride cannot embed it, same
/// relationship as the WireGuard app. This service only RECOGNIZES
/// that the tunnel is up: any local address in 10.99.1.0/24 means the
/// ZeroTier app has joined the network and the interface is live.
/// Detection drives connection (see AppState.evaluateZerotierPath):
/// when the tunnel is up and a ZeroTier join is stored, the transport
/// auto-selects 'zerotier'; when it is down, the transport stays put
/// and the next re-check tries again. Detection is a local interface
/// list — no packets, no new destination.
///
/// Pure Dart (dart:io) — no Flutter widgets — so it stays unit-testable.
/// The interface list is an injectable seam (same pattern as
/// device_autoconnect.dart): production lists the real interfaces,
/// tests inject address lists. On web, dart:io has no interfaces, so
/// the probe returns null ("not probed", never "down").
library zerotier_detect;

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

/// How often AppState re-checks the ZeroTier tunnel while ZMeta export
/// is on and a ZeroTier join is stored. Local-only and cheap (one
/// interface list, no sockets), so a minute is fine — an operator who
/// just joined the network in the ZeroTier app should not wait five
/// minutes for Outride to notice.
const Duration kZerotierRecheckInterval = Duration(minutes: 1);

/// The hub's ZeroTier mesh subnet. The gateway holds 10.99.1.1 and
/// meshes take 10.99.1.11+ (see zmeta_secure/ZEROTIER_JOIN_SPEC.md).
/// The WireGuard pool is the SEPARATE 10.99.0.0/24 — never confuse them.
const String kZerotierSubnetPrefix = '10.99.1.';

/// ZeroTier gateway address (the hub's ZMeta target host).
const String kZerotierGatewayIp = '10.99.1.1';

/// True when [ip] is a plain IPv4 address inside 10.99.1.0/24. Pure;
/// no network. Rejects leading zeros, whitespace, and non-quad text
/// (same bar as the WireGuard tunnel-IP check in zmeta_pairing.dart).
bool isZerotierAddress(String ip) {
  final t = ip.trim();
  if (!t.startsWith(kZerotierSubnetPrefix)) return false;
  final octets = t.split('.');
  if (octets.length != 4) return false;
  return octets.every((o) {
    final n = int.tryParse(o);
    return n != null && n >= 0 && n <= 255 && o == '$n';
  });
}

/// Default interface-list seam: every local address, loopback included
/// (a loopback address is never in 10.99.1.0/24, so it cannot false-
/// positive). Never throws — a failure to list interfaces reads as
/// "no ZeroTier address", never a crash.
Future<List<String>> zerotierListAddresses() async {
  try {
    final ifs = await NetworkInterface.list();
    return [for (final i in ifs) for (final a in i.addresses) a.address];
  } catch (_) {
    return const <String>[];
  }
}

/// Is the ZeroTier tunnel up on this device?
///
/// Returns true when any local address is in 10.99.1.0/24, false when
/// none is, and null on web, where dart:io interfaces do not exist —
/// null means "not probed", never "down". [listAddresses] is the
/// injectable seam (tests only); production passes nothing.
Future<bool?> zerotierTunnelUp({
  Future<List<String>> Function()? listAddresses,
}) async {
  if (kIsWeb) return null;
  final addrs = await (listAddresses ?? zerotierListAddresses)();
  return addrs.any(isZerotierAddress);
}

/// The device's own ZeroTier address when the tunnel is up, else null.
/// Null on web. Used by the UI to show which address the tunnel holds
/// (the hub-allocated mesh IP is stored separately at join time).
Future<String?> zerotierLocalAddress({
  Future<List<String>> Function()? listAddresses,
}) async {
  if (kIsWeb) return null;
  final addrs = await (listAddresses ?? zerotierListAddresses)();
  for (final a in addrs) {
    if (isZerotierAddress(a)) return a;
  }
  return null;
}

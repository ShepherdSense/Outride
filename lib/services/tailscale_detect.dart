/// Tailscale tunnel detection — does this device currently hold a
/// Tailscale address in the CGNAT range (100.64.0.0/10)?
///
/// The tunnel itself comes from the external Tailscale app — Outride
/// cannot embed it, same relationship as ZeroTier and WireGuard (see
/// zerotier_detect.dart). This service only RECOGNIZES that the tunnel
/// is up: any local address in 100.64.0.0/10 means the Tailscale app
/// has joined a tailnet and the interface is live. Detection is
/// read-only status + guidance only in this version: there is NO
/// Tailscale ZMeta transport enum, and nothing here flips the
/// transport. The operator pastes the hub's Tailscale IP as the ZMeta
/// host by hand (see the Tailscale detail screen). Detection is a
/// local interface list — no packets, no new destination.
///
/// Tailscale assigns addresses from the shared CGNAT block
/// 100.64.0.0/10 (second octet 64–127). The check is strict: a plain
/// IPv4 dotted quad with no leading zeros, first octet 100, second
/// octet 64–127. Other 100.x addresses (e.g. a carrier NAT 100.90.x
/// is IN the range — 90 is within 64–127 — so a carrier CGNAT address
/// can read as a Tailscale address; the detail screen says so
/// plainly and labels the whole row EXPERIMENTAL).
///
/// Pure Dart (dart:io) — no Flutter widgets — so it stays unit-testable.
/// The interface list is an injectable seam (same pattern as
/// zerotier_detect.dart): production lists the real interfaces, tests
/// inject address lists. On web, dart:io has no interfaces, so the
/// probe returns null ("not probed", never "down").
///
/// EXPERIMENTAL — unverified on hardware.
library tailscale_detect;

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

/// Tailscale's CGNAT block: 100.64.0.0/10 — first octet 100, second
/// octet 64–127.
const int kTailscaleFirstOctet = 100;

/// Second-octet bounds of 100.64.0.0/10 (inclusive).
const int kTailscaleSecondOctetMin = 64;
const int kTailscaleSecondOctetMax = 127;

/// True when [ip] is a plain IPv4 address inside 100.64.0.0/10. Pure;
/// no network. Rejects leading zeros, whitespace, and non-quad text
/// (same bar as [isZerotierAddress] in zerotier_detect.dart).
bool isTailscaleAddress(String ip) {
  final t = ip.trim();
  final octets = t.split('.');
  if (octets.length != 4) return false;
  final nums = <int>[];
  for (final o in octets) {
    final n = int.tryParse(o);
    if (n == null || n < 0 || n > 255 || o != '$n') return false;
    nums.add(n);
  }
  if (nums[0] != kTailscaleFirstOctet) return false;
  return nums[1] >= kTailscaleSecondOctetMin &&
      nums[1] <= kTailscaleSecondOctetMax;
}

/// Default interface-list seam: every local address, loopback included
/// (a loopback address is never in 100.64.0.0/10, so it cannot false-
/// positive). Never throws — a failure to list interfaces reads as
/// "no Tailscale address", never a crash.
Future<List<String>> tailscaleListAddresses() async {
  try {
    final ifs = await NetworkInterface.list();
    return [for (final i in ifs) for (final a in i.addresses) a.address];
  } catch (_) {
    return const <String>[];
  }
}

/// Is the Tailscale tunnel up on this device?
///
/// Returns true when any local address is in 100.64.0.0/10, false when
/// none is, and null on web, where dart:io interfaces do not exist —
/// null means "not probed", never "down". [listAddresses] is the
/// injectable seam (tests only); production passes nothing.
Future<bool?> tailscaleTunnelUp({
  Future<List<String>> Function()? listAddresses,
}) async {
  if (kIsWeb) return null;
  final addrs = await (listAddresses ?? tailscaleListAddresses)();
  return addrs.any(isTailscaleAddress);
}

/// The device's own Tailscale address when the tunnel is up, else
/// null. Null on web.
Future<String?> tailscaleLocalAddress({
  Future<List<String>> Function()? listAddresses,
}) async {
  if (kIsWeb) return null;
  final addrs = await (listAddresses ?? tailscaleListAddresses)();
  for (final a in addrs) {
    if (isTailscaleAddress(a)) return a;
  }
  return null;
}

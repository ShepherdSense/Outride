/// Cloudflare auto-path — select the ZMeta HTTPS (Cloudflare) transport
/// automatically when Outride opens and the internet is reachable.
///
/// The hub-behind-cloudflared path already exists in the invite/pairing
/// code: when the hub sits behind cloudflared, the invite code carries a
/// public HTTPS ingest URL with certfp '-' (public-CA mode) and the EUD
/// talks HTTPS to the hub's public hostname through the Cloudflare edge
/// (see zmeta_pairing.dart, zmeta_https_ingest.dart). That path was
/// join-time only — this service makes it automatic: on app open (and
/// every few minutes while ZMeta export is on), if a Cloudflare-mode
/// ingest URL is stored and its host answers, the transport flips to
/// HTTPS by itself. No WireGuard app, no manual step.
///
/// Selection rules (pure and unit-tested; the probe is the only network
/// touch, and it only ever connects to the already-stored ingest host —
/// never a new destination):
///   a. WireGuard joined (transport 'wireguard' + stored joined platform
///      id) is NEVER overridden — WireGuard stays. The same protection
///      covers ZeroTier (transport 'zerotier' + stored joined platform
///      id): a live ZeroTier link is the operator's chosen tunnel and
///      the Cloudflare path must never flip it to HTTPS — the ZeroTier
///      auto-eval owns that transport.
///   b. A stored Cloudflare-mode ingest URL (usable HTTPS URL + certfp
///      '-') AND a successful probe selects 'https' — when the
///      operator's in-app auto-path toggle is on (default on when a
///      Cloudflare-mode URL is stored). With the toggle off the hub is
///      still reported as available ('auto-off') and the operator can
///      connect by hand instead (a one-shot manual evaluation).
///   c. Anything else leaves the transport exactly as it is (offline
///      keeps working on UDP/local; no URL means nothing to select).
///
/// Pure Dart — no Flutter widgets — so it stays unit-testable. The probe
/// uses dart:io (the same precedent as zmeta_https_ingest.dart, which
/// the web build already compiles); it never runs on web, where kIsWeb
/// short-circuits it to null ("not probed", never "offline").
library cloudflare_auto;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

/// How often AppState re-checks the Cloudflare path while ZMeta export
/// is on (the boot check runs once from _loadZmetaSettings).
const Duration kCloudflareRecheckInterval = Duration(minutes: 5);

/// Default probe budget: one TCP connect to the ingest host. Short on
/// purpose — startup never waits on it (called unawaited).
const Duration kCloudflareProbeTimeout = Duration(seconds: 3);

/// True when [rawUrl]/[fpMode] describe a stored Cloudflare-mode ingest
/// endpoint: certfp '-' (public-CA mode) plus a usable absolute HTTPS
/// URL. Same validity bar as [zmetaValidateIngestUrl] in
/// zmeta_pairing.dart, narrowed to HTTPS — a Cloudflare hub is always
/// public, so plain HTTP (loopback-only there) is never a Cloudflare
/// path. Pure; no network.
bool isCloudflareIngestUrl(String rawUrl, String fpMode) {
  if (fpMode != '-') return false;
  final t = rawUrl.trim();
  if (t.isEmpty) return false;
  final uri = Uri.tryParse(t);
  if (uri == null || !uri.isAbsolute || uri.host.isEmpty) return false;
  return uri.scheme.toLowerCase() == 'https';
}

/// Probe the stored ingest host: one TCP connect to the URL's host:port
/// (443 unless the URL carries a port), inside [timeout].
///
/// Returns true when the host answers, false when it does not (refused,
/// timed out, unresolvable, malformed URL), and null on web, where
/// dart:io sockets do not exist — null means "not probed", never
/// "offline". The probe touches no destination beyond the already-stored
/// ingest URL, and a successful connect proves reachability only: TLS
/// and the bearer token are still enforced per-event by the emitter.
Future<bool?> probeCloudflareIngest(
  String ingestUrl, {
  Duration timeout = kCloudflareProbeTimeout,
}) async {
  if (kIsWeb) return null;
  final uri = Uri.tryParse(ingestUrl.trim());
  if (uri == null || !uri.isAbsolute || uri.host.isEmpty) return false;
  final port = uri.hasPort ? uri.port : 443;
  try {
    final socket = await Socket.connect(uri.host, port, timeout: timeout);
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Pure transport selection. [internetReachable] is the probe result:
/// true = the ingest host answered, false = it did not, null = the
/// probe could not run (web). [autoEnabled] is the operator's
/// in-app auto-path toggle: when it is off, the auto-path never flips
/// the transport on its own — a manual connect passes true for one
/// evaluation instead.
///
/// Returns the transport to use plus a short reason string for the UI:
/// 'active' (Cloudflare path selected and reachable), 'offline'
/// (stored URL, host did not answer), 'not configured' (no
/// Cloudflare-mode URL stored), 'wireguard' (WireGuard joined — never
/// overridden), 'zerotier' (ZeroTier joined — never overridden),
/// 'auto-off' (hub is up but auto-use is off — the operator can still
/// connect by hand), 'unavailable' (probe cannot run on this platform).
/// Rule (c): every non-selecting outcome returns [currentTransport]
/// unchanged — the auto-path only ever flips TO https, never away.
({String transport, String reason}) selectZmetaTransport({
  required String currentTransport,
  required String joinedPlatformId,
  required String ingestUrl,
  required String ingestFp,
  required bool? internetReachable,
  required bool autoEnabled,
}) {
  // Rule (a): WireGuard joined — never override it.
  if (currentTransport == 'wireguard' &&
      joinedPlatformId.trim().isNotEmpty) {
    return (transport: currentTransport, reason: 'wireguard');
  }
  // Rule (a2): ZeroTier joined — never override it either. A live
  // ZeroTier link is the operator's chosen tunnel; the Cloudflare
  // path must not flip it to HTTPS (the ZeroTier auto-eval owns that
  // transport, and flips it only when its own tunnel is up).
  if (currentTransport == 'zerotier' &&
      joinedPlatformId.trim().isNotEmpty) {
    return (transport: currentTransport, reason: 'zerotier');
  }
  // Rule (b): Cloudflare-mode URL stored — the probe decides.
  if (isCloudflareIngestUrl(ingestUrl, ingestFp)) {
    if (internetReachable == true) {
      // Already on the path (joined or manually connected) or
      // auto-use is on: select it. Otherwise report it as available
      // but not auto-selected.
      if (currentTransport == 'https' || autoEnabled) {
        return (transport: 'https', reason: 'active');
      }
      return (transport: currentTransport, reason: 'auto-off');
    }
    if (internetReachable == null) {
      return (transport: currentTransport, reason: 'unavailable');
    }
    return (transport: currentTransport, reason: 'offline');
  }
  // Rule (c): no Cloudflare-mode URL — leave the transport alone.
  return (transport: currentTransport, reason: 'not configured');
}

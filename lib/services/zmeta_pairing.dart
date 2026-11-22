/// ZMeta invite-code pairing ("Join network") — mesh side.
///
/// A hub operator generates a single-use invite code. The mesh operator
/// pastes it here; this service validates the code, generates a local
/// X25519 keypair (the private key NEVER leaves the device), redeems the
/// code against the hub's pairing endpoint, and builds the WireGuard
/// .conf the operator activates in the WireGuard app.
///
/// TLS is DUAL-MODE, selected by the invite code's certfp field:
/// - 64-hex fingerprint (direct pin mode): the hub serves pairing over
///   TLS with a self-signed cert. The client uses an EMPTY trust store,
///   so default verification fails for EVERY cert and the
///   badCertificateCallback pin — sha256(cert.der) == fingerprint — is
///   the SOLE gate. Even a compromised CA or a proxy CA installed on
///   the device cannot impersonate the hub.
/// - "-" (Cloudflare mode): the hub sits behind cloudflared and the
///   pairing endpoint is ordinary public HTTPS. The client does normal
///   public-CA verification of the hub's domain; the 256-bit single-use
///   token in the POST body is the credential. Tradeoff: this trusts
///   the public CA system and the Cloudflare edge (the edge sees the
///   token), but a stolen token only lets an attacker race the
///   legitimate redeem — and the loser's redeem fails loudly ("used"),
///   so interception is noisy and detectable in the hub's pairing.log.
///
/// Security posture (mirrors the hub contract):
/// - The private key is generated on-device and never transmitted.
/// - Nothing here enables ZMeta export by itself; the operator still
///   toggles export on explicitly in Settings.
///
/// Pure Dart (dart:io + package:crypto + package:cryptography) — no
/// Flutter imports — so it stays unit-testable.
library zmeta_pairing;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

import 'zmeta_adapter.dart' show zmetaIsLocalHost;

/// Invite code format:
///   Z1.<hub_host>.<pair_port>.<wg_port>.<token_b64url>.<certfp>
/// Parsed right-to-left because hub_host itself may contain dots.
/// certfp is "-" (Cloudflare / public-CA mode) or 64 hex chars
/// (direct self-signed pin mode).
class ZmetaInvite {
  const ZmetaInvite({
    required this.hubHost,
    required this.pairPort,
    required this.wgPort,
    required this.token,
    required this.certFpHex,
  });

  final String hubHost;
  final int pairPort;
  final int wgPort;

  /// 43-char base64url single-use token.
  final String token;

  /// "-" for Cloudflare/public-CA mode, or 64 lowercase hex chars:
  /// SHA-256 of the pairing server's TLS cert (direct pin mode).
  final String certFpHex;

  String get redeemUrl => 'https://$hubHost:$pairPort/redeem';
}

/// Human-readable pairing failure. [message] is safe to show verbatim.
class ZmetaPairingException implements Exception {
  ZmetaPairingException(this.message);
  final String message;
  @override
  String toString() => 'ZmetaPairingException: $message';
}

/// Platform IDs are hub-scoped identities: lowercase, digits, dashes.
bool zmetaIsValidPlatformId(String s) =>
    RegExp(r'^[a-z0-9-]{1,32}$').hasMatch(s);

/// ZeroTier node ID: exactly 10 hex chars, from the ZeroTier One app
/// (`zerotier-cli info` / the app's device screen). Case-insensitive
/// on entry, stored lower-cased. A node ID is a PUBLIC identifier, not
/// a credential and never proof of identity — the hub's controller
/// read-back is what stops an unapproved or already-paired node, not
/// this check. Throws [ZmetaPairingException] with the plain message
/// the join dialog shows verbatim.
String zmetaValidateZerotierNodeId(String raw) {
  final t = raw.trim().toLowerCase();
  if (!RegExp(r'^[0-9a-f]{10}$').hasMatch(t)) {
    throw ZmetaPairingException(
        'That doesn\'t look like a ZeroTier node ID — it\'s 10 hex '
        'characters, find it in the ZeroTier app');
  }
  return t;
}

/// A plain IPv4 dotted quad (no leading zeros, no whitespace). Used
/// for hub-supplied ZeroTier addresses; a compromised or buggy hub
/// must not smuggle config text into a stored address. The raw string
/// is validated as-is — callers that already trimmed their value pass
/// the trimmed copy.
bool zmetaIsValidIpv4(String s) {
  final octets = s.split('.');
  if (octets.length != 4) return false;
  return octets.every((o) {
    final n = int.tryParse(o);
    return n != null && n >= 0 && n <= 255 && o == '$n';
  });
}

/// Extracts a valid invite code from scanned QR text. Hub operators
/// may QR the bare code or a line of text containing it (e.g. a label
/// or URL), so this scans for the `Z1.` token and takes the run of
/// code characters that follows. Returns the code only when it fully
/// parses — a QR that is not a Outride invite yields null, never a
/// partially-trusted string.
String? zmetaInviteCodeFromScan(String raw) {
  final start = raw.indexOf('Z1.');
  if (start < 0) return null;
  final rest = raw.substring(start);
  final end = rest.indexOf(RegExp(r'[\s"<>&]'));
  final candidate = (end < 0 ? rest : rest.substring(0, end)).trim();
  try {
    parseInviteCode(candidate);
    return candidate;
  } on ZmetaPairingException {
    return null;
  }
}

/// Strict invite-code parse. Throws [ZmetaPairingException] with a
/// human-readable reason on any deviation.
ZmetaInvite parseInviteCode(String raw) {
  final code = raw.trim();
  if (code.isEmpty) {
    throw ZmetaPairingException('Paste the invite code first.');
  }
  if (!code.startsWith('Z1.')) {
    throw ZmetaPairingException(
        'Not a ZMeta invite code — it must start with "Z1.".');
  }
  final parts = code.substring(3).split('.');
  // Minimum: host(1+) + pairPort + wgPort + token + certfp = 5 parts.
  if (parts.length < 5) {
    throw ZmetaPairingException(
        'Invite code is truncated — ${parts.length} sections, need at least 5.');
  }
  final certFp = parts.removeLast();
  final token = parts.removeLast();
  final wgPortS = parts.removeLast();
  final pairPortS = parts.removeLast();
  final host = parts.join('.');

  if (certFp != '-' && !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(certFp)) {
    throw ZmetaPairingException(
        'Invite code is corrupt: certificate fingerprint must be "-" '
        '(Cloudflare mode) or 64 hex characters (direct pin mode).');
  }
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
    throw ZmetaPairingException(
        'Invite code is corrupt: token must be 43 base64url characters.');
  }
  final pairPort = int.tryParse(pairPortS);
  final wgPort = int.tryParse(wgPortS);
  if (pairPort == null || pairPort < 1 || pairPort > 65535) {
    throw ZmetaPairingException(
        'Invite code is corrupt: bad pairing port "$pairPortS".');
  }
  if (wgPort == null || wgPort < 1 || wgPort > 65535) {
    throw ZmetaPairingException(
        'Invite code is corrupt: bad WireGuard port "$wgPortS".');
  }
  if (host.isEmpty ||
      !RegExp(r'^[A-Za-z0-9.:\-_]+$').hasMatch(host)) {
    throw ZmetaPairingException(
        'Invite code is corrupt: bad hub address.');
  }
  return ZmetaInvite(
    hubHost: host,
    pairPort: pairPort,
    wgPort: wgPort,
    token: token,
    certFpHex: certFp.toLowerCase(),
  );
}

/// Generates an X25519 keypair for WireGuard. Returns standard-base64
/// (44-char) public and private keys. The private key stays on-device.
Future<({String publicB64, String privateB64})> zmetaGenerateWgKeypair() async {
  final algorithm = X25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final privateBytes = await keyPair.extractPrivateKeyBytes();
  return (
    publicB64: base64.encode(publicKey.bytes),
    privateB64: base64.encode(privateBytes),
  );
}

/// Builds the WireGuard .conf the operator scans/imports in the
/// WireGuard app.
///
/// N11: the tunnel IP comes from the hub over the network — validate it
/// is a plain IPv4 dotted-quad before embedding it, so a compromised or
/// buggy hub cannot inject config text (e.g. newlines) into the .conf.
String zmetaBuildWgConf({
  required String privateKeyB64,
  required String tunnelIp,
  required String hubPubkey,
  required String hubEndpoint,
}) {
  final octets = tunnelIp.split('.');
  final ipOk = octets.length == 4 &&
      octets.every((o) {
        final n = int.tryParse(o);
        // o == '$n' rejects leading zeros, whitespace, empty, "+1", etc.
        return n != null && n >= 0 && n <= 255 && o == '$n';
      });
  if (!ipOk) {
    throw ZmetaPairingException(
        'Hub returned a bad tunnel address "$tunnelIp". Ask the hub '
        'operator to check the pairing service.');
  }
  // Every value is hub-supplied text going into a config file: reject
  // anything that is not exactly a key / host:port, or a newline in
  // the endpoint could add a [Peer] (AllowedIPs = 0.0.0.0/0) or a
  // PostUp script.
  if (!zmetaIsValidWgKey(privateKeyB64)) {
    throw ZmetaPairingException('Local WireGuard key is malformed.');
  }
  if (!zmetaIsValidWgKey(hubPubkey)) {
    throw ZmetaPairingException(
        'Hub returned a malformed WireGuard public key. Ask the hub '
        'operator to check the pairing service.');
  }
  if (!zmetaIsValidWgEndpoint(hubEndpoint)) {
    throw ZmetaPairingException(
        'Hub returned a malformed WireGuard endpoint. Ask the hub '
        'operator to check the pairing service.');
  }
  // The tunnel subnet is the /24 of the address the hub assigned (the
  // old fixed 10.99.0.0/24 silently black-holed any other hub subnet).
  final subnet = '${octets[0]}.${octets[1]}.${octets[2]}.0/24';
  return '[Interface]\n'
      'PrivateKey = $privateKeyB64\n'
      'Address = $tunnelIp/32\n'
      '\n'
      '[Peer]\n'
      'PublicKey = $hubPubkey\n'
      'Endpoint = $hubEndpoint\n'
      'AllowedIPs = $subnet\n'
      'PersistentKeepalive = 25\n';
}

/// A WireGuard key: standard base64 of exactly 32 bytes (44 chars).
bool zmetaIsValidWgKey(String s) {
  if (!RegExp(r'^[A-Za-z0-9+/]{43}=$').hasMatch(s)) return false;
  try {
    return base64.decode(s).length == 32;
  } catch (_) {
    return false;
  }
}

/// A WireGuard endpoint: `host:port` / `[ipv6]:port` with no whitespace
/// or control characters.
bool zmetaIsValidWgEndpoint(String s) {
  final m = RegExp(
          r'^(?:[A-Za-z0-9](?:[A-Za-z0-9.\-]*[A-Za-z0-9])?|\[[0-9A-Fa-f:.]+\]):(\d{1,5})$')
      .firstMatch(s);
  if (m == null) return false;
  final port = int.tryParse(m.group(1)!);
  return port != null && port >= 1 && port <= 65535;
}

/// Whether a hub-supplied ingest host may receive the bearer token.
///
/// Pin mode: the pinned certificate authenticates whatever host answers,
/// so any host is fine. Public-CA ("-") mode: any host with a valid
/// certificate would be accepted, so the token could be steered to an
/// attacker-chosen domain; require the ingest host to be the invite's
/// hub, a subdomain of it, or a sibling under the same parent domain.
/// Loopback is always allowed (cloudflared-on-localhost deployments).
bool zmetaIngestHostAllowed(
    String ingestHost, String inviteHost, {required bool pinMode}) {
  if (pinMode || zmetaIsLocalHost(ingestHost)) return true;
  final a = ingestHost.toLowerCase();
  final b = inviteHost.toLowerCase();
  if (a == b || a.endsWith('.$b')) return true;
  final bl = b.split('.');
  final al = a.split('.');
  if (bl.length >= 3 && al.length >= 3) {
    final parentB = bl.skip(1).join('.');
    return a.endsWith('.$parentB');
  }
  return false;
}

/// Splits a "host:port" zmeta_target into parts. Null when unparseable.
({String host, int port})? zmetaParseTarget(String target) {
  final t = target.trim();
  final idx = t.lastIndexOf(':');
  if (idx <= 0) return null;
  final host = t.substring(0, idx).replaceAll(RegExp(r'^\[|\]$'), '');
  final port = int.tryParse(t.substring(idx + 1));
  if (host.isEmpty || port == null || port < 1 || port > 65535) return null;
  return (host: host, port: port);
}

/// Effective link mode for a completed join.
///
/// ZeroTier only when the hub returned a network ID AND a usable ZT
/// target: a hub with ZeroTier on but no target set (pairing.conf)
/// returns the network ID alone, and popping that as a ZeroTier join
/// would point the emitter at whatever host was stored before the
/// join while the UI claims the mesh joined. That case falls through
/// to HTTPS/WireGuard exactly like a hub that predates ZeroTier.
/// Pure, so the malformed-target path is regression-testable without
/// driving the dialog.
String zmetaJoinLinkMode({
  required bool zerotierReturned,
  required String zerotierTarget,
  required bool ingestMode,
}) {
  if (zerotierReturned && zmetaParseTarget(zerotierTarget) != null) {
    return 'zerotier';
  }
  return ingestMode ? 'https' : 'wireguard';
}

/// Validates a hub-supplied ingest URL. Returns the normalized URL.
///
/// Rules: must be a valid absolute URI with a non-empty host; scheme
/// must be https, or http ONLY when the host is loopback (local
/// testing / cloudflared-on-localhost deployments where TLS terminates
/// at the edge). Throws [ZmetaPairingException] with a human-readable
/// reason otherwise.
String zmetaValidateIngestUrl(String raw) {
  final t = raw.trim();
  if (t.isEmpty) {
    throw ZmetaPairingException('The hub did not provide an ingest URL.');
  }
  Uri uri;
  try {
    uri = Uri.parse(t);
  } catch (_) {
    throw ZmetaPairingException('The hub provided a malformed ingest URL.');
  }
  if (!uri.isAbsolute || uri.host.isEmpty) {
    throw ZmetaPairingException('The hub provided a malformed ingest URL.');
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'https') {
    return uri.toString();
  }
  if (scheme == 'http' && zmetaIsLocalHost(uri.host)) {
    return uri.toString();
  }
  throw ZmetaPairingException(
      'The hub\'s ingest URL must be HTTPS (plain HTTP is only allowed '
      'for local testing).');
}

/// Non-throwing version of [zmetaValidateIngestUrl] for the emit gate.
bool zmetaIsUsableIngestUrl(String raw) {
  try {
    zmetaValidateIngestUrl(raw);
    return true;
  } catch (_) {
    return false;
  }
}

/// Validates a hub-supplied ingest bearer token. The token is opaque —
/// the hub mints it — so this only rejects empty/whitespace/control
/// garbage, never a well-formed token.
String zmetaValidateIngestToken(String raw) {
  final t = raw.trim();
  if (t.isEmpty || t.length < 16 || RegExp(r'\s').hasMatch(t)) {
    throw ZmetaPairingException(
        'The hub provided an unusable ingest credential. Ask the hub '
        'operator to check the pairing service.');
  }
  return t;
}

/// Hub's successful redeem response.
class ZmetaRedeemResult {
  const ZmetaRedeemResult({
    required this.tunnelIp,
    required this.hubPubkey,
    required this.hubEndpoint,
    required this.zmetaTarget,
    required this.reloadNeeded,
    this.ingestUrl = '',
    this.ingestToken = '',
    this.zerotierNetworkId = '',
    this.zerotierIp = '',
    this.zerotierIpStatus = '',
    this.zerotierIpConfirmed = false,
    this.zmetaTargetZt = '',
  });

  final String tunnelIp;
  final String hubPubkey;
  final String hubEndpoint;
  final String zmetaTarget;

  /// Hub accepted the join but its tunnel needs a manual reactivate —
  /// the operator must ask the hub operator to reactivate it.
  final bool reloadNeeded;

  /// HTTPS ingest endpoint (no-WireGuard path). Empty when the hub
  /// predates it — then the join falls back to the WireGuard flow.
  final String ingestUrl;

  /// Bearer token for [ingestUrl]. Stored in secure storage by the UI
  /// layer, never in SharedPreferences. Empty when absent.
  final String ingestToken;

  /// ZeroTier fields (present only when the redeem carried a
  /// zerotier_node_id and the hub has ZeroTier on). Empty otherwise —
  /// a hub that predates ZeroTier simply returns none of them.
  ///
  /// [zerotierIpStatus] is 'reserved' or 'confirmed'. A RESERVED IP
  /// is a hub reservation, NOT confirmed by the controller, and is
  /// not usable until the operator assigns exactly that IP to the
  /// node in the controller — the UI must never label it "Your
  /// ZeroTier IP". Only a 'confirmed' IP (controller read-back
  /// verified the member's real managed IP) is the mesh's ZeroTier IP.
  final String zerotierNetworkId;
  final String zerotierIp;
  final String zerotierIpStatus;
  final bool zerotierIpConfirmed;

  /// ZMeta target over ZeroTier (e.g. '10.99.1.1:5555'). Outride's
  /// ZMeta export host/port are set to this target when the ZeroTier
  /// transport is active.
  final String zmetaTargetZt;
}

String zmetaFingerprintHex(X509Certificate cert) => sha256
    .convert(cert.der)
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

/// Maps a hub {ok:false, error} string to a human-readable message.
///
/// [zerotier] is true when the refused redeem carried a ZeroTier node
/// ID: the shared 'pool_exhausted' string then means the ZeroTier
/// pool, not the WireGuard tunnel pool, so it gets the ZeroTier
/// wording. All other mappings are identical on either transport.
/// Every ZeroTier refusal leaves the invite usable (the redeem failed
/// before any provisioning), so the operator can fix the cause and
/// retry — the messages say so where it matters.
String zmetaHumanizeHubError(String error, {bool zerotier = false}) {
  final e = error.toLowerCase();
  if (e.contains('expired')) {
    return 'This invite code has expired. Ask the hub operator for a fresh one.';
  }
  if (e.contains('used') || e.contains('redeemed') || e.contains('consumed')) {
    return 'This invite code was already used. Codes are single-use — ask the hub operator for a new one.';
  }
  if (e.contains('rate') || e.contains('too many')) {
    return 'Too many attempts — the hub is rate-limiting. Wait a minute and try again.';
  }
  // ZeroTier refusals (ZEROTIER_JOIN_SPEC.md §2). Checked before the
  // generic branches below so none of them swallows a specific one.
  if (e.contains('bad_zerotier_node_id')) {
    return 'Node ID format is wrong — 10 hex characters.';
  }
  if (e.contains('zerotier_not_configured')) {
    return 'This hub has ZeroTier turned off. Ask the hub operator to set a ZeroTier network ID, or join over HTTPS / WireGuard instead.';
  }
  if (e.contains('zt_node_taken')) {
    return 'That ZeroTier node ID is already paired to another mesh. Check you typed your own node ID.';
  }
  if (e.contains('zerotier_not_authorized')) {
    return 'Your node is not approved in the ZeroTier controller yet. Ask the hub operator to approve you.';
  }
  if (e.contains('zerotier_no_managed_ip')) {
    return 'Your node is approved but has no managed IP in the controller. Ask the hub operator to check the network\'s IP auto-assign pool.';
  }
  if (e.contains('zerotier_controller_error')) {
    return 'The hub could not reach the ZeroTier controller. Your invite is still usable — try again, or tell the hub operator.';
  }
  if (e.contains('zerotier_ip_taken')) {
    return 'The controller\'s IP for your node is already allocated to another mesh. Tell the hub operator.';
  }
  if (e.contains('zerotier_gateway_ip_mismatch')) {
    return 'The hub does not hold its ZeroTier gateway IP. Tell the hub operator.';
  }
  if (e.contains('pool_exhausted')) {
    return zerotier
        ? 'The hub is out of ZeroTier addresses. Tell the hub operator.'
        : 'The hub is out of tunnel addresses. Ask the hub operator to expand the pool.';
  }
  // N1: explicit mappings for the hub's specific validation errors.
  if (e.contains('bad_platform_id')) {
    return 'That platform ID is invalid — use 1–32 chars: lowercase a–z, 0–9, dashes.';
  }
  if (e.contains('bad_pubkey')) {
    return 'The hub rejected this device\u2019s key. Start the join over to generate a fresh keypair.';
  }
  if (e.contains('provision_failed')) {
    return 'The hub hit a disk/config error while provisioning — your invite code is still valid. Ask the hub operator to check the hub, then try again.';
  }
  if (e.contains('state_corrupt')) {
    return 'The hub\u2019s pairing state is unreadable. Ask the hub operator to check pairing_state.json.';
  }
  if (e.contains('platform') &&
      (e.contains('taken') ||
          e.contains('exists') ||
          e.contains('duplicate') ||
          e.contains('registered'))) {
    return 'That platform ID is already registered on this hub. Change the platform ID and try again.';
  }
  if (e.contains('token') || e.contains('invalid') || e.contains('unknown')) {
    return 'The hub rejected the invite code. Check for typos, or ask the hub operator for a new code.';
  }
  return 'The hub refused the join: $error';
}

/// Redeems an invite code against the hub.
///
/// TLS is dual-mode (see library docs):
/// - 64-hex fingerprint: pin mode — HttpClient with an EMPTY trust
///   store, so default verification fails for every cert and the
///   badCertificateCallback pin is the sole gate. Any mismatch throws
///   with an explicit MITM warning.
/// - "-": Cloudflare mode — plain HttpClient() with system roots;
///   normal public-CA verification of the hub's domain.
/// 10 s timeouts throughout.
/// Redeems an invite code against the hub.
///
/// [zerotierNodeId] (ZeroTier joins only): the device's ZeroTier node
/// ID, exactly 10 hex chars from the ZeroTier One app. Validated and
/// lower-cased here (defense in depth — the dialog validates first);
/// sent as the single extra field `zerotier_node_id` in the redeem
/// body. Omitted entirely on HTTPS/WireGuard joins, so a hub that
/// predates ZeroTier sees a byte-identical redeem.
Future<ZmetaRedeemResult> zmetaRedeemInvite({
  required ZmetaInvite invite,
  required String publicKeyB64,
  required String platformId,
  String? zerotierNodeId,
}) async {
  if (!zmetaIsValidPlatformId(platformId)) {
    throw ZmetaPairingException(
        'Platform ID must be 1–32 chars: lowercase a-z, 0-9, dashes.');
  }
  // ZeroTier node ID, when this is a ZeroTier join: validate before
  // anything goes on the wire — a malformed ID must never reach the
  // hub, and the single-use invite must not be burned on it.
  String? ztNodeId;
  if (zerotierNodeId != null && zerotierNodeId.trim().isNotEmpty) {
    ztNodeId = zmetaValidateZerotierNodeId(zerotierNodeId);
  }
  final bool pinMode = invite.certFpHex != '-';
  // Pin mode: SecurityContext() has an EMPTY trust store
  // (withTrustedRoots:false), so default verification fails for EVERY
  // cert and the callback below becomes the sole gate. Cloudflare
  // mode: plain HttpClient() — system roots, normal CA verification.
  final client = pinMode
      ? HttpClient(context: SecurityContext())
      : HttpClient();
  client.connectionTimeout = const Duration(seconds: 10);
  if (pinMode) {
    // Certificate pinning: accept ONLY the exact fingerprint from the
    // invite code. This callback fires because default verification
    // always fails against the empty trust store (the hub uses a
    // self-signed cert); returning false aborts the handshake.
    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) =>
            zmetaFingerprintHex(cert) == invite.certFpHex;
  }
  String tlsFailMsg() => pinMode
      ? 'TLS CERTIFICATE MISMATCH — the hub presented a certificate '
          'that does not match the invite code. Possible interception. '
          'STOPPED. Do not proceed; contact the hub operator out-of-band.'
      : 'TLS VERIFICATION FAILED — the hub\'s certificate is not trusted '
          'by this device. Cloudflare mode needs a valid public cert on '
          'the hub domain. STOPPED. Do not proceed; contact the hub '
          'operator out-of-band.';
  try {
    late HttpClientRequest req;
    late final Uri uri;
    try {
      // Uri constructor (not Uri.parse): brackets IPv6 hosts correctly.
      uri = Uri(scheme: 'https', host: invite.hubHost, port: invite.pairPort, path: '/redeem');
    } on ArgumentError {
      throw ZmetaPairingException(
          'Invite code has an unusable hub address "${invite.hubHost}".');
    }
    try {
      req = await client
          .postUrl(uri)
          .timeout(const Duration(seconds: 10));
    } on HandshakeException {
      // Pin mode: badCertificateCallback returned false (fingerprint
      // mismatch). Cloudflare mode: the edge cert failed CA verification.
      throw ZmetaPairingException(tlsFailMsg());
    } on SocketException {
      throw ZmetaPairingException(
          'Could not reach ${invite.hubHost}:${invite.pairPort}. Check the '
          'hub address and that the pairing service is running.');
    } on TimeoutException {
      throw ZmetaPairingException(
          'Timed out reaching the hub. Check the network and try again.');
    }
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({
      'token': invite.token,
      'pubkey': publicKeyB64,
      'platform_id': platformId,
      if (ztNodeId != null) 'zerotier_node_id': ztNodeId,
    }));
    late HttpClientResponse resp;
    try {
      resp = await req.close().timeout(const Duration(seconds: 10));
    } on HandshakeException {
      throw ZmetaPairingException(tlsFailMsg());
    } on SocketException {
      throw ZmetaPairingException('Lost connection to the hub mid-join.');
    } on TimeoutException {
      throw ZmetaPairingException('The hub did not answer in time.');
    }
    // S5: bound the body read too — a stalled server must not hang the
    // join forever.
    // Also size-bound: a hostile server must not be able to stream an
    // unbounded body into memory inside the timeout.
    final bodyBytes = await resp.fold<List<int>>(<int>[], (acc, chunk) {
      if (acc.length + chunk.length > 65536) {
        throw ZmetaPairingException('The hub\'s reply was unreasonably large.');
      }
      acc.addAll(chunk);
      return acc;
    }).timeout(const Duration(seconds: 10));
    final body = utf8.decode(bodyBytes, allowMalformed: true);
    Map<String, dynamic>? doc;
    try {
      final d = jsonDecode(body);
      if (d is Map<String, dynamic>) doc = d;
    } catch (_) {}
    // The hub reports refusals as {ok:false, error} with HTTP 400/429/500,
    // so read the error body BEFORE judging the status code — otherwise
    // every specific message (expired, already used, rate limited...)
    // collapses into a generic "HTTP 400".
    if (doc == null) {
      throw ZmetaPairingException(
          'Hub returned HTTP ${resp.statusCode}. The pairing service may '
          'be misconfigured — ask the hub operator.');
    }
    if (doc['ok'] != true) {
      throw ZmetaPairingException(zmetaHumanizeHubError(
          '${doc['error'] ?? 'unknown error'}',
          zerotier: ztNodeId != null));
    }
    if (resp.statusCode != 200) {
      throw ZmetaPairingException(
          'Hub returned HTTP ${resp.statusCode}. The pairing service may '
          'be misconfigured — ask the hub operator.');
    }
    final tunnelIp = '${doc['tunnel_ip'] ?? ''}';
    final hubPubkey = '${doc['hub_pubkey'] ?? ''}';
    final hubEndpoint = '${doc['hub_endpoint'] ?? ''}';
    final zmetaTarget = '${doc['zmeta_target'] ?? ''}';
    if (tunnelIp.isEmpty || hubPubkey.isEmpty) {
      throw ZmetaPairingException(
          'Hub reply was incomplete (missing tunnel details). Ask the hub '
          'operator to check the pairing service.');
    }
    // HTTPS ingest (no-WireGuard path). Both fields are optional — hubs
    // that predate them simply don't send them, and the join falls back
    // to the WireGuard flow. Enter ingest mode ONLY when BOTH are
    // present (&&, not ||): a half-present ingest offer must never fail
    // the join — it falls back to WireGuard instead.
    var ingestUrl = '';
    var ingestToken = '';
    final rawUrl = '${doc['ingest_url'] ?? ''}';
    final rawToken = '${doc['ingest_token'] ?? ''}';
    if (rawUrl.isNotEmpty && rawToken.isNotEmpty) {
      ingestUrl = zmetaValidateIngestUrl(rawUrl);
      ingestToken = zmetaValidateIngestToken(rawToken);
      final host = Uri.parse(ingestUrl).host;
      if (!zmetaIngestHostAllowed(host, invite.hubHost, pinMode: pinMode)) {
        throw ZmetaPairingException(
            'The hub asked to send events to "$host", which is not the '
            'hub in the invite code (${invite.hubHost}). STOPPED — '
            'contact the hub operator out-of-band.');
      }
    }
    // The WireGuard conf is only built when an endpoint exists; reject
    // malformed peer data here so the failure is clear and nothing is
    // stored.
    if (hubEndpoint.isNotEmpty) {
      if (!zmetaIsValidWgKey(hubPubkey) ||
          !zmetaIsValidWgEndpoint(hubEndpoint)) {
        throw ZmetaPairingException(
            'Hub returned malformed WireGuard details. Ask the hub '
            'operator to check the pairing service.');
      }
    }
    // An HTTPS-only hub (no public WireGuard endpoint) is valid as long
    // as it handed out an ingest credential; the WireGuard fallback is
    // the only path that needs the endpoint.
    if (ingestToken.isEmpty && hubEndpoint.isEmpty) {
      throw ZmetaPairingException(
          'Hub reply was incomplete (missing tunnel details). Ask the hub '
          'operator to check the pairing service.');
    }
    // ZeroTier fields: present only when the redeem carried a node ID
    // and the hub has ZeroTier on. Validate everything hub-supplied
    // before storing it — a malformed value drops to empty (the join
    // still succeeds over the tunnel fields), never into settings.
    // A 16-hex network ID, a plain IPv4 in the mesh subnet, a status
    // of 'reserved'/'confirmed', and a ZMeta target that parses.
    var ztNetworkId = '';
    var ztIp = '';
    var ztIpStatus = '';
    var ztIpConfirmed = false;
    var ztTarget = '';
    if (ztNodeId != null) {
      final rawNet = '${doc['zerotier_network_id'] ?? ''}'.trim().toLowerCase();
      if (RegExp(r'^[0-9a-f]{16}$').hasMatch(rawNet)) ztNetworkId = rawNet;
      final rawIp = '${doc['zerotier_ip'] ?? ''}'.trim();
      if (zmetaIsValidIpv4(rawIp) && rawIp.startsWith('10.99.1.')) {
        ztIp = rawIp;
      }
      final rawStatus = '${doc['zerotier_ip_status'] ?? ''}'.trim().toLowerCase();
      if (rawStatus == 'reserved' || rawStatus == 'confirmed') {
        ztIpStatus = rawStatus;
      }
      ztIpConfirmed = doc['zerotier_ip_confirmed'] == true;
      final rawTarget = '${doc['zmeta_target_zt'] ?? ''}'.trim();
      if (zmetaParseTarget(rawTarget) != null) ztTarget = rawTarget;
    }
    return ZmetaRedeemResult(
      tunnelIp: tunnelIp,
      hubPubkey: hubPubkey,
      hubEndpoint: hubEndpoint,
      zmetaTarget: zmetaTarget,
      reloadNeeded: doc['reload_needed'] == true,
      ingestUrl: ingestUrl,
      ingestToken: ingestToken,
      zerotierNetworkId: ztNetworkId,
      zerotierIp: ztIp,
      zerotierIpStatus: ztIpStatus,
      zerotierIpConfirmed: ztIpConfirmed,
      zmetaTargetZt: ztTarget,
    );
  } finally {
    client.close(force: true);
  }
}

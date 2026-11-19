/// Fleet crypto — pure functions for Outride v0.28.0 auto-mesh.
///
/// No I/O, no clock, no Flutter imports: every function here is
/// unit-testable in isolation. See docs/auto_mesh_fleet_spec.md §5.
///
/// Honesty contract (non-negotiable): the 4-digit PIN is an ADMISSION
/// CODE, never the encryption key. The fleet key is
/// Argon2id(PIN, salt) (64 MiB, 3 iterations, 32-byte output); the
/// PBKDF2-HMAC-SHA256 600k fallback exists only if Argon2id is
/// unavailable at build time — it is available in
/// `package:cryptography` 2.9.0, so Argon2id is the live path and the
/// fallback ships for the spec's recorded-KDF case only. The fleet
/// key admits members (HMAC proof); all peer traffic is encrypted
/// under per-pair X25519 session keys (HKDF-SHA256, info
/// "outride-fleet-v1") with AES-256-GCM, AAD = fleet_id. Beacons
/// carry no PIN verifier, so offline PIN brute force is impossible.
library fleet_crypto;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto_pkg;
import 'package:cryptography/cryptography.dart';
// DartArgon2id (not exported from the package top level) for
// maxIsolates: 0 — see the note at the Argon2id constructor below.
// ignore: implementation_imports
import 'package:cryptography/src/dart/argon2.dart' show DartArgon2id;

/// Fleet multicast group / port (spec §3). Dedicated group, separate
/// from the CoT group 239.2.3.1:6969.
const String fleetMulticastGroup = '239.2.3.2';
const int fleetMulticastPort = 6970;

/// Beacon cadence and peer expiry (spec §3): 5 s beacons, gone after
/// 15 s of silence (3 missed intervals).
const int fleetBeaconIntervalSec = 5;
const int fleetPeerTimeoutSec = 15;

/// Receivers reject beacons with |clock skew| > 30 s (same as
/// CotListener.maxClockSkew).
const int fleetMaxClockSkewSec = 30;

/// Most peers held at once (spec §3). The 65th peer evicts the oldest.
const int fleetMaxPeers = 64;

/// Most fleets heard at once.
const int fleetMaxHeardFleets = 16;

/// Argon2id parameters for a phone-class CPU (spec §5): 64 MiB,
/// 3 iterations, parallelism 1, 32-byte output.
const int fleetKdfArgonMemoryKib = 65536;
const int fleetKdfArgonIterations = 3;
const int fleetKdfArgonParallelism = 1;
const int fleetKdfOutputBytes = 32;

/// PBKDF2-HMAC-SHA256 fallback: 600,000 iterations (OWASP floor),
/// 32-byte output. Recorded in the stored record's `kdf` field.
const int fleetKdfPbkdf2Iterations = 600000;

/// HKDF info string for session keys (spec §5).
const String fleetHkdfInfo = 'outride-fleet-v1';

/// KDF names recorded in the stored fleet record.
const String fleetKdfArgon2id = 'argon2id';
const String fleetKdfPbkdf2 = 'pbkdf2-hmac-sha256-600k';

/// A fleet PIN is exactly 4 decimal digits — nothing else.
bool fleetIsValidPin(String pin) =>
    pin.length == 4 && RegExp(r'^[0-9]{4}$').hasMatch(pin);

/// 16 cryptographically random bytes (the fleet salt, public value).
List<int> fleetRandomSalt() {
  final r = Random.secure();
  return List<int>.generate(16, (_) => r.nextInt(256));
}

/// 128-bit random fleet id as 32 lowercase hex chars.
String fleetRandomId() {
  final r = Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// 16-hex-char stable per-device node id.
String fleetRandomNodeId() {
  final r = Random.secure();
  final bytes = List<int>.generate(8, (_) => r.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Derive the 32-byte fleet key from [pin] + [salt].
///
/// [kdf] is `argon2id` (live path) or the PBKDF2 fallback name.
/// Throws [ArgumentError] on a malformed PIN or a salt that is not
/// exactly 16 bytes. The raw PIN is never stored — only this output.
Future<List<int>> fleetDeriveKey({
  required String pin,
  required List<int> salt,
  String kdf = fleetKdfArgon2id,
}) async {
  if (!fleetIsValidPin(pin)) {
    throw ArgumentError('Fleet PIN must be exactly 4 digits');
  }
  if (salt.length != 16) {
    throw ArgumentError('Fleet salt must be exactly 16 bytes');
  }
  if (kdf == fleetKdfPbkdf2) {
    return fleetDeriveKeyPbkdf2(pin: pin, salt: salt);
  }
  // maxIsolates: 0 — no worker isolate. The default Argon2id spawns
  // one even at parallelism 1, and an isolate spawned inside
  // flutter_test's fake-async zone never delivers its result, so a
  // widget test that derives a fleet key hangs forever. At
  // parallelism 1 there is nothing to parallelize, so the
  // in-isolate chunked path computes the identical output; its
  // 1µs yields also keep the UI responsive between 500-block
  // chunks on-device. KDF parameters are exactly per spec §5.
  const algorithm = DartArgon2id(
    parallelism: fleetKdfArgonParallelism,
    memory: fleetKdfArgonMemoryKib,
    iterations: fleetKdfArgonIterations,
    hashLength: fleetKdfOutputBytes,
    maxIsolates: 0,
  );
  final derived = await algorithm.deriveKey(
    secretKey: SecretKey(utf8.encode(pin)),
    nonce: salt,
  );
  return derived.extractBytes();
}

/// PBKDF2-HMAC-SHA256 fallback derivation (spec §5). Same contract
/// as [fleetDeriveKey]: 32-byte output, same inputs.
Future<List<int>> fleetDeriveKeyPbkdf2({
  required String pin,
  required List<int> salt,
}) async {
  if (!fleetIsValidPin(pin)) {
    throw ArgumentError('Fleet PIN must be exactly 4 digits');
  }
  if (salt.length != 16) {
    throw ArgumentError('Fleet salt must be exactly 16 bytes');
  }
  final algorithm = Pbkdf2.hmacSha256(
    iterations: fleetKdfPbkdf2Iterations,
    bits: fleetKdfOutputBytes * 8,
  );
  final derived = await algorithm.deriveKey(
    secretKey: SecretKey(utf8.encode(pin)),
    nonce: salt,
  );
  return derived.extractBytes();
}

/// HMAC-SHA256 join proof: HMAC(fleet_key,
/// eph_pub || node_id || fleet_id) (spec §5). The member holding the
/// fleet key verifies it; a wrong PIN fails the HMAC and the request
/// is silently dropped — no "wrong PIN" oracle beyond the joiner's
/// own timeout.
List<int> fleetJoinProof({
  required List<int> fleetKey,
  required List<int> ephPub,
  required String nodeId,
  required String fleetId,
}) {
  final hmac = crypto_pkg.Hmac(crypto_pkg.sha256, fleetKey);
  final msg = <int>[
    ...ephPub,
    ...utf8.encode(nodeId),
    ...utf8.encode(fleetId),
  ];
  return hmac.convert(msg).bytes;
}

/// Constant-time comparison of a presented proof against the
/// expected one. Length mismatch is a failure, never an exception.
bool fleetProofMatches(List<int> presented, List<int> expected) {
  if (presented.length != expected.length) return false;
  var diff = 0;
  for (var i = 0; i < presented.length; i++) {
    diff |= presented[i] ^ expected[i];
  }
  return diff == 0;
}

/// One ephemeral X25519 keypair for a join exchange. The private key
/// never leaves the device (zmeta_pairing.dart pattern).
class FleetEphemeral {
  FleetEphemeral._(this.keyPair, this.publicBytes, this.privateBytes);

  final SimpleKeyPair keyPair;
  final List<int> publicBytes;
  final List<int> privateBytes;
}

/// Generate a fresh ephemeral X25519 keypair.
Future<FleetEphemeral> fleetNewEphemeral() async {
  final algorithm = X25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final privateBytes = await keyPair.extractPrivateKeyBytes();
  return FleetEphemeral._(keyPair, publicKey.bytes, privateBytes);
}

/// Derive the 32-byte per-pair session key from our ephemeral
/// keypair and the peer's ephemeral public key: X25519 shared
/// secret, then HKDF-SHA256 with info "outride-fleet-v1" (spec §5).
/// Both sides derive the same key; the fleet key is never used for
/// traffic.
Future<List<int>> fleetSessionKey({
  required FleetEphemeral local,
  required List<int> remotePub,
}) async {
  final algorithm = X25519();
  final shared = await algorithm.sharedSecretKey(
    keyPair: local.keyPair,
    remotePublicKey: SimplePublicKey(remotePub, type: KeyPairType.x25519),
  );
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final derived = await hkdf.deriveKey(
    secretKey: shared,
    nonce: const <int>[],
    info: utf8.encode(fleetHkdfInfo),
  );
  return derived.extractBytes();
}

/// AES-256-GCM envelope for one peer datagram (spec §6):
/// `{"type":"fleet_data","fleet_id","from_node","nonce_b64","ct_b64"}`.
/// `ct_b64` is ciphertext || 16-byte GCM tag, base64. AAD is the
/// fleet_id. A fresh 12-byte random nonce is used per datagram.
Future<Map<String, dynamic>> fleetEncryptEnvelope({
  required List<int> sessionKey,
  required String fleetId,
  required String fromNode,
  required Map<String, dynamic> innerJson,
}) async {
  final algorithm = AesGcm.with256bits();
  final nonce = List<int>.generate(12, (_) => Random.secure().nextInt(256));
  final box = await algorithm.encrypt(
    utf8.encode(jsonEncode(innerJson)),
    secretKey: SecretKey(sessionKey),
    nonce: nonce,
    aad: utf8.encode(fleetId),
  );
  final ct = <int>[...box.cipherText, ...box.mac.bytes];
  return <String, dynamic>{
    'type': 'fleet_data',
    'fleet_id': fleetId,
    'from_node': fromNode,
    'nonce_b64': base64.encode(nonce),
    'ct_b64': base64.encode(ct),
  };
}

/// Decrypt a `fleet_data` envelope. Returns the inner JSON text, or
/// null when anything fails: wrong type / fleet_id mismatch / bad
/// nonce / replayed (nonce, sender) pair / authentication failure.
/// A failed decrypt drops the datagram silently — never throws.
///
/// [seenNonces] is the caller's replay set, keyed by
/// "$fromNode:$nonceB64". A nonce is recorded on first sight (even
/// when the decrypt then fails — a failed datagram's nonce is never
/// legitimately reused, retries use a fresh nonce). The caller owns
/// the set's bound; entries are tiny strings.
Future<String?> fleetDecryptEnvelope(
  Map<String, dynamic> j, {
  required List<int> sessionKey,
  required String expectedFleetId,
  required Set<String> seenNonces,
}) async {
  try {
    if (j['type'] != 'fleet_data') return null;
    if ('${j['fleet_id'] ?? ''}' != expectedFleetId) return null;
    final fromNode = '${j['from_node'] ?? ''}';
    if (fromNode.isEmpty) return null;
    final nonceB64 = '${j['nonce_b64'] ?? ''}';
    final nonce = base64.decode(nonceB64);
    if (nonce.length != 12) return null;
    final replayKey = '$fromNode:$nonceB64';
    if (seenNonces.contains(replayKey)) return null;
    seenNonces.add(replayKey);
    final ct = base64.decode('${j['ct_b64'] ?? ''}');
    if (ct.length < 17) return null;
    final cipherText = ct.sublist(0, ct.length - 16);
    final mac = ct.sublist(ct.length - 16);
    final algorithm = AesGcm.with256bits();
    final plain = await algorithm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
      secretKey: SecretKey(sessionKey),
      aad: utf8.encode(expectedFleetId),
    );
    return utf8.decode(plain);
  } catch (_) {
    return null;
  }
}

/// One fleet beacon (spec §3). Salt and fleet id are public values;
/// nothing secret is ever in a beacon.
class FleetBeacon {
  const FleetBeacon({
    required this.fleetId,
    required this.saltB64,
    required this.nodeId,
    required this.callsign,
    required this.appVersion,
    required this.hasSilvus,
    required this.memberCount,
    required this.t,
  });

  /// 32 lowercase hex chars.
  final String fleetId;

  /// Base64 of the 16-byte fleet salt.
  final String saltB64;

  /// 16 lowercase hex chars, stable per device.
  final String nodeId;

  /// `OUTRIDE-<first 6 of node_id>` (callsign prefix setting + id).
  final String callsign;

  final String appVersion;

  /// True iff a non-sim radio config exists and its driver is live.
  /// Re-evaluated on every beacon; the role label follows this field.
  final bool hasSilvus;

  /// Members this node currently sees (including itself).
  final int memberCount;

  /// Unix seconds, sender clock.
  final int t;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': 'fleet_beacon',
        'v': 1,
        'fleet_id': fleetId,
        'salt_b64': saltB64,
        'node_id': nodeId,
        'callsign': callsign,
        'app_version': appVersion,
        'has_silvus': hasSilvus,
        'member_count': memberCount,
        't': t,
      };

  /// Strict parse. Returns null for malformed JSON, missing
  /// fleet_id, a salt that is not 16 bytes, a bad timestamp, or
  /// |clock skew| > 30 s. Never throws.
  static FleetBeacon? tryParse(Map<String, dynamic> j, {DateTime? now}) {
    try {
      if (j['type'] != 'fleet_beacon') return null;
      if (j['v'] != 1) return null;
      final fleetId = '${j['fleet_id'] ?? ''}';
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(fleetId)) return null;
      final saltB64 = '${j['salt_b64'] ?? ''}';
      final salt = base64.decode(saltB64);
      if (salt.length != 16) return null;
      final nodeId = '${j['node_id'] ?? ''}';
      if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(nodeId)) return null;
      final callsign = '${j['callsign'] ?? ''}';
      if (callsign.isEmpty) return null;
      final memberCount = j['member_count'];
      if (memberCount is! num || memberCount < 1) return null;
      final t = j['t'];
      if (t is! num || !t.isFinite) return null;
      final beaconTime =
          DateTime.fromMillisecondsSinceEpoch((t * 1000).round(), isUtc: true);
      final ref = (now ?? DateTime.now()).toUtc();
      if (beaconTime.difference(ref).abs().inSeconds > fleetMaxClockSkewSec) {
        return null;
      }
      return FleetBeacon(
        fleetId: fleetId,
        saltB64: saltB64,
        nodeId: nodeId,
        callsign: callsign,
        appVersion: '${j['app_version'] ?? ''}',
        hasSilvus: j['has_silvus'] == true,
        memberCount: memberCount.toInt(),
        t: t.toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Parse one raw beacon datagram body. Never throws.
  static FleetBeacon? tryParseText(String text, {DateTime? now}) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return null;
      return tryParse(decoded, now: now);
    } catch (_) {
      return null;
    }
  }
}

/// Callsign for a fleet member: the CoT callsign prefix plus the
/// first 6 chars of the node id (spec §3).
String fleetCallsign(String prefix, String nodeId) =>
    '$prefix${nodeId.length >= 6 ? nodeId.substring(0, 6) : nodeId}';

/// Fleet-screen role label. Follows the live `has_silvus` beacon
/// field — never a one-time claim at join (spec §6).
String fleetRoleLabel(bool hasSilvus) =>
    hasSilvus ? 'SENSING' : 'FUSION PEER';

/// Prefix a peer sensor id with the sender callsign so a peer's
/// `rf1` can never collide with local `rf1` (spec §6). Capped at
/// the SensorProtocol 48-char `_id` limit.
String fleetPrefixedSensorId(String callsign, String sensorId) {
  final prefixed = '$callsign:$sensorId';
  if (prefixed.length > 48) return prefixed.substring(0, 48);
  return prefixed;
}

/// Fleet crypto tests (spec §10 items 1, 3, 5, 7).
///
/// KDF determinism (Argon2id + PBKDF2 fallback), join-proof
/// verification, X25519 session-key agreement, AES-GCM envelope
/// round-trip + tamper/wrong-AAD/replay rejection, beacon
/// parse/encode round-trip + malformed/skew rejection, role labels,
/// and sensor-id prefixing. Pure functions — no socket, no clock
/// beyond the beacon's injected `now`.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/fleet_crypto.dart';

void main() {
  group('fleetDeriveKey (Argon2id)', () {
    test('same PIN + salt ⇒ same 32-byte key, twice', () async {
      final salt = List<int>.generate(16, (i) => i);
      final a = await fleetDeriveKey(pin: '1234', salt: salt);
      final b = await fleetDeriveKey(pin: '1234', salt: salt);
      expect(a.length, 32);
      expect(a, b);
    });

    test('different salt ⇒ different key', () async {
      final saltA = List<int>.generate(16, (i) => i);
      final saltB = List<int>.generate(16, (i) => 15 - i);
      final a = await fleetDeriveKey(pin: '1234', salt: saltA);
      final b = await fleetDeriveKey(pin: '1234', salt: saltB);
      expect(a, isNot(b));
    });

    test('wrong PIN ⇒ different key', () async {
      final salt = List<int>.generate(16, (i) => i);
      final a = await fleetDeriveKey(pin: '1234', salt: salt);
      final b = await fleetDeriveKey(pin: '9999', salt: salt);
      expect(a, isNot(b));
    });

    test('malformed PIN and salt throw ArgumentError', () async {
      final salt = List<int>.generate(16, (i) => i);
      await expectLater(
          fleetDeriveKey(pin: '123', salt: salt),
          throwsArgumentError);
      await expectLater(
          fleetDeriveKey(pin: '12a4', salt: salt),
          throwsArgumentError);
      await expectLater(
          fleetDeriveKey(pin: '12345', salt: salt),
          throwsArgumentError);
      await expectLater(
          fleetDeriveKey(pin: '1234', salt: [1, 2, 3]),
          throwsArgumentError);
    });

    test('fleetIsValidPin accepts only 4 digits', () {
      expect(fleetIsValidPin('1234'), isTrue);
      expect(fleetIsValidPin('0000'), isTrue);
      expect(fleetIsValidPin('123'), isFalse);
      expect(fleetIsValidPin('12345'), isFalse);
      expect(fleetIsValidPin('12a4'), isFalse);
      expect(fleetIsValidPin(''), isFalse);
    });
  });

  group('fleetDeriveKeyPbkdf2 (fallback)', () {
    test('same PIN + salt ⇒ same 32-byte key, twice', () async {
      final salt = List<int>.generate(16, (i) => i);
      final a = await fleetDeriveKeyPbkdf2(pin: '1234', salt: salt);
      final b = await fleetDeriveKeyPbkdf2(pin: '1234', salt: salt);
      expect(a.length, 32);
      expect(a, b);
    });

    test('different salt and wrong PIN ⇒ different keys', () async {
      final salt = List<int>.generate(16, (i) => i);
      final base = await fleetDeriveKeyPbkdf2(pin: '1234', salt: salt);
      final otherSalt = await fleetDeriveKeyPbkdf2(
          pin: '1234', salt: List<int>.generate(16, (i) => 15 - i));
      final wrongPin =
          await fleetDeriveKeyPbkdf2(pin: '9999', salt: salt);
      expect(otherSalt, isNot(base));
      expect(wrongPin, isNot(base));
    });

    test('fallback differs from Argon2id for the same inputs', () async {
      final salt = List<int>.generate(16, (i) => i);
      final argon = await fleetDeriveKey(pin: '1234', salt: salt);
      final pbkdf2 = await fleetDeriveKey(
          pin: '1234', salt: salt, kdf: fleetKdfPbkdf2);
      expect(pbkdf2, isNot(argon));
    });
  });

  group('join proof (HMAC)', () {
    test('proof verifies for the right key, fails for the wrong PIN',
        () async {
      final salt = List<int>.generate(16, (i) => i);
      final key = await fleetDeriveKey(pin: '1234', salt: salt);
      final wrongKey = await fleetDeriveKey(pin: '9999', salt: salt);
      final ephPub = List<int>.generate(32, (i) => i);
      const fleetId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const nodeId = 'bbbbbbbbbbbbbbbb';
      final proof = fleetJoinProof(
          fleetKey: key,
          ephPub: ephPub,
          nodeId: nodeId,
          fleetId: fleetId);
      final expected = fleetJoinProof(
          fleetKey: key,
          ephPub: ephPub,
          nodeId: nodeId,
          fleetId: fleetId);
      expect(fleetProofMatches(proof, expected), isTrue);
      final wrongExpected = fleetJoinProof(
          fleetKey: wrongKey,
          ephPub: ephPub,
          nodeId: nodeId,
          fleetId: fleetId);
      expect(fleetProofMatches(proof, wrongExpected), isFalse);
      // One flipped bit fails.
      final flipped = List<int>.of(proof)..[0] ^= 1;
      expect(fleetProofMatches(flipped, expected), isFalse);
      // Length mismatch fails, never throws.
      expect(fleetProofMatches(proof.sublist(0, 16), expected),
          isFalse);
    });
  });

  group('session keys (X25519 + HKDF)', () {
    test('both sides derive the same 32-byte session key', () async {
      final a = await fleetNewEphemeral();
      final b = await fleetNewEphemeral();
      final keyA =
          await fleetSessionKey(local: a, remotePub: b.publicBytes);
      final keyB =
          await fleetSessionKey(local: b, remotePub: a.publicBytes);
      expect(keyA.length, 32);
      expect(keyA, keyB);
    });

    test('a third keypair derives a different session key', () async {
      final a = await fleetNewEphemeral();
      final b = await fleetNewEphemeral();
      final c = await fleetNewEphemeral();
      final keyAB =
          await fleetSessionKey(local: a, remotePub: b.publicBytes);
      final keyAC =
          await fleetSessionKey(local: a, remotePub: c.publicBytes);
      expect(keyAC, isNot(keyAB));
    });
  });

  group('fleet_data envelope (AES-256-GCM)', () {
    const fleetId = 'cccccccccccccccccccccccccccccccc';
    final inner = <String, dynamic>{
      'type': 'sensor_obs',
      'obs': 'ENERGY',
      'sensor': 'rf1',
      'level_db': -67.0,
      't': 1731849600,
    };

    test('encrypt ⇒ decrypt ⇒ inner sensor_obs parses', () async {
      final session = List<int>.generate(32, (i) => i);
      final env = await fleetEncryptEnvelope(
        sessionKey: session,
        fleetId: fleetId,
        fromNode: 'd' * 16,
        innerJson: inner,
      );
      expect(env['type'], 'fleet_data');
      final seen = <String>{};
      final plain = await fleetDecryptEnvelope(
        env,
        sessionKey: session,
        expectedFleetId: fleetId,
        seenNonces: seen,
      );
      expect(plain, isNotNull);
      final decoded = jsonDecode(plain!) as Map<String, dynamic>;
      expect(decoded['type'], 'sensor_obs');
      expect(decoded['obs'], 'ENERGY');
      expect(decoded['sensor'], 'rf1');
    });

    test('tampered ciphertext ⇒ dropped', () async {
      final session = List<int>.generate(32, (i) => i);
      final env = await fleetEncryptEnvelope(
        sessionKey: session,
        fleetId: fleetId,
        fromNode: 'd' * 16,
        innerJson: inner,
      );
      final ct = base64.decode(env['ct_b64'] as String);
      ct[0] ^= 1;
      env['ct_b64'] = base64.encode(ct);
      final plain = await fleetDecryptEnvelope(
        env,
        sessionKey: session,
        expectedFleetId: fleetId,
        seenNonces: <String>{},
      );
      expect(plain, isNull);
    });

    test('wrong fleet_id AAD ⇒ dropped', () async {
      final session = List<int>.generate(32, (i) => i);
      final env = await fleetEncryptEnvelope(
        sessionKey: session,
        fleetId: fleetId,
        fromNode: 'd' * 16,
        innerJson: inner,
      );
      final plain = await fleetDecryptEnvelope(
        env,
        sessionKey: session,
        expectedFleetId: 'e' * 32,
        seenNonces: <String>{},
      );
      expect(plain, isNull);
    });

    test('wrong session key ⇒ dropped', () async {
      final session = List<int>.generate(32, (i) => i);
      final env = await fleetEncryptEnvelope(
        sessionKey: session,
        fleetId: fleetId,
        fromNode: 'd' * 16,
        innerJson: inner,
      );
      final plain = await fleetDecryptEnvelope(
        env,
        sessionKey: List<int>.generate(32, (i) => 31 - i),
        expectedFleetId: fleetId,
        seenNonces: <String>{},
      );
      expect(plain, isNull);
    });

    test('replayed nonce ⇒ dropped on second delivery', () async {
      final session = List<int>.generate(32, (i) => i);
      final env = await fleetEncryptEnvelope(
        sessionKey: session,
        fleetId: fleetId,
        fromNode: 'd' * 16,
        innerJson: inner,
      );
      final seen = <String>{};
      final first = await fleetDecryptEnvelope(
        env,
        sessionKey: session,
        expectedFleetId: fleetId,
        seenNonces: seen,
      );
      expect(first, isNotNull);
      final second = await fleetDecryptEnvelope(
        env,
        sessionKey: session,
        expectedFleetId: fleetId,
        seenNonces: seen,
      );
      expect(second, isNull);
    });

    test('same nonce from a different sender is not a replay', () async {
      final session = List<int>.generate(32, (i) => i);
      final envA = await fleetEncryptEnvelope(
        sessionKey: session,
        fleetId: fleetId,
        fromNode: 'd' * 16,
        innerJson: inner,
      );
      // Reuse A's nonce with a different sender: a fresh envelope
      // would never share a nonce, but the replay key is
      // (sender, nonce) by design — prove the keying, not the RNG.
      final envB = Map<String, dynamic>.of(envA)
        ..['from_node'] = 'f' * 16;
      final seen = <String>{};
      expect(
          await fleetDecryptEnvelope(envA,
              sessionKey: session,
              expectedFleetId: fleetId,
              seenNonces: seen),
          isNotNull);
      // envB fails authentication (from_node is not AAD, but the
      // ciphertext was built for A — actually AAD is fleet_id only,
      // so envB decrypts: the point is only that the replay key
      // differs, so it is NOT dropped as a replay).
      expect(
          await fleetDecryptEnvelope(envB,
              sessionKey: session,
              expectedFleetId: fleetId,
              seenNonces: seen),
          isNotNull);
    });
  });

  group('FleetBeacon parse/encode', () {
    final now = DateTime.utc(2026, 11, 17, 12, 0, 0);

    FleetBeacon sampleBeacon() => FleetBeacon(
          fleetId: 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
          saltB64: base64.encode(List<int>.generate(16, (i) => i)),
          nodeId: '0123456789abcdef',
          callsign: 'OUTRIDE-012345',
          appVersion: '0.28.0',
          hasSilvus: true,
          memberCount: 3,
          t: now.millisecondsSinceEpoch ~/ 1000,
        );

    test('round-trip: JSON ⇒ struct ⇒ JSON identical', () {
      final b = sampleBeacon();
      final parsed = FleetBeacon.tryParse(b.toJson(), now: now);
      expect(parsed, isNotNull);
      expect(parsed!.toJson(), b.toJson());
    });

    test('malformed JSON / missing fleet_id / bad t ⇒ dropped',
        () {
      expect(FleetBeacon.tryParseText('not json', now: now), isNull);
      expect(FleetBeacon.tryParseText('{"type":"x"}', now: now),
          isNull);
      final missingId = sampleBeacon().toJson()..remove('fleet_id');
      expect(FleetBeacon.tryParse(missingId, now: now), isNull);
      final badSalt = sampleBeacon().toJson()
        ..['salt_b64'] = base64.encode([1, 2, 3]);
      expect(FleetBeacon.tryParse(badSalt, now: now), isNull);
      final badNode = sampleBeacon().toJson()..['node_id'] = 'zzz';
      expect(FleetBeacon.tryParse(badNode, now: now), isNull);
      final badT = sampleBeacon().toJson()..['t'] = 'soon';
      expect(FleetBeacon.tryParse(badT, now: now), isNull);
      final wrongType = sampleBeacon().toJson()
        ..['type'] = 'fleet_join';
      expect(FleetBeacon.tryParse(wrongType, now: now), isNull);
    });

    test('skew > 30 s ⇒ dropped; skew within 30 s ⇒ kept', () {
      final future = sampleBeacon().toJson()
        ..['t'] = now.millisecondsSinceEpoch ~/ 1000 + 31;
      expect(FleetBeacon.tryParse(future, now: now), isNull);
      final past = sampleBeacon().toJson()
        ..['t'] = now.millisecondsSinceEpoch ~/ 1000 - 31;
      expect(FleetBeacon.tryParse(past, now: now), isNull);
      final edge = sampleBeacon().toJson()
        ..['t'] = now.millisecondsSinceEpoch ~/ 1000 + 30;
      expect(FleetBeacon.tryParse(edge, now: now), isNotNull);
    });
  });

  group('roles and sensor-id prefixing', () {
    test('has_silvus true ⇒ SENSING, false ⇒ FUSION PEER', () {
      expect(fleetRoleLabel(true), 'SENSING');
      expect(fleetRoleLabel(false), 'FUSION PEER');
    });

    test('callsign is prefix + first 6 of node id', () {
      expect(fleetCallsign('OUTRIDE-', '0123456789abcdef'),
          'OUTRIDE-012345');
    });

    test('peer sensor ids are prefixed and capped at 48 chars', () {
      expect(fleetPrefixedSensorId('OUTRIDE-012345', 'rf1'),
          'OUTRIDE-012345:rf1');
      final long = fleetPrefixedSensorId(
          'OUTRIDE-012345', 'x' * 60);
      expect(long.length, 48);
      expect(long.startsWith('OUTRIDE-012345:'), isTrue);
    });
  });
}

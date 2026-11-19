/// Fleet service tests (spec §10 items 2, 4, 6, 7).
///
/// PIN rate-limit behavior (fake clock), fleet persistence
/// round-trip + PIN absence + forget, beacon dedup/expiry/64-peer
/// cap, the join handshake at message level (right PIN admits,
/// wrong PIN is silently dropped and rate-limited), and the
/// fleet_data ingest path (decrypt ⇒ SensorProtocol.parseUdpJson,
/// tamper/replay dropped, sensor id prefixed).
///
/// No sockets are bound here: beacons and join messages are driven
/// through the socket-free handlers, and persistence is the
/// in-memory store. No synthetic RF data anywhere — the only
/// "sensor" payload is a hand-written ENERGY observation.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/models/sensor_observation.dart';
import 'package:outride/services/fleet_crypto.dart';
import 'package:outride/services/fleet_service.dart';
import 'package:outride/services/sensor_protocol.dart';

void main() {
  group('FleetJoinRateLimiter', () {
    test('5 failures from one IP ⇒ lockout; expiry re-admits', () {
      var now = DateTime.utc(2026, 11, 17, 12);
      final limiter = FleetJoinRateLimiter(now: () => now);
      const ip = '192.168.1.10';
      for (var i = 0; i < 4; i++) {
        expect(limiter.allowAttempt(ip), isTrue);
        limiter.recordFailure(ip);
      }
      expect(limiter.allowAttempt(ip), isTrue);
      limiter.recordFailure(ip);
      expect(limiter.allowAttempt(ip), isFalse);
      // 29 s into the 30 s lockout: still locked.
      now = now.add(const Duration(seconds: 29));
      expect(limiter.allowAttempt(ip), isFalse);
      // 31 s: lockout expired, attempts allowed again.
      now = now.add(const Duration(seconds: 2));
      expect(limiter.allowAttempt(ip), isTrue);
    });

    test('backoff grows 30/60/120/300 s and caps', () {
      var now = DateTime.utc(2026, 11, 17, 12);
      final limiter = FleetJoinRateLimiter(now: () => now);
      const ip = '192.168.1.10';
      final expected = [30, 60, 120, 300, 300];
      for (final backoff in expected) {
        for (var i = 0; i < 5; i++) {
          limiter.recordFailure(ip);
        }
        expect(limiter.allowAttempt(ip), isFalse);
        expect(limiter.lockoutRemainingSec(ip), backoff);
        now = now.add(Duration(seconds: backoff + 1));
        expect(limiter.allowAttempt(ip), isTrue);
      }
    });

    test('global 10 failures/min ⇒ 60 s fleet-wide freeze', () {
      var now = DateTime.utc(2026, 11, 17, 12);
      final limiter = FleetJoinRateLimiter(now: () => now);
      for (var i = 0; i < 10; i++) {
        limiter.recordFailure('192.168.1.${20 + i}');
      }
      expect(limiter.isFrozen, isTrue);
      // An unrelated IP is frozen too.
      expect(limiter.allowAttempt('192.168.1.99'), isFalse);
      now = now.add(const Duration(seconds: 59));
      expect(limiter.allowAttempt('192.168.1.99'), isFalse);
      now = now.add(const Duration(seconds: 2));
      expect(limiter.allowAttempt('192.168.1.99'), isTrue);
      expect(limiter.isFrozen, isFalse);
    });

    test('a success resets the per-IP counter', () {
      var now = DateTime.utc(2026, 11, 17, 12);
      final limiter = FleetJoinRateLimiter(now: () => now);
      const ip = '192.168.1.10';
      for (var i = 0; i < 4; i++) {
        limiter.recordFailure(ip);
      }
      limiter.recordSuccess(ip);
      // Four more failures after the reset must not lock out.
      for (var i = 0; i < 4; i++) {
        expect(limiter.allowAttempt(ip), isTrue);
        limiter.recordFailure(ip);
      }
      expect(limiter.allowAttempt(ip), isTrue);
      limiter.recordFailure(ip);
      expect(limiter.allowAttempt(ip), isFalse);
    });

    test('different IPs are limited independently', () {
      final limiter = FleetJoinRateLimiter();
      for (var i = 0; i < 5; i++) {
        limiter.recordFailure('192.168.1.10');
      }
      expect(limiter.allowAttempt('192.168.1.10'), isFalse);
      expect(limiter.allowAttempt('192.168.1.11'), isTrue);
    });
  });

  group('FleetService persistence', () {
    test('store record ⇒ reload ⇒ same fleet_id/salt; key survives',
        () async {
      final store = FleetMemoryPersistence();
      final service = FleetService(persistence: store);
      final rec = await service.createFleet('1234');
      expect(service.inFleet, isTrue);
      expect(rec.fleetId.length, 32);
      expect(rec.kdf, fleetKdfArgon2id);

      // Reload through a second service over the same store.
      final reloaded = FleetService(persistence: store);
      await reloaded.init();
      expect(reloaded.inFleet, isTrue);
      expect(reloaded.record!.fleetId, rec.fleetId);
      expect(reloaded.record!.saltB64, rec.saltB64);
      expect(reloaded.record!.nodeId, rec.nodeId);
      final key = await store.loadKey();
      expect(key, isNotNull);
      expect(key!.length, 32);
      await service.stop();
      await reloaded.stop();
    });

    test('raw PIN is absent from both stores', () async {
      final store = FleetMemoryPersistence();
      final service = FleetService(persistence: store);
      await service.createFleet('1234');
      for (final written in store.writtenStrings) {
        expect(written.contains('1234'), isFalse,
            reason: 'raw PIN leaked into a store: $written');
      }
      await service.stop();
    });

    test('Forget fleet deletes both stores and drops the fleet',
        () async {
      final store = FleetMemoryPersistence();
      final service = FleetService(persistence: store);
      await service.createFleet('1234');
      expect(service.inFleet, isTrue);
      await service.forgetFleet();
      expect(service.inFleet, isFalse);
      expect(await store.loadRecord(), isNull);
      expect(await store.loadKey(), isNull);
      final reloaded = FleetService(persistence: store);
      await reloaded.init();
      expect(reloaded.inFleet, isFalse);
      await service.stop();
      await reloaded.stop();
    });

    test('node id is stable across services over the same store',
        () async {
      final store = FleetMemoryPersistence();
      final a = FleetService(persistence: store);
      final b = FleetService(persistence: store);
      final idA = await a.ensureNodeId();
      final idB = await b.ensureNodeId();
      expect(idA, idB);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(idA), isTrue);
      await a.stop();
      await b.stop();
    });
  });

  group('FleetService peers (beacon dedup/expiry)', () {
    FleetBeacon beaconFor(String nodeId, String fleetId, DateTime at,
        {bool hasSilvus = true}) {
      return FleetBeacon(
        fleetId: fleetId,
        saltB64: base64.encode(List<int>.generate(16, (i) => i)),
        nodeId: nodeId,
        callsign: 'OUTRIDE-${nodeId.substring(0, 6)}',
        appVersion: '0.28.0',
        hasSilvus: hasSilvus,
        memberCount: 2,
        t: at.toUtc().millisecondsSinceEpoch ~/ 1000,
      );
    }

    test('repeat beacons from one node_id ⇒ one peer', () async {
      var now = DateTime.utc(2026, 11, 17, 12);
      final store = FleetMemoryPersistence();
      final service =
          FleetService(persistence: store, now: () => now);
      final rec = await service.createFleet('1234');
      final b = beaconFor('1111111111111111', rec.fleetId, now);
      service.handleDatagramText(jsonEncode(b.toJson()), '10.0.0.2',
          now: now);
      service.handleDatagramText(jsonEncode(b.toJson()), '10.0.0.2',
          now: now);
      service.handleDatagramText(jsonEncode(b.toJson()), '10.0.0.2',
          now: now);
      expect(service.peers.length, 1);
      expect(service.peers.first.callsign, 'OUTRIDE-111111');
      expect(service.peers.first.roleLabel, 'SENSING');
      await service.stop();
    });

    test('15 s silence ⇒ peer GONE and removed', () async {
      var now = DateTime.utc(2026, 11, 17, 12);
      final store = FleetMemoryPersistence();
      final service =
          FleetService(persistence: store, now: () => now);
      final rec = await service.createFleet('1234');
      final b = beaconFor('1111111111111111', rec.fleetId, now);
      service.handleDatagramText(jsonEncode(b.toJson()), '10.0.0.2',
          now: now);
      expect(service.peers.length, 1);
      // 14 s later: still held (STALE, not gone).
      now = now.add(const Duration(seconds: 14));
      service.pruneForTest(now);
      expect(service.peers.length, 1);
      expect(service.peers.first.linkStateAt(now), 'STALE');
      // 16 s: gone.
      now = now.add(const Duration(seconds: 2));
      service.pruneForTest(now);
      expect(service.peers, isEmpty);
      await service.stop();
    });

    test('role label follows the live has_silvus beacon field',
        () async {
      var now = DateTime.utc(2026, 11, 17, 12);
      final store = FleetMemoryPersistence();
      final service =
          FleetService(persistence: store, now: () => now);
      final rec = await service.createFleet('1234');
      final sensing = beaconFor(
          '1111111111111111', rec.fleetId, now,
          hasSilvus: true);
      service.handleDatagramText(
          jsonEncode(sensing.toJson()), '10.0.0.2',
          now: now);
      expect(service.peers.first.roleLabel, 'SENSING');
      // Same node, radio unplugged: the label flips within one
      // beacon interval.
      now = now.add(const Duration(seconds: 5));
      final fusion = beaconFor(
          '1111111111111111', rec.fleetId, now,
          hasSilvus: false);
      service.handleDatagramText(
          jsonEncode(fusion.toJson()), '10.0.0.2',
          now: now);
      expect(service.peers.length, 1);
      expect(service.peers.first.roleLabel, 'FUSION PEER');
      await service.stop();
    });

    test('64-peer cap drops the oldest, never crashes', () async {
      var now = DateTime.utc(2026, 11, 17, 12);
      final store = FleetMemoryPersistence();
      final service =
          FleetService(persistence: store, now: () => now);
      final rec = await service.createFleet('1234');
      for (var i = 0; i < 70; i++) {
        final nodeId = i.toRadixString(16).padLeft(16, '0');
        final b = beaconFor(nodeId, rec.fleetId, now);
        service.handleDatagramText(
            jsonEncode(b.toJson()), '10.0.0.${2 + (i % 50)}',
            now: now);
        now = now.add(const Duration(milliseconds: 100));
      }
      expect(service.peers.length, fleetMaxPeers);
      await service.stop();
    });

    test('beacons for other fleets land in heard, not peers', () async {
      final now = DateTime.utc(2026, 11, 17, 12);
      final store = FleetMemoryPersistence();
      final service =
          FleetService(persistence: store, now: () => now);
      final rec = await service.createFleet('1234');
      final other = beaconFor(
          '2222222222222222', 'f' * 32, now);
      service.handleDatagramText(
          jsonEncode(other.toJson()), '10.0.0.3',
          now: now);
      expect(service.peers, isEmpty);
      expect(service.heardFleets.length, 1);
      expect(service.heardFleets.first.shortId, 'ffffff');
      // Our own fleet never appears as heard.
      final own = beaconFor('3333333333333333', rec.fleetId, now);
      service.handleDatagramText(
          jsonEncode(own.toJson()), '10.0.0.4',
          now: now);
      expect(service.heardFleets.length, 1);
      await service.stop();
    });

    test('malformed beacons are dropped, never throw', () async {
      final store = FleetMemoryPersistence();
      final service = FleetService(persistence: store);
      await service.createFleet('1234');
      service.handleDatagramText('not json', '10.0.0.2');
      service.handleDatagramText('{"type":"fleet_beacon"}', '10.0.0.2');
      service.handleDatagramText('[]', '10.0.0.2');
      expect(service.peers, isEmpty);
      expect(service.heardFleets, isEmpty);
      await service.stop();
    });
  });

  group('FleetService join handshake (message level)', () {
    test('right PIN admits: member answers, joiner stores a session',
        () async {
      final memberStore = FleetMemoryPersistence();
      final member = FleetService(persistence: memberStore);
      final rec = await member.createFleet('1234');
      await member.ensureNodeId();

      final joinerStore = FleetMemoryPersistence();
      final joiner = FleetService(persistence: joinerStore);
      final heard = FleetHeard(
        fleetId: rec.fleetId,
        saltB64: rec.saltB64,
        memberCount: 1,
        lastSeen: DateTime.now(),
        address: '10.0.0.2',
      );
      final key = await fleetDeriveKey(
          pin: '1234', salt: base64.decode(rec.saltB64));
      final built = await joiner.buildJoinRequest(
          heard: heard, candidateKey: key);
      expect(built, isNotNull);
      final (request, ephemeral) = built!;
      final reply =
          await member.answerJoinRequestAsync(request, '10.0.0.9');
      expect(reply, isNotNull);
      expect(reply!['type'], 'fleet_join_reply');
      final ok = await joiner.completeJoinFromReply(
        reply: reply,
        ephemeral: ephemeral,
        candidateKey: key,
        heard: heard,
      );
      expect(ok, isTrue);
      expect(joiner.inFleet, isTrue);
      expect(joiner.record!.fleetId, rec.fleetId);
      expect(joiner.sessionsForTest.length, 1);
      expect(member.sessionsForTest.length, 1);
      // Both sides derived the same session key.
      final joinerKey = joiner.sessionsForTest.values.first;
      final memberKey = member.sessionsForTest.values.first;
      expect(joinerKey, memberKey);
      await member.stop();
      await joiner.stop();
    });

    test('wrong PIN: member drops silently and rate-limits', () async {
      final memberStore = FleetMemoryPersistence();
      final member = FleetService(persistence: memberStore);
      final rec = await member.createFleet('1234');
      await member.ensureNodeId();

      final joiner = FleetService(persistence: FleetMemoryPersistence());
      final heard = FleetHeard(
        fleetId: rec.fleetId,
        saltB64: rec.saltB64,
        memberCount: 1,
        lastSeen: DateTime.now(),
        address: '10.0.0.2',
      );
      final wrongKey = await fleetDeriveKey(
          pin: '9999', salt: base64.decode(rec.saltB64));
      final built = await joiner.buildJoinRequest(
          heard: heard, candidateKey: wrongKey);
      final (request, _) = built!;
      final reply =
          await member.answerJoinRequestAsync(request, '10.0.0.9');
      expect(reply, isNull);
      expect(member.sessionsForTest, isEmpty);
      expect(joiner.inFleet, isFalse);
      await member.stop();
      await joiner.stop();
    });

    test('join request for an unknown fleet is dropped', () async {
      final member = FleetService(persistence: FleetMemoryPersistence());
      await member.createFleet('1234');
      final request = <String, dynamic>{
        'type': 'fleet_join',
        'fleet_id': 'e' * 32,
        'node_id': 'a' * 16,
        'callsign': 'OUTRIDE-aaaaaa',
        'eph_pub_b64': base64.encode(List<int>.filled(32, 1)),
        'proof_b64': base64.encode(List<int>.filled(32, 2)),
      };
      expect(
          await member.answerJoinRequestAsync(request, '10.0.0.9'),
          isNull);
      await member.stop();
    });
  });

  group('FleetService peer-data ingest', () {
    test('fleet_data decrypts ⇒ parseUdpJson ⇒ prefixed observation',
        () async {
      final received = <SensorObservation>[];
      final memberStore = FleetMemoryPersistence();
      final member = FleetService(
        persistence: memberStore,
        onPeerObservation: received.add,
      );
      final rec = await member.createFleet('1234');
      await member.ensureNodeId();
      final memberNodeId = await member.ensureNodeId();

      // Joiner side: build a session with the member, then encrypt
      // one ENERGY observation as the joiner would.
      final joinerStore = FleetMemoryPersistence();
      final joiner = FleetService(persistence: joinerStore);
      final heard = FleetHeard(
        fleetId: rec.fleetId,
        saltB64: rec.saltB64,
        memberCount: 1,
        lastSeen: DateTime.now(),
        address: '10.0.0.2',
      );
      final key = await fleetDeriveKey(
          pin: '1234', salt: base64.decode(rec.saltB64));
      final built = await joiner.buildJoinRequest(
          heard: heard, candidateKey: key);
      final (request, ephemeral) = built!;
      final reply =
          await member.answerJoinRequestAsync(request, '10.0.0.9');
      expect(reply, isNotNull);
      await joiner.completeJoinFromReply(
        reply: reply!,
        ephemeral: ephemeral,
        candidateKey: key,
        heard: heard,
      );
      final sessionKey =
          joiner.sessionsForTest[memberNodeId]!;
      final joinerNodeId = await joiner.ensureNodeId();

      // The member must know the joiner as a peer for the callsign
      // prefix; feed it one beacon first.
      final beacon = FleetBeacon(
        fleetId: rec.fleetId,
        saltB64: rec.saltB64,
        nodeId: joinerNodeId,
        callsign: 'OUTRIDE-${joinerNodeId.substring(0, 6)}',
        appVersion: '0.28.0',
        hasSilvus: true,
        memberCount: 2,
        t: DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
      );
      member.handleDatagramText(
          jsonEncode(beacon.toJson()), '10.0.0.9');

      final inner = SensorProtocol.toUdpJson(SensorObservation(
        type: SensorObsType.energy,
        sensorId: 'rf1',
        timestamp: DateTime.utc(2026, 11, 17, 12),
        levelDb: -67.0,
      ));
      final envelope = await fleetEncryptEnvelope(
        sessionKey: sessionKey,
        fleetId: rec.fleetId,
        fromNode: joinerNodeId,
        innerJson: inner,
      );
      await member.handleFleetDataText(jsonEncode(envelope));
      expect(received.length, 1);
      expect(received.first.sensorId,
          'OUTRIDE-${joinerNodeId.substring(0, 6)}:rf1');
      expect(received.first.type, SensorObsType.energy);
      expect(received.first.levelDb, -67.0);
      await member.stop();
      await joiner.stop();
    });

    test('tampered fleet_data and replayed envelopes are dropped',
        () async {
      final received = <SensorObservation>[];
      final member = FleetService(
        persistence: FleetMemoryPersistence(),
        onPeerObservation: received.add,
      );
      final rec = await member.createFleet('1234');
      final joiner = FleetService(persistence: FleetMemoryPersistence());
      final heard = FleetHeard(
        fleetId: rec.fleetId,
        saltB64: rec.saltB64,
        memberCount: 1,
        lastSeen: DateTime.now(),
        address: '10.0.0.2',
      );
      final key = await fleetDeriveKey(
          pin: '1234', salt: base64.decode(rec.saltB64));
      final built = await joiner.buildJoinRequest(
          heard: heard, candidateKey: key);
      final (request, ephemeral) = built!;
      final reply =
          await member.answerJoinRequestAsync(request, '10.0.0.9');
      await joiner.completeJoinFromReply(
        reply: reply!,
        ephemeral: ephemeral,
        candidateKey: key,
        heard: heard,
      );
      final memberNodeId = await member.ensureNodeId();
      final joinerNodeId = await joiner.ensureNodeId();
      final sessionKey = joiner.sessionsForTest[memberNodeId]!;
      final inner = SensorProtocol.toUdpJson(SensorObservation(
        type: SensorObsType.energy,
        sensorId: 'rf1',
        timestamp: DateTime.utc(2026, 11, 17, 12),
        levelDb: -67.0,
      ));
      // Tampered ciphertext (its own fresh nonce — a tampered copy
      // burns its nonce, so the genuine envelope needs a separate
      // encryption, exactly as a real sender would produce).
      final tamperedEnv = await fleetEncryptEnvelope(
        sessionKey: sessionKey,
        fleetId: rec.fleetId,
        fromNode: joinerNodeId,
        innerJson: inner,
      );
      final ct = base64.decode(tamperedEnv['ct_b64'] as String);
      ct[0] ^= 1;
      tamperedEnv['ct_b64'] = base64.encode(ct);
      await member.handleFleetDataText(jsonEncode(tamperedEnv));
      expect(received, isEmpty);
      // Genuine envelope: accepted once, replay dropped.
      final envelope = await fleetEncryptEnvelope(
        sessionKey: sessionKey,
        fleetId: rec.fleetId,
        fromNode: joinerNodeId,
        innerJson: inner,
      );
      await member.handleFleetDataText(jsonEncode(envelope));
      expect(received.length, 1);
      await member.handleFleetDataText(jsonEncode(envelope));
      expect(received.length, 1);
      // Plain sensor_obs on the hub is not fleet data: untouched.
      await member.handleFleetDataText(jsonEncode(inner));
      expect(received.length, 1);
      await member.stop();
      await joiner.stop();
    });

    test('shareObservation is a no-op when unjoined or fusion-only',
        () async {
      final service = FleetService(
        persistence: FleetMemoryPersistence(),
        hasSilvus: () => true,
      );
      // Unjoined: no sessions, no socket — must not throw.
      await service.shareObservation(SensorObservation(
        type: SensorObsType.energy,
        sensorId: 'rf1',
        timestamp: DateTime.now(),
        levelDb: -67.0,
      ));
      final fusion = FleetService(
        persistence: FleetMemoryPersistence(),
        hasSilvus: () => false,
      );
      await fusion.createFleet('1234');
      await fusion.shareObservation(SensorObservation(
        type: SensorObsType.energy,
        sensorId: 'rf1',
        timestamp: DateTime.now(),
        levelDb: -67.0,
      ));
      await service.stop();
      await fusion.stop();
    });
  });

  group('FleetService join-reply authentication (Fix 1)', () {
    Future<(FleetService, FleetService, FleetRecord, List<int>)>
        joinedPair() async {
      final memberStore = FleetMemoryPersistence();
      final member = FleetService(persistence: memberStore);
      final rec = await member.createFleet('1234');
      final joinerStore = FleetMemoryPersistence();
      final joiner = FleetService(persistence: joinerStore);
      final key = await fleetDeriveKey(
          pin: '1234', salt: base64.decode(rec.saltB64));
      return (member, joiner, rec, key);
    }

    test('reply carries a verifiable proof; correct proof is accepted',
        () async {
      final (member, joiner, rec, key) = await joinedPair();
      final memberNodeId = await member.ensureNodeId();
      try {
        final heard = FleetHeard(
          fleetId: rec.fleetId,
          saltB64: rec.saltB64,
          memberCount: 1,
          lastSeen: DateTime.now(),
          address: '10.0.0.2',
        );
        final built = await joiner.buildJoinRequest(
            heard: heard, candidateKey: key);
        final (request, ephemeral) = built!;
        final reply =
            await member.answerJoinRequestAsync(request, '10.0.0.9');
        expect(reply, isNotNull);
        // The proof is present and is exactly the HMAC the joiner
        // will verify: HMAC(key, member_eph_pub || member_node_id
        // || fleet_id).
        final memberPub =
            base64.decode(reply!['eph_pub_b64'] as String);
        final expectedProof = fleetJoinProof(
          fleetKey: key,
          ephPub: memberPub,
          nodeId: memberNodeId,
          fleetId: rec.fleetId,
        );
        expect(base64.decode(reply['proof_b64'] as String),
            expectedProof);
        final ok = await joiner.completeJoinFromReply(
          reply: reply,
          ephemeral: ephemeral,
          candidateKey: key,
          heard: heard,
        );
        expect(ok, isTrue);
        expect(joiner.inFleet, isTrue);
        expect(joiner.sessionsForTest.length, 1);
      } finally {
        await member.stop();
        await joiner.stop();
      }
    });

    test('reply with a wrong-key proof is rejected; nothing stored',
        () async {
      final (member, joiner, rec, key) = await joinedPair();
      final memberNodeId = await member.ensureNodeId();
      try {
        final heard = FleetHeard(
          fleetId: rec.fleetId,
          saltB64: rec.saltB64,
          memberCount: 1,
          lastSeen: DateTime.now(),
          address: '10.0.0.2',
        );
        final built = await joiner.buildJoinRequest(
            heard: heard, candidateKey: key);
        final (request, ephemeral) = built!;
        final reply =
            await member.answerJoinRequestAsync(request, '10.0.0.9');
        expect(reply, isNotNull);
        // Forge: same reply, but the proof is computed under a
        // different key (as a fake member with no fleet key would
        // have to — it cannot produce the right HMAC).
        final wrongKey = await fleetDeriveKey(
            pin: '9999', salt: base64.decode(rec.saltB64));
        final memberPub =
            base64.decode(reply!['eph_pub_b64'] as String);
        final badProof = fleetJoinProof(
          fleetKey: wrongKey,
          ephPub: memberPub,
          nodeId: memberNodeId,
          fleetId: rec.fleetId,
        );
        final forged = Map<String, dynamic>.of(reply)
          ..['proof_b64'] = base64.encode(badProof);
        expect(
            await joiner.completeJoinFromReply(
              reply: forged,
              ephemeral: ephemeral,
              candidateKey: key,
              heard: heard,
            ),
            isFalse);
        expect(joiner.inFleet, isFalse);
        expect(joiner.sessionsForTest, isEmpty);
        // No fleet record or key was stored for the fake member.
        expect(joiner.record, isNull);
        // A reply with the proof missing entirely is rejected too.
        final noProof = Map<String, dynamic>.of(reply)
          ..remove('proof_b64');
        expect(
            await joiner.completeJoinFromReply(
              reply: noProof,
              ephemeral: ephemeral,
              candidateKey: key,
              heard: heard,
            ),
            isFalse);
        expect(joiner.inFleet, isFalse);
        expect(joiner.sessionsForTest, isEmpty);
        expect(joiner.record, isNull);
      } finally {
        await member.stop();
        await joiner.stop();
      }
    });
  });

  group('FleetService session rotation on rejoin (Fix 2)', () {
    test('prune drops the session; a returning beacon re-handshakes '
        'with a fresh key', () async {
      var now = DateTime.utc(2026, 11, 17, 12);
      final memberStore = FleetMemoryPersistence();
      final member = FleetService(persistence: memberStore);
      final rec = await member.createFleet('1234');
      final memberNodeId = await member.ensureNodeId();

      final joinerStore = FleetMemoryPersistence();
      final joiner =
          FleetService(persistence: joinerStore, now: () => now);
      final heard = FleetHeard(
        fleetId: rec.fleetId,
        saltB64: rec.saltB64,
        memberCount: 1,
        lastSeen: DateTime.now(),
        address: '10.0.0.2',
      );
      final key = await fleetDeriveKey(
          pin: '1234', salt: base64.decode(rec.saltB64));
      try {
        final built = await joiner.buildJoinRequest(
            heard: heard, candidateKey: key);
        final (request, ephemeral) = built!;
        final reply =
            await member.answerJoinRequestAsync(request, '10.0.0.9');
        expect(reply, isNotNull);
        expect(
            await joiner.completeJoinFromReply(
              reply: reply!,
              ephemeral: ephemeral,
              candidateKey: key,
              heard: heard,
            ),
            isTrue);
        final oldSession = joiner.sessionsForTest[memberNodeId]!;
        expect(oldSession.length, 32);

        FleetBeacon beaconAt(DateTime at) => FleetBeacon(
              fleetId: rec.fleetId,
              saltB64: rec.saltB64,
              nodeId: memberNodeId,
              callsign: 'OUTRIDE-${memberNodeId.substring(0, 6)}',
              appVersion: '0.28.0',
              hasSilvus: true,
              memberCount: 2,
              t: at.toUtc().millisecondsSinceEpoch ~/ 1000,
            );
        joiner.handleDatagramText(
            jsonEncode(beaconAt(now).toJson()), '10.0.0.2',
            now: now);
        expect(joiner.peers.length, 1);

        // 16 s of silence, then prune: peer AND session are gone.
        now = now.add(const Duration(seconds: 16));
        joiner.pruneForTest(now);
        expect(joiner.peers, isEmpty);
        expect(joiner.sessionsForTest.containsKey(memberNodeId),
            isFalse);

        // The member returns: its beacon must trigger a fresh
        // handshake (a pending join for that node id).
        joiner.handleDatagramText(
            jsonEncode(beaconAt(now).toJson()), '10.0.0.2',
            now: now);
        expect(joiner.peers.length, 1);
        var pending = false;
        for (var i = 0; i < 50 && !pending; i++) {
          await Future<void>.delayed(
              const Duration(milliseconds: 20));
          pending =
              joiner.pendingJoinNodeIdsForTest.contains(memberNodeId);
        }
        expect(pending, isTrue,
            reason: 'returning beacon did not trigger a fresh handshake');

        // Answer the fresh handshake the way the returning member
        // would: a new ephemeral + a proof under the fleet key.
        // (Fabricated here because the request went out on the
        // real socket; the joiner verifies it exactly as it would
        // a live reply.)
        final freshMemberEph = await fleetNewEphemeral();
        final freshProof = fleetJoinProof(
          fleetKey: key,
          ephPub: freshMemberEph.publicBytes,
          nodeId: memberNodeId,
          fleetId: rec.fleetId,
        );
        final freshReply = <String, dynamic>{
          'type': 'fleet_join_reply',
          'fleet_id': rec.fleetId,
          'node_id': memberNodeId,
          'eph_pub_b64': base64.encode(freshMemberEph.publicBytes),
          'proof_b64': base64.encode(freshProof),
        };
        joiner.handleDatagramText(
            jsonEncode(freshReply), '10.0.0.2',
            now: now);
        List<int>? newSession;
        for (var i = 0; i < 50 && newSession == null; i++) {
          await Future<void>.delayed(
              const Duration(milliseconds: 20));
          newSession = joiner.sessionsForTest[memberNodeId];
        }
        expect(newSession, isNotNull);
        expect(newSession, isNot(oldSession),
            reason: 'rejoin reused the old session key');
      } finally {
        await member.stop();
        await joiner.stop();
      }
    });
  });

  group('FleetService socket-death recovery (Fix 3)', () {
    test('socket death rebinds on the next beacon tick and resumes',
        () async {
      // Unjoined (listen-only) service: it binds the socket and
      // runs the beacon timer but sends no beacons, so the
      // rebound socket stays up in this sandbox — multicast
      // SENDS fail here with EPERM, which would kill an
      // in-fleet socket again on its first beacon (the direct
      // rebind test below covers the in-fleet path). On a real
      // device the same timer tick drives the in-fleet rebind.
      final service =
          FleetService(persistence: FleetMemoryPersistence());
      try {
        await service.start();
        expect(service.isRunning, isTrue);
        expect(service.inFleet, isFalse);
        service.simulateSocketDeathForTest();
        expect(service.isRunning, isFalse);
        expect(service.needsRebindForTest, isTrue);
        // The beacon timer (5 s tick) drives the rebind — no
        // screen reopen, no restart.
        var back = false;
        for (var i = 0; i < 40 && !back; i++) {
          await Future<void>.delayed(
              const Duration(milliseconds: 250));
          back = service.isRunning;
        }
        expect(back, isTrue,
            reason: 'service did not rebind after socket death');
        expect(service.needsRebindForTest, isFalse);
        // And it stays up across further ticks.
        await Future<void>.delayed(const Duration(seconds: 6));
        expect(service.isRunning, isTrue);
        expect(service.needsRebindForTest, isFalse);
      } finally {
        await service.stop();
      }
    });

    test('in-fleet socket death rebinds on a direct attempt', () async {
      final service =
          FleetService(persistence: FleetMemoryPersistence());
      try {
        await service.createFleet('1234');
        expect(service.isRunning, isTrue);
        service.simulateSocketDeathForTest();
        expect(service.isRunning, isFalse);
        expect(service.needsRebindForTest, isTrue);
        await service.tryRebindForTest();
        expect(service.isRunning, isTrue);
        expect(service.needsRebindForTest, isFalse);
      } finally {
        await service.stop();
      }
    });

    test('rebind backoff grows 5/10/20/40/60 s and caps', () {
      expect(FleetService.rebindBackoffSecForTest(0), 5);
      expect(FleetService.rebindBackoffSecForTest(1), 10);
      expect(FleetService.rebindBackoffSecForTest(2), 20);
      expect(FleetService.rebindBackoffSecForTest(3), 40);
      expect(FleetService.rebindBackoffSecForTest(4), 60);
      expect(FleetService.rebindBackoffSecForTest(9), 60);
    });

    test('stop() disarms a pending rebind', () async {
      final service =
          FleetService(persistence: FleetMemoryPersistence());
      await service.createFleet('1234');
      service.simulateSocketDeathForTest();
      expect(service.needsRebindForTest, isTrue);
      await service.stop();
      expect(service.needsRebindForTest, isFalse);
      expect(service.isRunning, isFalse);
    });
  });

  group('FleetService summary', () {    test('NOT IN A FLEET when unjoined; FLEET N · M SENSING when in',
        () async {
      final now = DateTime.utc(2026, 11, 17, 12);
      final store = FleetMemoryPersistence();
      final service = FleetService(
        persistence: store,
        hasSilvus: () => true,
        now: () => now,
      );
      expect(service.summary, 'NOT IN A FLEET');
      final rec = await service.createFleet('1234');
      expect(service.summary, 'FLEET 1 · 1 SENSING');
      final peer = FleetBeacon(
        fleetId: rec.fleetId,
        saltB64: rec.saltB64,
        nodeId: '1111111111111111',
        callsign: 'OUTRIDE-111111',
        appVersion: '0.28.0',
        hasSilvus: false,
        memberCount: 2,
        t: now.millisecondsSinceEpoch ~/ 1000,
      );
      service.handleDatagramText(jsonEncode(peer.toJson()), '10.0.0.2',
          now: now);
      expect(service.summary, 'FLEET 2 · 1 SENSING');
      await service.stop();
    });
  });
}

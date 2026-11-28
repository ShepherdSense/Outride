import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/meshtastic_mesh_config.dart';

List<int> _psk([int seed = 1]) =>
    List<int>.generate(32, (i) => (seed + i * 7) % 251 + 1);

void main() {
  group('MeshtasticMeshConfig.validate', () {
    test('accepts the locked config', () {
      final c = MeshtasticMeshConfig.locked(
        pskBytes: _psk(),
        adminPublicKeys: ['aabbcc', 'ddeeff'],
      );
      expect(c.isValid, isTrue);
      expect(c.validate(), isEmpty);
      expect(c.preset, MeshModemPreset.mediumFast);
      expect(c.hopLimit, 3);
      expect(c.useAead, isTrue);
      expect(c.signingPolicy, MeshSigningPolicy.balanced);
      expect(c.ignoreMqtt, isTrue);
      expect(c.downlinkEnabled, isFalse);
      expect(c.authenticated, isTrue);
    });

    test('rejects the published default key AQ==', () {
      expect(
        () => MeshtasticMeshConfig.fromBase64Psk(pskBase64: 'AQ=='),
        throwsArgumentError,
      );
      // 1-byte form via constructor.
      final one = MeshtasticMeshConfig(pskBytes: [0x01]);
      expect(one.validate().join(' '), contains('default key'));
      // 16-byte expanded form.
      final sixteen = MeshtasticMeshConfig(
          pskBytes: List<int>.from(
              MeshtasticMeshConfig.defaultKeyBytes));
      expect(sixteen.validate().join(' '), contains('default key'));
    });

    test('rejects a short PSK', () {
      final c = MeshtasticMeshConfig(pskBytes: List<int>.filled(16, 0x42));
      final errors = c.validate();
      expect(errors.join(' '), contains('exactly 32 bytes'));
      expect(c.isValid, isFalse);
    });

    test('rejects an all-zero 32-byte PSK', () {
      final c = MeshtasticMeshConfig(pskBytes: List<int>.filled(32, 0));
      expect(c.validate().join(' '), contains('all zeros'));
    });

    test('authenticated requires a usable PSK (re-review item 8)', () {
      // A directly-constructed config with the default / zero /
      // short PSK and useAead: true used to report authenticated
      // == true; only validate() / locked() / fromBase64Psk caught
      // the bad key. Fusion trusts this flag, so the getter folds
      // the PSK check in.
      final oneByte = MeshtasticMeshConfig(pskBytes: [0x01]);
      expect(oneByte.authenticated, isFalse);
      final short = MeshtasticMeshConfig(
          pskBytes: List<int>.filled(16, 0x42));
      expect(short.authenticated, isFalse);
      final zeros = MeshtasticMeshConfig(
          pskBytes: List<int>.filled(32, 0));
      expect(zeros.authenticated, isFalse);
      // STRICT does not rescue a bad PSK either.
      final strictBad = MeshtasticMeshConfig(
        pskBytes: List<int>.filled(32, 0),
        useAead: false,
        signingPolicy: MeshSigningPolicy.strict,
      );
      expect(strictBad.authenticated, isFalse);
      // And a valid 32-byte PSK still authenticates (AEAD on).
      final good = MeshtasticMeshConfig(pskBytes: _psk());
      expect(good.authenticated, isTrue);
    });

    test('rejects hop limit above the wire ceiling', () {
      final c = MeshtasticMeshConfig(pskBytes: _psk(), hopLimit: 8);
      expect(c.validate().join(' '), contains('hop limit'));
      final zero = MeshtasticMeshConfig(pskBytes: _psk(), hopLimit: 0);
      expect(zero.validate().join(' '), contains('hop limit'));
    });

    test('rejects more than 3 admin keys', () {
      final c = MeshtasticMeshConfig(
        pskBytes: _psk(),
        adminPublicKeys: ['k1', 'k2', 'k3', 'k4'],
      );
      expect(c.validate().join(' '), contains('at most 3 admin'));
    });

    test('rejects ignore_mqtt=false on infrastructure nodes', () {
      final c = MeshtasticMeshConfig(pskBytes: _psk(), ignoreMqtt: false);
      expect(c.validate().join(' '), contains('ignore_mqtt'));
    });

    test('rejects AEAD off (locked config requires it)', () {
      final c = MeshtasticMeshConfig(pskBytes: _psk(), useAead: false);
      expect(c.validate().join(' '), contains('AEAD'));
      // AEAD off + BALANCED: unsigned broadcasts from nodes not
      // known to sign are still accepted — not authenticated.
      expect(c.authenticated, isFalse);
    });

    test('AEAD on authenticates regardless of signing policy', () {
      // channel.proto: AEAD "overrides packet_signature_policy:
      // its packets are never XEdDSA signed, and are not dropped
      // for lacking a signature, because the tag authenticates
      // them." AEAD-on + ACCEPT_UNSIGNED is authenticated.
      final c = MeshtasticMeshConfig(
        pskBytes: _psk(),
        signingPolicy: MeshSigningPolicy.acceptUnsigned,
      );
      expect(c.authenticated, isTrue);
      // But the config itself is still deployable (policy choice,
      // not a validation error) — it just yields untrusted samples
      // when AEAD is off.
      expect(c.isValid, isTrue);
    });

    test('without AEAD only STRICT fully authenticates', () {
      final balanced = MeshtasticMeshConfig(
        pskBytes: _psk(),
        useAead: false,
        signingPolicy: MeshSigningPolicy.balanced,
      );
      expect(balanced.authenticated, isFalse);
      final strict = MeshtasticMeshConfig(
        pskBytes: _psk(),
        useAead: false,
        signingPolicy: MeshSigningPolicy.strict,
      );
      expect(strict.authenticated, isTrue);
    });

    test('STRICT policy is authenticated', () {
      final c = MeshtasticMeshConfig(
        pskBytes: _psk(),
        signingPolicy: MeshSigningPolicy.strict,
      );
      expect(c.authenticated, isTrue);
      expect(c.isValid, isTrue);
    });

    test('rejects downlink + ignore_mqtt off even off infrastructure',
        () {
      // The MQTT loop shape: downlink on + ignore_mqtt off passes
      // validate() only when isInfrastructure is false — that was
      // the loop hole. Now rejected regardless.
      final c = MeshtasticMeshConfig(
        pskBytes: _psk(),
        isInfrastructure: false,
        downlinkEnabled: true,
        ignoreMqtt: false,
      );
      expect(c.validate().join(' '), contains('ignore_mqtt'));
      final ok = MeshtasticMeshConfig(
        pskBytes: _psk(),
        isInfrastructure: false,
        downlinkEnabled: true,
        ignoreMqtt: true,
      );
      expect(ok.isValid, isTrue);
    });

    test('role is wired into the config model', () {
      final c = MeshtasticMeshConfig(pskBytes: _psk());
      expect(c.role, MeshDeviceRole.client);
      final router = MeshtasticMeshConfig.locked(
        pskBytes: _psk(),
        role: MeshDeviceRole.router,
      );
      expect(router.role, MeshDeviceRole.router);
      expect(router.isValid, isTrue);
    });

    test('fromBase64Psk fails loudly on an invalid PSK', () {
      // A short PSK used to return an unvalidated config; only
      // locked() failed loudly. Now this throws too.
      expect(
        () => MeshtasticMeshConfig.fromBase64Psk(
            pskBase64: base64.encode(List<int>.filled(16, 0x42))),
        throwsArgumentError,
      );
    });

    test('locked() factory throws on a bad PSK', () {
      expect(
        () => MeshtasticMeshConfig.locked(pskBytes: [1, 2, 3]),
        throwsArgumentError,
      );
    });

    test('base64 round-trip accepts a real 32-byte PSK', () {
      final bytes = _psk(5);
      final b64 = base64.encode(bytes);
      final c = MeshtasticMeshConfig.fromBase64Psk(pskBase64: b64);
      expect(c.isValid, isTrue);
      expect(c.pskBytes, bytes);
    });
  });
}

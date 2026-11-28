/// Validated Meshtastic mesh hygiene config (improvements #4 + #5).
///
/// The locked deployment config lives in prose in
/// `docs/meshtastic_hygiene_config.md`; this model makes it
/// enforceable in code: [MeshtasticMeshConfig.validate] rejects the
/// configs that must never ship (default key, short PSK, hop limit
/// above the wire ceiling, too many admin keys, MQTT loop risk).
///
/// SECURITY NOTES:
/// - The PSK is held here as bytes, never logged, never written to
///   prefs. The published default key `AQ==` (1-byte shorthand for
///   the 16-byte default key) is rejected explicitly as well as by
///   the 32-byte length rule.
/// - Unauthenticated mesh data is UNTRUSTED fusion input: it may
///   corroborate or upgrade, never veto — and Meshtastic samples
///   never veto a Silvus tripwire (standing fusion rule). See
///   [authenticated]: true when the channel is AEAD (the AES-CCM
///   tag authenticates every packet) OR the signing policy is
///   STRICT (all unsigned broadcasts rejected).
/// - Longer-term upstream items (extend the `ack_proof` HMAC toward
///   authenticated sensing payloads; register the sensing portnum in
///   the 64-127 range) are doc-only, in the hygiene doc — not code.
library;

import 'dart:convert';

/// Packet-signature policy (firmware 2.8+, `packet_signature_policy`).
enum MeshSigningPolicy {
  /// Accept unsigned broadcasts (firmware default).
  acceptUnsigned,

  /// Reject unsigned broadcasts from nodes known to sign.
  balanced,

  /// Reject all unsigned broadcasts.
  strict,
}

/// Modem preset for the deployment. MediumFast is the locked default
/// for dense deployments; LongFast only for sparse / long-range legs.
enum MeshModemPreset {
  longFast,
  mediumFast,
  mediumSlow,
  shortFast,
}

/// Device role for a node in the deployment.
enum MeshDeviceRole {
  client,
  clientMute,
  clientHidden,
  clientBase,
  router,
  routerLate,
  tracker,
  sensor,
}

/// The locked, validated deployment configuration for one Outride
/// Meshtastic deployment.
///
/// Defaults ARE the locked config, except the PSK and admin keys,
/// which must be supplied by the operator (there is no safe default:
/// the published default key is forbidden).
class MeshtasticMeshConfig {
  MeshtasticMeshConfig({
    this.preset = MeshModemPreset.mediumFast,
    this.hopLimit = 3,
    required this.pskBytes,
    this.useAead = true,
    this.signingPolicy = MeshSigningPolicy.balanced,
    this.role = MeshDeviceRole.client,
    this.adminPublicKeys = const [],
    this.ignoreMqtt = true,
    this.downlinkEnabled = false,
    this.isInfrastructure = true,
    this.nodeInfoIntervalSecs = 10800,
    this.telemetryEnabled = true,
    this.telemetryIntervalSecs = 1800,
  });

  /// Locked-config factory: the operator supplies only the secrets
  /// (32-byte PSK) and the admin allowlist; everything else is the
  /// locked value. Throws [ArgumentError] when the supplied secrets
  /// fail validation, so a bad locked config cannot be constructed
  /// silently.
  factory MeshtasticMeshConfig.locked({
    required List<int> pskBytes,
    List<String> adminPublicKeys = const [],
    MeshModemPreset preset = MeshModemPreset.mediumFast,
    MeshDeviceRole role = MeshDeviceRole.client,
  }) {
    final c = MeshtasticMeshConfig(
      preset: preset,
      pskBytes: pskBytes,
      adminPublicKeys: adminPublicKeys,
      role: role,
    );
    final errors = c.validate();
    if (errors.isNotEmpty) {
      throw ArgumentError(
          'locked Meshtastic config invalid: ${errors.join('; ')}');
    }
    return c;
  }

  /// Modem preset. Locked: MediumFast (dense) / LongFast (sparse).
  final MeshModemPreset preset;

  /// Hop limit. Locked: 3. Wire ceiling is 7 — never a target.
  final int hopLimit;

  /// Channel pre-shared key, raw bytes. Must be exactly 32 bytes
  /// (AES-256). Never the published default key.
  final List<int> pskBytes;

  /// AEAD (`use_aead`, firmware 2.8.1+): AES-CCM with integrity.
  /// Locked: true. Without it, AES-CTR has no integrity and a
  /// tampered packet decrypts to garbage that looks like data.
  final bool useAead;

  /// Signed-broadcast policy (firmware 2.8+). Locked: BALANCED.
  final MeshSigningPolicy signingPolicy;

  /// Device role for this node (ROUTER only on powered, elevated,
  /// fixed nodes; CLIENT elsewhere; CLIENT_MUTE on battery sensing
  /// nodes — hygiene doc §3). Wires the [MeshDeviceRole] enum into
  /// the config model (FIX, review small item: it was defined but
  /// used nowhere).
  final MeshDeviceRole role;

  /// Admin public keys allowed for remote admin. Firmware cap: 3.
  final List<String> adminPublicKeys;

  /// `lora.ignore_mqtt` — must be true on all infrastructure nodes,
  /// or a gateway that uplinks LoRa→MQTT and downlinks MQTT→LoRa
  /// can loop indefinitely. Locked: true.
  final bool ignoreMqtt;

  /// MQTT downlink (broker → mesh). Locked: off unless a use case
  /// needs it.
  final bool downlinkEnabled;

  /// True for infrastructure / gateway nodes, where [ignoreMqtt]
  /// is mandatory. Battery sensing nodes are not infrastructure,
  /// but keeping it true is still the safe default.
  final bool isInfrastructure;

  /// NodeInfo broadcast interval, seconds. Locked: 3 h (10800 s).
  final int nodeInfoIntervalSecs;

  /// Whether device telemetry is broadcast on this deployment.
  final bool telemetryEnabled;

  /// Device telemetry mesh interval, seconds. Locked: 30 min.
  /// (Firmware defaults drift by version; cite the version when
  /// quoting an interval — see the hygiene doc.)
  final int telemetryIntervalSecs;

  /// The published default key, base64 `AQ==`: a 1-byte PSK whose
  /// single byte is 0x01. Anyone can read a channel on this key.
  static const String defaultKeyBase64 = 'AQ==';

  /// The 16-byte key the 1-byte default shorthand expands to
  /// (channel.proto): d4 f1 bb 3a 20 29 07 59 f0 bc ff ab cf 4e 69 01.
  /// Rejected even if presented as 16 bytes.
  static const List<int> defaultKeyBytes = [
    0xd4, 0xf1, 0xbb, 0x3a, 0x20, 0x29, 0x07, 0x59,
    0xf0, 0xbc, 0xff, 0xab, 0xcf, 0x4e, 0x69, 0x01,
  ];

  /// True when this channel's traffic counts as authenticated.
  ///
  /// FIX (review 2026-11-28, item 1): the old getter was
  /// `useAead && signingPolicy != acceptUnsigned`, which is wrong
  /// both ways. channel.proto (`use_aead`) states AEAD "overrides
  /// packet_signature_policy: its packets are never XEdDSA signed,
  /// and are not dropped for lacking a signature, because the tag
  /// authenticates them" — so AEAD-on authenticates every packet
  /// regardless of signing policy, and AEAD-off + BALANCED still
  /// accepts unsigned broadcasts from nodes not known to sign.
  /// Correct: AEAD alone authenticates; without AEAD only STRICT
  /// (all unsigned broadcasts rejected) fully authenticates.
  ///
  /// FIX (re-review item 8): the flag also requires a usable PSK.
  /// A directly-constructed config with the default / zero / short
  /// PSK and `useAead: true` used to report `authenticated ==
  /// true`, while only [validate] / [locked] / [fromBase64Psk]
  /// caught the bad key. Fusion trusts this flag, so the getter
  /// folds the PSK check in: the PSK must be exactly 32 bytes
  /// and not all zeros (the same bar [validate] sets for a
  /// deployable key — the 1-byte and 16-byte default-key forms
  /// fail the length check too).
  bool get authenticated =>
      _pskUsable &&
      (useAead || signingPolicy == MeshSigningPolicy.strict);

  /// True when [pskBytes] is a usable channel key: exactly 32
  /// bytes (AES-256) and not all zeros.
  bool get _pskUsable =>
      pskBytes.length == 32 && pskBytes.any((b) => b != 0);

  /// Validate the locked config. Returns the list of violations;
  /// empty means the config is acceptable to deploy.
  List<String> validate() {
    final errors = <String>[];
    if (pskBytes.length != 32) {
      errors.add('PSK must be exactly 32 bytes (AES-256); '
          'got ${pskBytes.length}');
    }
    if (pskBytes.length == 1 && pskBytes.first == 0x01) {
      errors.add('PSK is the published default key (AQ==); '
          'never deploy on the default key');
    }
    if (pskBytes.length == 16 &&
        _bytesEqual(pskBytes, defaultKeyBytes)) {
      errors.add('PSK is the published default key (16-byte form); '
          'never deploy on the default key');
    }
    if (pskBytes.length == 32 && pskBytes.every((b) => b == 0)) {
      errors.add('PSK must not be all zeros');
    }
    if (hopLimit < 1 || hopLimit > 7) {
      errors.add('hop limit must be 1-7 (wire ceiling 7); got $hopLimit');
    }
    if (adminPublicKeys.length > 3) {
      errors.add('at most 3 admin public keys are allowed; '
          'got ${adminPublicKeys.length}');
    }
    if (adminPublicKeys.any((k) => k.trim().isEmpty)) {
      errors.add('admin public keys must not be empty strings');
    }
    if (isInfrastructure && !ignoreMqtt) {
      errors.add('lora.ignore_mqtt must be true on infrastructure '
          'nodes (MQTT loop risk)');
    }
    // FIX (review item 13): the loop hole was open for
    // non-infrastructure nodes — a config with downlink on +
    // ignore_mqtt off passed validate() despite being exactly the
    // documented loop shape (gateway uplinks LoRa→MQTT and
    // downlinks MQTT→LoRa). Downlink on requires ignore_mqtt on,
    // regardless of isInfrastructure.
    if (downlinkEnabled && !ignoreMqtt) {
      errors.add('MQTT downlink requires lora.ignore_mqtt=true '
          '(MQTT loop risk) — set ignore_mqtt or turn downlink off');
    }
    if (!useAead) {
      errors.add('AEAD (use_aead) is required by the locked config '
          '(firmware 2.8.1+); AES-CTR without integrity is not trusted');
    }
    if (nodeInfoIntervalSecs < 0) {
      errors.add('NodeInfo interval must not be negative');
    }
    if (telemetryEnabled && telemetryIntervalSecs <= 0) {
      errors.add('telemetry interval must be positive when telemetry '
          'is enabled');
    }
    return errors;
  }

  bool get isValid => validate().isEmpty;

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Convenience: build from a base64 PSK string. Throws
  /// [FormatException] on invalid base64 and [ArgumentError] when
  /// the decoded bytes fail validation (FIX, review small item:
  /// it used to return an unvalidated config and leave the caller
  /// to check `isValid`; only `locked()` failed loudly).
  factory MeshtasticMeshConfig.fromBase64Psk({
    required String pskBase64,
    List<String> adminPublicKeys = const [],
    MeshModemPreset preset = MeshModemPreset.mediumFast,
    MeshDeviceRole role = MeshDeviceRole.client,
    int hopLimit = 3,
    bool useAead = true,
    MeshSigningPolicy signingPolicy = MeshSigningPolicy.balanced,
    bool ignoreMqtt = true,
    bool downlinkEnabled = false,
    bool isInfrastructure = true,
  }) {
    if (pskBase64.trim() == defaultKeyBase64) {
      // Fail fast with the specific reason, not just a length error.
      throw ArgumentError(
          'PSK is the published default key (AQ==); never deploy '
          'on the default key');
    }
    final config = MeshtasticMeshConfig(
      preset: preset,
      hopLimit: hopLimit,
      pskBytes: base64.decode(pskBase64.trim()),
      useAead: useAead,
      signingPolicy: signingPolicy,
      role: role,
      adminPublicKeys: adminPublicKeys,
      ignoreMqtt: ignoreMqtt,
      downlinkEnabled: downlinkEnabled,
      isInfrastructure: isInfrastructure,
    );
    final errors = config.validate();
    if (errors.isNotEmpty) {
      throw ArgumentError(
          'base64 PSK config invalid: ${errors.join('; ')}');
    }
    return config;
  }
}

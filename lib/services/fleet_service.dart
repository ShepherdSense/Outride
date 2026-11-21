/// Fleet service — Outride v0.28.0 automatic EUD-to-EUD meshing.
///
/// Beaconing, listening, admission, session keys, and the peer
/// table for one Outride fleet. See docs/auto_mesh_fleet_spec.md
/// (§3 discovery, §4 lifecycle, §5 crypto, §6 peer data, §8
/// lifecycle/permissions).
///
/// Shape follows CotListener: serialized start/stop, a socket-free
/// datagram path ([handleDatagramText] / [answerJoinRequest]) that
/// unit tests drive directly, never-throws ingest, and a
/// MulticastLock held only while listening.
///
/// No single point of failure: every member beacons the fleet and
/// ANY member holding the fleet key can admit a late joiner — the
/// lead is only special at creation time.
///
/// Defensive-only: the only bytes this service sends are fleet
/// beacons, admission messages, and our own sensor observations to
/// admitted peers (encrypted). Peer observations are
/// corroboration-only — they land in the shared sensor-observation
/// store exactly like local sensor-bus observations, never in the
/// tripwire, never creating a track alone, never vetoing one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/sensor_observation.dart';
import 'fleet_crypto.dart';
import 'fleet_foreground.dart';
import 'multicast_lock.dart';
import 'node_udp_hub.dart';
import 'sensor_protocol.dart';

/// Join rate limiting (spec §5): 5 failed joins per source IP per
/// 60 s, then exponential lockout 30/60/120/300 s (capped); a global
/// cap of 10 failures per minute across all sources triggers a 60 s
/// fleet-wide join freeze. Pure state + injectable clock, so tests
/// drive it with fake time. A success resets the per-IP counter.
class FleetJoinRateLimiter {
  FleetJoinRateLimiter({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const int maxFailuresPerIp = 5;
  static const int failureWindowSec = 60;
  static const int maxGlobalFailuresPerMin = 10;
  static const int freezeSec = 60;

  /// Lockout durations in seconds, by lockout count (capped at last).
  static const List<int> backoffSec = [30, 60, 120, 300];

  final DateTime Function() _now;

  final Map<String, List<DateTime>> _failuresByIp = {};
  final Map<String, DateTime> _lockedUntilByIp = {};
  final Map<String, int> _lockoutCountByIp = {};
  final List<DateTime> _globalFailures = [];
  DateTime? _frozenUntil;

  /// True when [ip] may attempt a join right now: not locked out
  /// and no fleet-wide freeze in force.
  bool allowAttempt(String ip) {
    final now = _now();
    final lockedUntil = _lockedUntilByIp[ip];
    if (lockedUntil != null && now.isBefore(lockedUntil)) return false;
    final frozenUntil = _frozenUntil;
    if (frozenUntil != null && now.isBefore(frozenUntil)) return false;
    return true;
  }

  /// Record a failed join attempt from [ip]. On the 5th failure in
  /// the window the IP locks out with the next backoff step; 10
  /// failures fleet-wide in a minute freezes all joins for 60 s.
  void recordFailure(String ip) {
    final now = _now();
    final windowStart = now.subtract(const Duration(seconds: failureWindowSec));
    final mine = _failuresByIp.putIfAbsent(ip, () => <DateTime>[]);
    mine.removeWhere((t) => t.isBefore(windowStart));
    mine.add(now);
    _globalFailures.removeWhere((t) => t.isBefore(windowStart));
    _globalFailures.add(now);
    if (_globalFailures.length >= maxGlobalFailuresPerMin) {
      _frozenUntil = now.add(const Duration(seconds: freezeSec));
    }
    if (mine.length >= maxFailuresPerIp) {
      final count = _lockoutCountByIp[ip] ?? 0;
      final backoff =
          backoffSec[count < backoffSec.length ? count : backoffSec.length - 1];
      _lockedUntilByIp[ip] = now.add(Duration(seconds: backoff));
      _lockoutCountByIp[ip] = count + 1;
      mine.clear();
    }
  }

  /// Record a successful join from [ip]: resets its failure counter
  /// and lockout progression.
  void recordSuccess(String ip) {
    _failuresByIp.remove(ip);
    _lockedUntilByIp.remove(ip);
    _lockoutCountByIp.remove(ip);
  }

  /// Seconds until [ip]'s lockout ends (0 when not locked out).
  /// Test/observability helper — never shown in the UI.
  int lockoutRemainingSec(String ip) {
    final until = _lockedUntilByIp[ip];
    if (until == null) return 0;
    final left = until.difference(_now()).inSeconds;
    return left > 0 ? left : 0;
  }

  /// True while a fleet-wide join freeze is in force.
  bool get isFrozen {
    final until = _frozenUntil;
    return until != null && _now().isBefore(until);
  }
}

/// One stored fleet membership (spec §4). Lives in
/// SharedPreferences — metadata only. The derived key lives
/// separately in secure storage; the raw PIN is never stored
/// anywhere.
class FleetRecord {
  const FleetRecord({
    required this.fleetId,
    required this.saltB64,
    required this.kdf,
    required this.nodeId,
    required this.joinedAt,
  });

  /// 32 lowercase hex chars.
  final String fleetId;

  /// Base64 of the 16-byte fleet salt (public value).
  final String saltB64;

  /// KDF that derived the stored key (`argon2id` or the PBKDF2
  /// fallback name) so a future version never mis-derives.
  final String kdf;

  /// This device's stable node id (16 hex chars).
  final String nodeId;

  final DateTime joinedAt;

  List<int> get saltBytes => base64.decode(saltB64);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'fleet_id': fleetId,
        'salt_b64': saltB64,
        'kdf': kdf,
        'node_id': nodeId,
        'joined_at': joinedAt.toIso8601String(),
      };

  static FleetRecord? tryParse(Map<String, dynamic> j) {
    try {
      final fleetId = '${j['fleet_id'] ?? ''}';
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(fleetId)) return null;
      final saltB64 = '${j['salt_b64'] ?? ''}';
      if (base64.decode(saltB64).length != 16) return null;
      final nodeId = '${j['node_id'] ?? ''}';
      if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(nodeId)) return null;
      final joinedAt = DateTime.tryParse('${j['joined_at'] ?? ''}');
      if (joinedAt == null) return null;
      return FleetRecord(
        fleetId: fleetId,
        saltB64: saltB64,
        kdf: '${j['kdf'] ?? fleetKdfArgon2id}',
        nodeId: nodeId,
        joinedAt: joinedAt,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Fleet persistence split (spec §4, ZMeta pattern): metadata in
/// SharedPreferences, the derived key in secure storage. The
/// interface exists so tests use an in-memory store and the real
/// stores are never touched by a test — and so the raw PIN can never
/// reach either store (neither method takes a PIN).
abstract class FleetPersistence {
  Future<FleetRecord?> loadRecord();
  Future<void> saveRecord(FleetRecord record);
  Future<void> deleteRecord();
  Future<List<int>?> loadKey();
  Future<void> saveKey(List<int> keyBytes);
  Future<void> deleteKey();
  Future<String?> loadNodeId();
  Future<void> saveNodeId(String nodeId);
}

/// Real persistence: SharedPreferences + flutter_secure_storage.
///
/// Every call is best-effort and never throws: a missing plugin or
/// a failed read degrades to "no record / no key" (or a dropped
/// write). NOTE: deliberately NO timeout here — a `.timeout()` arms
/// a fake timer in widget tests, and AppState's constructor now
/// triggers fleet init, so an unmocked-prefs test would fail at
/// teardown with "a Timer is still pending". Tests that exercise
/// fleet persistence mock the stores (see fleet_screen_test.dart).
class FleetSharedPrefsPersistence implements FleetPersistence {
  static const String recordKey = 'outride_fleet_v1';
  static const String nodeIdKey = 'outride_fleet_node_id';
  static const String secureKeyName = 'fleet_key_b64';

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(),
  );

  @override
  Future<FleetRecord?> loadRecord() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(recordKey);
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return FleetRecord.tryParse(decoded);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveRecord(FleetRecord record) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(recordKey, jsonEncode(record.toJson()));
    } catch (_) {}
  }

  @override
  Future<void> deleteRecord() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(recordKey);
    } catch (_) {}
  }

  @override
  Future<List<int>?> loadKey() async {
    try {
      final b64 = await _secure.read(key: secureKeyName);
      if (b64 == null || b64.isEmpty) return null;
      final bytes = base64.decode(b64);
      return bytes.length == 32 ? bytes : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveKey(List<int> keyBytes) async {
    try {
      await _secure.write(
          key: secureKeyName, value: base64.encode(keyBytes));
    } catch (_) {}
  }

  @override
  Future<void> deleteKey() async {
    try {
      await _secure.delete(key: secureKeyName);
    } catch (_) {}
  }

  @override
  Future<String?> loadNodeId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(nodeIdKey);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveNodeId(String nodeId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(nodeIdKey, nodeId);
    } catch (_) {}
  }
}

/// In-memory persistence for tests. Never touches a plugin.
class FleetMemoryPersistence implements FleetPersistence {
  FleetRecord? record;
  List<int>? key;
  String? nodeId;

  /// Every string ever written to either store (record JSON + key
  /// base64): the persistence test asserts the raw PIN appears in
  /// none of them.
  List<String> get writtenStrings => [
        if (record != null) jsonEncode(record!.toJson()),
        if (key != null) base64.encode(key!),
        if (nodeId != null) nodeId!,
      ];

  @override
  Future<FleetRecord?> loadRecord() async => record;

  @override
  Future<void> saveRecord(FleetRecord r) async {
    record = r;
  }

  @override
  Future<void> deleteRecord() async {
    record = null;
  }

  @override
  Future<List<int>?> loadKey() async => key;

  @override
  Future<void> saveKey(List<int> k) async {
    key = List<int>.of(k);
  }

  @override
  Future<void> deleteKey() async {
    key = null;
  }

  @override
  Future<String?> loadNodeId() async => nodeId;

  @override
  Future<void> saveNodeId(String id) async {
    nodeId = id;
  }
}

/// One joined fleet member (this device + peers), from live beacons.
class FleetPeer {
  const FleetPeer({
    required this.nodeId,
    required this.callsign,
    required this.fleetId,
    required this.hasSilvus,
    required this.memberCount,
    required this.lastSeen,
    required this.address,
  });

  final String nodeId;
  final String callsign;
  final String fleetId;
  final bool hasSilvus;
  final int memberCount;
  final DateTime lastSeen;
  final String address;

  /// Role label follows the live `has_silvus` beacon field.
  String get roleLabel => fleetRoleLabel(hasSilvus);

  /// LIVE ≤ 10 s, STALE 10–15 s, GONE > 15 s (then pruned).
  String linkStateAt(DateTime now) {
    final age = now.difference(lastSeen).inSeconds;
    if (age <= 10) return 'LIVE';
    if (age <= fleetPeerTimeoutSec) return 'STALE';
    return 'GONE';
  }

  int lastSeenSecondsAgo(DateTime now) =>
      now.difference(lastSeen).inSeconds.clamp(0, 1 << 30);
}

/// A fleet heard on the segment that this device has NOT joined.
class FleetHeard {
  const FleetHeard({
    required this.fleetId,
    required this.saltB64,
    required this.memberCount,
    required this.lastSeen,
    required this.address,
  });

  final String fleetId;
  final String saltB64;
  final int memberCount;
  final DateTime lastSeen;
  final String address;

  /// Short id shown on the Fleet screen ("Fleet a1b2c3").
  String get shortId =>
      fleetId.length >= 6 ? fleetId.substring(0, 6) : fleetId;
}

/// Pending outbound join: the joiner's ephemeral keypair and the
/// candidate fleet key, held until the member's reply (or timeout).
class _PendingJoin {
  _PendingJoin({
    required this.ephemeral,
    required this.candidateKey,
    required this.heard,
    required this.completer,
  });

  final FleetEphemeral ephemeral;
  final List<int> candidateKey;
  final FleetHeard heard;
  final Completer<Map<String, dynamic>?> completer;
}

/// The fleet service: beaconing, listening, admission, session keys,
/// peer table, and encrypted peer-data ingest (spec §3–§6, §8).
class FleetService {
  FleetService({
    FleetPersistence? persistence,
    bool Function()? hasSilvus,
    String Function()? callsignPrefix,
    void Function(SensorObservation)? onPeerObservation,
    void Function()? onChanged,
    DateTime Function()? now,
    FleetJoinRateLimiter? rateLimiter,
  })  : _persistence = persistence ?? FleetSharedPrefsPersistence(),
        _hasSilvus = hasSilvus ?? (() => false),
        _callsignPrefix = callsignPrefix ?? (() => 'OUTRIDE-'),
        _onPeerObservation = onPeerObservation,
        _onChanged = onChanged,
        _now = now ?? DateTime.now,
        _rateLimiter = rateLimiter ?? FleetJoinRateLimiter();

  final FleetPersistence _persistence;
  final bool Function() _hasSilvus;
  final String Function() _callsignPrefix;
  final void Function(SensorObservation)? _onPeerObservation;
  final void Function()? _onChanged;
  final DateTime Function() _now;
  final FleetJoinRateLimiter _rateLimiter;

  FleetRecord? _record;
  List<int>? _fleetKey;
  String? _nodeId;
  bool _loaded = false;

  RawDatagramSocket? _socket;
  RawDatagramSocket? _sendSocket;
  Timer? _beaconTimer;
  bool _hubListening = false;
  bool _foregroundStarted = false;
  String? _lastError;
  DateTime? _listenStartedAt;
  DateTime? _lastBeaconHeardAt;

  /// Fix 3 (reviewer finding 3, spec §8 gap): socket-death
  /// recovery. When the socket dies, [_needsRebind] arms and the
  /// beacon timer — which keeps firing — attempts a rebind on its
  /// ticks with exponential backoff (5/10/20/40/60 s, capped), so
  /// the fleet resumes without reopening the screen or restarting
  /// the app. At most one attempt per backoff window, so a dead
  /// interface can never spin a hot rebind loop.
  bool _needsRebind = false;
  int _rebindAttempts = 0;
  DateTime? _lastRebindAttemptAt;
  bool _rebindInFlight = false;

  /// Peers keyed by node_id (upsert on repeat beacon).
  final Map<String, FleetPeer> _peers = {};

  /// Fleets heard but not joined, keyed by fleet_id.
  final Map<String, FleetHeard> _heard = {};

  /// Per-pair session keys, keyed by peer node_id.
  final Map<String, List<int>> _sessions = {};

  /// Our ephemeral keypair per peer we are joining with (reply
  /// pending) — kept so the session key can be derived on reply.
  final Map<String, _PendingJoin> _pendingJoins = {};

  /// Seen (nonce, sender) pairs for fleet_data replay rejection.
  final Set<String> _seenNonces = {};

  String? get lastError => _lastError;
  bool get isRunning => _socket != null;
  bool get inFleet => _record != null;
  FleetRecord? get record => _record;
  FleetJoinRateLimiter get rateLimiterForTest => _rateLimiter;

  /// Sessions held, keyed by peer node_id (test hook).
  Map<String, List<int>> get sessionsForTest => Map.of(_sessions);

  /// This device's stable node id. Generated once at first Fleet
  /// use and stored in SharedPreferences.
  Future<String> ensureNodeId() async {
    final existing = _nodeId;
    if (existing != null) return existing;
    var stored = await _persistence.loadNodeId();
    if (stored == null || !RegExp(r'^[0-9a-f]{16}$').hasMatch(stored)) {
      stored = fleetRandomNodeId();
      await _persistence.saveNodeId(stored);
    }
    _nodeId = stored;
    return stored;
  }

  String get callsign {
    final id = _nodeId ?? '0000000000000000';
    return fleetCallsign(_callsignPrefix(), id);
  }

  /// This device's role right now (live Silvus = SENSING).
  String get ownRoleLabel => fleetRoleLabel(_hasSilvus());

  /// Joined members (this device excluded), freshest first.
  /// Prunes peers silent > 15 s.
  List<FleetPeer> get peers {
    _prunePeers(_now());
    final out = _peers.values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return List.unmodifiable(out);
  }

  /// Fleets heard but not joined, freshest first. The remembered
  /// fleet never appears here (it is joined, not heard).
  List<FleetHeard> get heardFleets {
    final now = _now();
    _heard.removeWhere(
        (_, h) => now.difference(h.lastSeen).inSeconds > fleetPeerTimeoutSec);
    final out = _heard.values
        .where((h) => h.fleetId != _record?.fleetId)
        .toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return List.unmodifiable(out);
  }

  /// Dashboard chip text: `FLEET 3 · 2 SENSING` or `NOT IN A FLEET`.
  String get summary {
    if (!inFleet) return 'NOT IN A FLEET';
    final sensing = peers.where((p) => p.hasSilvus).length +
        (_hasSilvus() ? 1 : 0);
    return 'FLEET ${peers.length + 1} · $sensing SENSING';
  }

  /// True when listening for 15+ s with zero beacons heard — the
  /// screen's "No fleet heard — this network may block device
  /// discovery (AP isolation)" hint.
  bool get heardNothing {
    final started = _listenStartedAt;
    if (started == null || _lastBeaconHeardAt != null) return false;
    return _now().difference(started).inSeconds >= fleetPeerTimeoutSec;
  }

  /// Load the stored record + key + node id. Idempotent; never
  /// throws. A record without its key is unusable (forget the
  /// record rather than beaconing with no key).
  Future<void> init() async {
    if (_loaded) return;
    try {
      await ensureNodeId();
      final rec = await _persistence.loadRecord();
      final key = rec == null ? null : await _persistence.loadKey();
      if (rec != null && key != null) {
        _record = rec;
        _fleetKey = key;
      } else if (rec != null) {
        await _persistence.deleteRecord();
      }
    } catch (_) {}
    _loaded = true;
    _notify();
  }

  /// Start listening + beaconing (when in a fleet) or listening
  /// only (when unjoined, so fleets can be heard). Serialized with
  /// [stop] like CotListener. Never throws.
  Future<void> start() => _serialize(_start);

  Future<void> _start() async {
    await init();
    if (_socket != null) return;
    _lastError = null;
    final locked = await MulticastLock.acquire();
    if (!locked) {
      _lastError = 'multicast lock unavailable — Wi-Fi may drop fleet beacons';
    }
    RawDatagramSocket? sock;
    try {
      sock = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, fleetMulticastPort);
      sock.joinMulticast(InternetAddress(fleetMulticastGroup));
      // NOTE (spec §3, TTL 1): dart:io exposes no multicast-TTL
      // setter; the OS default multicast TTL is 1, which is the
      // spec value — beacons stay on the local segment by default.
      // If a platform ever defaults higher, this needs a native
      // setter; the fleet still works, it only reaches further.
    } catch (e) {
      try {
        sock?.close();
      } catch (_) {}
      _lastError = e.toString();
      await MulticastLock.release();
      return;
    }
    final bound = sock;
    _socket = bound;
    _listenStartedAt = _now();
    bound.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        for (var dg = bound.receive(); dg != null; dg = bound.receive()) {
          handleDatagram(dg.data, dg.address.address);
        }
      },
      onError: (Object e) => _socketDied(bound, e.toString()),
      onDone: () => _socketDied(bound, 'socket closed'),
      cancelOnError: true,
    );
    // Peer data arrives on the shared 49160 hub (spec §6).
    if (!_hubListening) {
      _hubListening = true;
      unawaited(NodeUdpHub.ensureListening(handleFleetDataText));
    }
    _beaconTimer?.cancel();
    _beaconTimer = Timer.periodic(
      const Duration(seconds: fleetBeaconIntervalSec),
      (_) => _sendBeacon(),
    );
    // Beacon immediately on start so a joiner sees us at once.
    _sendBeacon();
    await _startForeground();
    _notify();
  }

  void _socketDied(RawDatagramSocket sock, String why) {
    if (!identical(_socket, sock)) return;
    _socket = null;
    _lastError = 'fleet socket lost: $why';
    try {
      sock.close();
    } catch (_) {}
    unawaited(MulticastLock.release());
    // Fix 3: arm the rebind — the beacon timer's next tick(s)
    // retry start() with backoff until the socket is back.
    _needsRebind = true;
    _rebindAttempts = 0;
    _lastRebindAttemptAt = null;
    _notify();
  }

  /// Backoff between rebind attempts, by attempt count: 5/10/20/
  /// 40/60 s (capped at 60 s).
  static int _rebindBackoffSec(int attempts) {
    var backoff = 5 << attempts;
    if (backoff > 60) backoff = 60;
    return backoff;
  }

  /// Test seam: the rebind backoff schedule (Fix 3 — the cap is
  /// what keeps a dead interface from spinning a hot rebind loop).
  @visibleForTesting
  static int rebindBackoffSecForTest(int attempts) =>
      _rebindBackoffSec(attempts);

  /// One rebind attempt, at most once per backoff window. No-op
  /// when the socket is already back, no rebind is armed, or an
  /// attempt is already in flight. A successful rebind disarms;
  /// a failed one leaves the arm set for the next window.
  Future<void> _tryRebind() async {
    if (_socket != null || !_needsRebind || _rebindInFlight) return;
    final now = _now();
    final last = _lastRebindAttemptAt;
    if (last != null &&
        now.difference(last).inSeconds < _rebindBackoffSec(_rebindAttempts)) {
      return;
    }
    _rebindInFlight = true;
    _lastRebindAttemptAt = now;
    _rebindAttempts++;
    try {
      await start();
    } catch (_) {
      // start() never throws; this is belt-and-braces only.
    } finally {
      _rebindInFlight = false;
    }
    if (_socket != null) {
      _needsRebind = false;
      _rebindAttempts = 0;
      _lastRebindAttemptAt = null;
    }
  }

  Future<void> _startForeground() async {
    if (_foregroundStarted) return;
    final ok = await FleetForegroundService.start(members: peers.length + 1);
    _foregroundStarted = ok;
  }

  Future<void> _updateForeground() async {
    if (!_foregroundStarted) return;
    await FleetForegroundService.update(members: peers.length + 1);
  }

  /// Stop beaconing/listening. The foreground service stops too.
  Future<void> stop() => _serialize(_stop);

  Future<void> _stop() async {
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _needsRebind = false;
    _rebindAttempts = 0;
    _lastRebindAttemptAt = null;
    _rebindInFlight = false;
    final sock = _socket;
    _socket = null;
    if (sock != null) {
      try {
        sock.leaveMulticast(InternetAddress(fleetMulticastGroup));
      } catch (_) {}
      try {
        sock.close();
      } catch (_) {}
      await MulticastLock.release();
    }
    try {
      _sendSocket?.close();
    } catch (_) {}
    _sendSocket = null;
    if (_hubListening) {
      _hubListening = false;
      NodeUdpHub.release(handleFleetDataText);
    }
    if (_foregroundStarted) {
      _foregroundStarted = false;
      await FleetForegroundService.stop();
    }
    _listenStartedAt = null;
    _notify();
  }

  Future<void> _opChain = Future<void>.value();

  Future<void> _serialize(Future<void> Function() op) {
    final next = _opChain.then((_) => op()).catchError((Object _) {});
    _opChain = next;
    return next;
  }

  void _notify() {
    try {
      _onChanged?.call();
    } catch (_) {}
  }

  /// Build this device's beacon JSON (public values only).
  Map<String, dynamic> buildBeaconJson({DateTime? now}) {
    final at = now ?? _now();
    return FleetBeacon(
      fleetId: _record?.fleetId ?? '',
      saltB64: _record == null
          ? base64.encode(fleetRandomSalt())
          : _record!.saltB64,
      nodeId: _nodeId ?? '0000000000000000',
      callsign: callsign,
      appVersion: '0.29.6',
      hasSilvus: _hasSilvus(),
      memberCount: peers.length + 1,
      t: at.toUtc().millisecondsSinceEpoch ~/ 1000,
    ).toJson();
  }

  void _sendBeacon() {
    final sock = _socket;
    if (sock == null) {
      // Fix 3: the beacon timer keeps firing into a dead socket —
      // use its ticks as the rebind driver (backed off inside).
      // This runs before the in-fleet check so an unjoined
      // listener rebinds too.
      if (_needsRebind) unawaited(_tryRebind());
      return;
    }
    if (_record == null) return; // unjoined: listen only, never beacon
    try {
      final bytes = utf8.encode(jsonEncode(buildBeaconJson()));
      sock.send(bytes, InternetAddress(fleetMulticastGroup),
          fleetMulticastPort);
    } catch (_) {}
  }

  /// Create a fleet (lead): generate fleet_id + salt, derive the
  /// key from the 4-digit PIN, store the record + key, start
  /// beaconing as a member. The PIN is used once for the KDF and
  /// never stored. Throws [ArgumentError] on a malformed PIN.
  Future<FleetRecord> createFleet(String pin) async {
    await init();
    if (!fleetIsValidPin(pin)) {
      throw ArgumentError('Fleet PIN must be exactly 4 digits');
    }
    final fleetId = fleetRandomId();
    final salt = fleetRandomSalt();
    final key = await fleetDeriveKey(
        pin: pin, salt: salt, kdf: fleetKdfArgon2id);
    final nodeId = await ensureNodeId();
    final rec = FleetRecord(
      fleetId: fleetId,
      saltB64: base64.encode(salt),
      kdf: fleetKdfArgon2id,
      nodeId: nodeId,
      joinedAt: _now().toUtc(),
    );
    await _persistence.saveRecord(rec);
    await _persistence.saveKey(key);
    _record = rec;
    _fleetKey = key;
    _peers.clear();
    _heard.remove(fleetId);
    _sessions.clear();
    await start();
    _notify();
    return rec;
  }

  /// Join a heard fleet by dialing its 4-digit PIN (spec §4–§5).
  /// Returns true on admission, false on wrong PIN / timeout /
  /// no answer. The UI shows only "Wrong PIN — try again" — no
  /// detail about which step failed.
  Future<bool> joinFleet(FleetHeard heard, String pin) async {
    await init();
    if (!fleetIsValidPin(pin)) return false;
    List<int> candidateKey;
    try {
      candidateKey = await fleetDeriveKey(
          pin: pin, salt: base64.decode(heard.saltB64));
    } catch (_) {
      return false;
    }
    final built = await buildJoinRequest(
        heard: heard, candidateKey: candidateKey);
    if (built == null) return false;
    final (request, ephemeral) = built;
    final completer = Completer<Map<String, dynamic>?>();
    final pending = _PendingJoin(
      ephemeral: ephemeral,
      candidateKey: candidateKey,
      heard: heard,
      completer: completer,
    );
    _pendingJoins[heard.fleetId] = pending;
    try {
      await _sendUnicast(
          request, InternetAddress(heard.address), fleetMulticastPort);
    } catch (_) {
      if (identical(_pendingJoins[heard.fleetId], pending)) {
        _pendingJoins.remove(heard.fleetId);
      }
      return false;
    }
    Map<String, dynamic>? reply;
    try {
      reply = await completer.future
          .timeout(const Duration(seconds: 8));
    } on TimeoutException {
      reply = null;
    } catch (_) {
      reply = null;
    }
    if (identical(_pendingJoins[heard.fleetId], pending)) {
      _pendingJoins.remove(heard.fleetId);
    }
    if (reply == null) return false;
    return completeJoinFromReply(
        reply: reply,
        ephemeral: ephemeral,
        candidateKey: candidateKey,
        heard: heard);
  }

  /// Build a `fleet_join` request for [heard] using the candidate
  /// fleet key: ephemeral X25519 keypair + HMAC proof (spec §5).
  /// Returns (request JSON, ephemeral) or null when the node id is
  /// unavailable. Public so tests can drive the handshake without
  /// a socket.
  Future<(Map<String, dynamic>, FleetEphemeral)?> buildJoinRequest({
    required FleetHeard heard,
    required List<int> candidateKey,
  }) async {
    final nodeId = await ensureNodeId();
    final ephemeral = await fleetNewEphemeral();
    final proof = fleetJoinProof(
      fleetKey: candidateKey,
      ephPub: ephemeral.publicBytes,
      nodeId: nodeId,
      fleetId: heard.fleetId,
    );
    return (
      <String, dynamic>{
        'type': 'fleet_join',
        'fleet_id': heard.fleetId,
        'node_id': nodeId,
        'callsign': callsign,
        'eph_pub_b64': base64.encode(ephemeral.publicBytes),
        'proof_b64': base64.encode(proof),
      },
      ephemeral,
    );
  }

  /// Complete a join from a member's `fleet_join_reply`: derive the
  /// per-pair session key, store the fleet record + key, and start
  /// beaconing as a member. Returns false on any malformed reply.
  Future<bool> completeJoinFromReply({
    required Map<String, dynamic> reply,
    required FleetEphemeral ephemeral,
    required List<int> candidateKey,
    required FleetHeard heard,
  }) async {
    try {
      if (reply['type'] != 'fleet_join_reply') return false;
      if ('${reply['fleet_id'] ?? ''}' != heard.fleetId) return false;
      final memberNodeId = '${reply['node_id'] ?? ''}';
      if (memberNodeId.isEmpty || memberNodeId == _nodeId) return false;
      final memberPub = base64.decode('${reply['eph_pub_b64'] ?? ''}');
      if (memberPub.length != 32) return false;
      // Fix 1 (reviewer finding 1, spec §9 gap): the reply must
      // prove the replier holds the fleet key — HMAC-SHA256
      // (fleet_key, member_eph_pub || member_node_id || fleet_id)
      // — verified with the candidate key BEFORE the session key
      // is derived or any record stored. A bad proof is rejected
      // exactly like any other failed join (the UI shows only
      // "Wrong PIN — try again", no oracle).
      final proof = base64.decode('${reply['proof_b64'] ?? ''}');
      final expectedProof = fleetJoinProof(
        fleetKey: candidateKey,
        ephPub: memberPub,
        nodeId: memberNodeId,
        fleetId: heard.fleetId,
      );
      if (!fleetProofMatches(proof, expectedProof)) return false;
      final session = await fleetSessionKey(
          local: ephemeral, remotePub: memberPub);
      final nodeId = await ensureNodeId();
      final rec = FleetRecord(
        fleetId: heard.fleetId,
        saltB64: heard.saltB64,
        kdf: fleetKdfArgon2id,
        nodeId: nodeId,
        joinedAt: _now().toUtc(),
      );
      await _persistence.saveRecord(rec);
      await _persistence.saveKey(candidateKey);
      _record = rec;
      _fleetKey = candidateKey;
      _sessions[memberNodeId] = session;
      _heard.remove(heard.fleetId);
      await start();
      _notify();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Verify a `fleet_join` request (member side, spec §5):
  /// in a fleet, right fleet, rate-limit gate, HMAC proof over
  /// the candidate key. A failure counts toward rate limiting and
  /// is dropped silently (no "wrong PIN" oracle); a success
  /// resets the sender's counter. Never throws.
  bool verifyJoinRequest(Map<String, dynamic> j, String sourceAddress) {
    try {
      final rec = _record;
      final key = _fleetKey;
      if (rec == null || key == null) return false;
      if (j['type'] != 'fleet_join') return false;
      if ('${j['fleet_id'] ?? ''}' != rec.fleetId) return false;
      if (!_rateLimiter.allowAttempt(sourceAddress)) return false;
      final joinerNodeId = '${j['node_id'] ?? ''}';
      final ephPub = base64.decode('${j['eph_pub_b64'] ?? ''}');
      final proof = base64.decode('${j['proof_b64'] ?? ''}');
      if (joinerNodeId.isEmpty || ephPub.length != 32) {
        _rateLimiter.recordFailure(sourceAddress);
        return false;
      }
      final expected = fleetJoinProof(
        fleetKey: key,
        ephPub: ephPub,
        nodeId: joinerNodeId,
        fleetId: rec.fleetId,
      );
      if (!fleetProofMatches(proof, expected)) {
        _rateLimiter.recordFailure(sourceAddress);
        return false;
      }
      _rateLimiter.recordSuccess(sourceAddress);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Answer a verified `fleet_join` request: generate our ephemeral
  /// keypair, derive the per-pair session key, store it for the
  /// joiner, and return the `fleet_join_reply` JSON. The reply
  /// carries `proof_b64` — HMAC-SHA256(fleet_key, member_eph_pub ||
  /// member_node_id || fleet_id) — so the joiner can verify the
  /// replier holds the fleet key before trusting the reply (spec
  /// §5 step 3). Returns null when the request must be dropped
  /// (same cases as [verifyJoinRequest]).
  Future<Map<String, dynamic>?> answerJoinRequestAsync(
      Map<String, dynamic> j, String sourceAddress) async {
    if (!verifyJoinRequest(j, sourceAddress)) return null;
    try {
      final joinerNodeId = '${j['node_id'] ?? ''}';
      final joinerPub = base64.decode('${j['eph_pub_b64'] ?? ''}');
      final ephemeral = await fleetNewEphemeral();
      final session = await fleetSessionKey(
          local: ephemeral, remotePub: joinerPub);
      _sessions[joinerNodeId] = session;
      final memberNodeId = await ensureNodeId();
      final proof = fleetJoinProof(
        fleetKey: _fleetKey!,
        ephPub: ephemeral.publicBytes,
        nodeId: memberNodeId,
        fleetId: _record!.fleetId,
      );
      return <String, dynamic>{
        'type': 'fleet_join_reply',
        'fleet_id': _record!.fleetId,
        'node_id': memberNodeId,
        'eph_pub_b64': base64.encode(ephemeral.publicBytes),
        'proof_b64': base64.encode(proof),
      };
    } catch (_) {
      return null;
    }
  }

  /// Rate-limit gate (test seam: [answerJoinRequest] calls this).
  @visibleForTesting
  bool allowJoinAttemptForTest(String ip) => _rateLimiter.allowAttempt(ip);

  /// Silently re-run admission against a heard beacon of the
  /// remembered fleet using the stored key (spec §4: auto-rejoin
  /// on sight, no dialer). Fire-and-forget; failures are silent.
  /// The beacon source address is needed for the unicast join, so
  /// this is the entry point the beacon handler calls.
  Future<void> rejoinSilentlyFrom(
      FleetBeacon beacon, String sourceAddress) async {
    final rec = _record;
    final key = _fleetKey;
    if (rec == null || key == null) return;
    if (beacon.fleetId != rec.fleetId) return;
    if (beacon.nodeId == _nodeId) return;
    if (_sessions.containsKey(beacon.nodeId)) return;
    // One outstanding rejoin per member: a beacon every 5 s must
    // not stack a new 8 s wait behind the one already running.
    if (_pendingJoins.containsKey(beacon.nodeId)) return;
    try {
      final heard = FleetHeard(
        fleetId: beacon.fleetId,
        saltB64: beacon.saltB64,
        memberCount: beacon.memberCount,
        lastSeen: _now(),
        address: sourceAddress,
      );
      final built =
          await buildJoinRequest(heard: heard, candidateKey: key);
      if (built == null) return;
      final (request, ephemeral) = built;
      final completer = Completer<Map<String, dynamic>?>();
      final pending = _PendingJoin(
        ephemeral: ephemeral,
        candidateKey: key,
        heard: heard,
        completer: completer,
      );
      _pendingJoins[beacon.nodeId] = pending;
      await _sendUnicast(
          request, InternetAddress(sourceAddress), fleetMulticastPort);
      Map<String, dynamic>? reply;
      try {
        reply =
            await completer.future.timeout(const Duration(seconds: 8));
      } catch (_) {
        reply = null;
      }
      if (identical(_pendingJoins[beacon.nodeId], pending)) {
        _pendingJoins.remove(beacon.nodeId);
      }
      if (reply == null) return;
      await completeJoinFromReply(
        reply: reply,
        ephemeral: ephemeral,
        candidateKey: key,
        heard: heard,
      );
    } catch (_) {}
  }

  /// Feed one raw 6970 datagram through the fleet parser. Never
  /// throws: any parse failure drops the datagram silently.
  void handleDatagram(List<int> bytes, String sourceAddress) {
    try {
      final text = utf8.decode(bytes, allowMalformed: true);
      handleDatagramText(text, sourceAddress);
    } catch (_) {}
  }

  /// Feed one decoded 6970 datagram body. Never throws.
  void handleDatagramText(String text, String sourceAddress,
      {DateTime? now}) {
    try {
      final at = now ?? _now();
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return;
      final type = '${decoded['type'] ?? ''}';
      switch (type) {
        case 'fleet_beacon':
          _handleBeacon(decoded, sourceAddress, at);
        case 'fleet_join':
          _handleJoinDatagram(decoded, sourceAddress);
        case 'fleet_join_reply':
          _handleJoinReply(decoded);
      }
    } catch (_) {}
  }

  void _handleBeacon(
      Map<String, dynamic> j, String sourceAddress, DateTime at) {
    final beacon = FleetBeacon.tryParse(j, now: at);
    if (beacon == null) return;
    if (beacon.nodeId == _nodeId) return; // our own beacon, looped back
    _lastBeaconHeardAt = at;
    if (_record != null && beacon.fleetId == _record!.fleetId) {
      _upsertPeer(beacon, sourceAddress, at);
      // Auto-rejoin: a remembered fleet heard again re-runs
      // admission silently (no session with this member yet).
      if (!_sessions.containsKey(beacon.nodeId)) {
        unawaited(rejoinSilentlyFrom(beacon, sourceAddress));
      }
    } else {
      _upsertHeard(beacon, sourceAddress, at);
    }
    _prunePeers(at);
    unawaited(_updateForeground());
    _notify();
  }

  void _upsertPeer(FleetBeacon b, String address, DateTime at) {
    if (_peers.containsKey(b.nodeId) || _peers.length < fleetMaxPeers) {
      _peers[b.nodeId] = FleetPeer(
        nodeId: b.nodeId,
        callsign: b.callsign,
        fleetId: b.fleetId,
        hasSilvus: b.hasSilvus,
        memberCount: b.memberCount,
        lastSeen: at,
        address: address,
      );
    } else {
      // Cap: drop the oldest peer to make room (never crash).
      final oldest = _peers.values
          .reduce((a, c) => a.lastSeen.isBefore(c.lastSeen) ? a : c);
      _peers.remove(oldest.nodeId);
      _peers[b.nodeId] = FleetPeer(
        nodeId: b.nodeId,
        callsign: b.callsign,
        fleetId: b.fleetId,
        hasSilvus: b.hasSilvus,
        memberCount: b.memberCount,
        lastSeen: at,
        address: address,
      );
    }
  }

  void _upsertHeard(FleetBeacon b, String address, DateTime at) {
    if (_heard.containsKey(b.fleetId) ||
        _heard.length < fleetMaxHeardFleets) {
      _heard[b.fleetId] = FleetHeard(
        fleetId: b.fleetId,
        saltB64: b.saltB64,
        memberCount: b.memberCount,
        lastSeen: at,
        address: address,
      );
    }
  }

  void _prunePeers(DateTime at) {
    // Fix 2 (reviewer finding 2, spec §5 deviation): a pruned
    // peer's session key goes with it, plus its seen-nonce scope,
    // so a peer that leaves (> 15 s silence) and returns
    // re-handshakes and gets a fresh per-pair key instead of
    // reusing the old session indefinitely. The next beacon from
    // the returning member then triggers a fresh silent rejoin
    // via _handleBeacon (no session on file).
    final expired = _peers.entries
        .where((e) =>
            at.difference(e.value.lastSeen).inSeconds >
            fleetPeerTimeoutSec)
        .map((e) => e.key)
        .toList();
    for (final nodeId in expired) {
      _peers.remove(nodeId);
      _sessions.remove(nodeId);
      _seenNonces.removeWhere((n) => n.startsWith('$nodeId:'));
    }
  }

  /// Test seam: prune peers at [now] (dedup/expiry tests).
  @visibleForTesting
  void pruneForTest(DateTime now) => _prunePeers(now);

  /// Test seam: node ids with an outstanding (re)join handshake.
  /// A returning beacon triggers a fresh handshake iff its node
  /// id shows up here (Fix 2 test).
  @visibleForTesting
  Set<String> get pendingJoinNodeIdsForTest =>
      Set<String>.of(_pendingJoins.keys);

  /// Test seam: true while a socket-death rebind is armed (Fix 3).
  @visibleForTesting
  bool get needsRebindForTest => _needsRebind;

  /// Test seam: drive one rebind attempt now, honouring backoff
  /// (Fix 3 backoff test).
  @visibleForTesting
  Future<void> tryRebindForTest() => _tryRebind();

  /// Test seam: simulate the socket dying (Fix 3 test) — the same
  /// path the socket's onError/onDone handlers call. Arms the
  /// rebind; the beacon timer's next tick retries `start()`.
  @visibleForTesting
  void simulateSocketDeathForTest() {
    final sock = _socket;
    if (sock != null) {
      _socketDied(sock, 'test socket death');
    } else {
      // No live socket (bind failed in this environment): arm the
      // rebind directly so the recovery path is still exercisable.
      _needsRebind = true;
      _rebindAttempts = 0;
      _lastRebindAttemptAt = null;
      _lastError = 'fleet socket lost: test socket death';
      _notify();
    }
  }

  void _handleJoinDatagram(
      Map<String, dynamic> j, String sourceAddress) {
    // Answer asynchronously: the ephemeral keypair + session key
    // derivation are async, the reply goes out on the socket.
    unawaited(_answerAndReply(j, sourceAddress));
  }

  Future<void> _answerAndReply(
      Map<String, dynamic> j, String sourceAddress) async {
    final reply = await answerJoinRequestAsync(j, sourceAddress);
    if (reply == null) return;
    try {
      await _sendUnicast(
          reply, InternetAddress(sourceAddress), fleetMulticastPort);
    } catch (_) {}
  }

  void _handleJoinReply(Map<String, dynamic> j) {
    // Pending joins are keyed by member node id (auto-rejoin) or
    // by fleet id (dialer join) — a reply carries both, so match
    // either key.
    final byNode = _pendingJoins['${j['node_id'] ?? ''}'];
    final byFleet = _pendingJoins['${j['fleet_id'] ?? ''}'];
    final match = byNode ?? byFleet;
    if (match == null) return;
    if (!match.completer.isCompleted) match.completer.complete(j);
  }

  /// Handle one text datagram from the shared 49160 hub (spec §6).
  /// Only `fleet_data` envelopes are touched; everything else
  /// (sensor_obs, beacons) is left for the hub's other listeners.
  /// Decrypts under the sender's pairwise session key, verifies
  /// fleet_id + AAD, rejects replayed nonces, and feeds the inner
  /// JSON straight into SensorProtocol.parseUdpJson — the same
  /// parser, the same lenient never-throws contract. A failed
  /// decrypt drops the datagram silently. Never throws.
  Future<void> handleFleetDataText(String text) async {
    try {
      final trimmed = text.trim();
      if (!trimmed.startsWith('{') || !trimmed.contains('fleet_data')) {
        return;
      }
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['type'] != 'fleet_data') return;
      final fromNode = '${decoded['from_node'] ?? ''}';
      final session = _sessions[fromNode];
      final rec = _record;
      if (session == null || rec == null) return;
      final inner = await fleetDecryptEnvelope(
        decoded,
        sessionKey: session,
        expectedFleetId: rec.fleetId,
        seenNonces: _seenNonces,
      );
      if (inner == null) return;
      if (_seenNonces.length > 4096) {
        // Bound the replay set: clear it (nonces are random
        // 12-byte values, so a reset window costs nothing real).
        _seenNonces.clear();
      }
      final innerDecoded = jsonDecode(inner);
      if (innerDecoded is! Map<String, dynamic>) return;
      final result = SensorProtocol.parseUdpJson(innerDecoded);
      final obs = result.observation;
      if (obs == null) return;
      // Prefix the sensor id with the sender callsign so a peer's
      // `rf1` can never collide with local `rf1` (spec §6).
      final sender = _peers[fromNode];
      final prefixed = fleetPrefixedSensorId(
          sender?.callsign ?? fromNode, obs.sensorId);
      final prefixedObs = SensorObservation(
        type: obs.type,
        sensorId: prefixed,
        timestamp: obs.timestamp,
        levelDb: obs.levelDb,
        distanceM: obs.distanceM,
        angleDeg: obs.angleDeg,
        bearingDeg: obs.bearingDeg,
        confidence: obs.confidence,
        freqHz: obs.freqHz,
        magnitudes: obs.magnitudes,
        triggered: obs.triggered,
        zone: obs.zone,
        zoneLabel: obs.zoneLabel,
        sensorLat: obs.sensorLat,
        sensorLon: obs.sensorLon,
      );
      _onPeerObservation?.call(prefixedObs);
    } catch (_) {}
  }

  /// Share one local sensor observation with joined peers
  /// (sensing nodes only — spec §6). Encrypted per pair under the
  /// session key, sent as `fleet_data` on UDP 49160. No-op when
  /// unjoined, when this EUD has no live Silvus radio, or when
  /// there are no peers with sessions. Never throws.
  Future<void> shareObservation(SensorObservation obs) async {
    if (!inFleet || !_hasSilvus()) return;
    if (_sessions.isEmpty) return;
    final inner = SensorProtocol.toUdpJson(obs);
    for (final entry in _sessions.entries) {
      final peer = _peers[entry.key];
      if (peer == null) continue;
      try {
        final envelope = await fleetEncryptEnvelope(
          sessionKey: entry.value,
          fleetId: _record!.fleetId,
          fromNode: _nodeId ?? '',
          innerJson: inner,
        );
        await _sendUnicast(
            envelope, InternetAddress(peer.address), NodeUdpHub.port);
      } catch (_) {}
    }
  }

  /// Share several observations (one poll tick's worth).
  Future<void> shareObservations(List<SensorObservation> obs) async {
    for (final o in obs) {
      await shareObservation(o);
    }
  }

  /// Forget the fleet (spec §4): deletes the SharedPreferences
  /// record AND the secure-storage key, stops beaconing, drops
  /// all peers and sessions. The EUD is unjoined until it creates
  /// or joins again.
  Future<void> forgetFleet() async {
    await _persistence.deleteRecord();
    await _persistence.deleteKey();
    _record = null;
    _fleetKey = null;
    _peers.clear();
    _heard.clear();
    _sessions.clear();
    _pendingJoins.clear();
    _seenNonces.clear();
    await stop();
    _notify();
  }

  Future<RawDatagramSocket> _sendSocketFor() async {
    final cur = _sendSocket;
    if (cur != null) return cur;
    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _sendSocket = sock;
    return sock;
  }

  Future<void> _sendUnicast(
      Map<String, dynamic> json, InternetAddress address, int port) async {
    final sock = _socket ?? await _sendSocketFor();
    final bytes = utf8.encode(jsonEncode(json));
    sock.send(bytes, address, port);
  }

  /// Test hook: feed a fleet_data envelope text directly.
  @visibleForTesting
  Future<void> handleFleetDataTextForTest(String text) =>
      handleFleetDataText(text);
}

/// MQTT gateway tap (improvement #3): mesh-wide packet capture with
/// zero extra RF load.
///
/// One or two gateway nodes uplink every MeshPacket they hear to OUR
/// PRIVATE broker (Uplink enabled on our channel); this tap
/// subscribes and ingests every `ServiceEnvelope` — every MeshPacket
/// any gateway hears, including packets our local node never heard —
/// into the same per-edge [MeshLinkSeries] the driver feeds.
///
/// NEVER the public broker: the constructor throws for
/// `mqtt.meshtastic.org` (zero-hop policy, 10-16-bit position
/// precision cap, and the docs' explicit warning against the default
/// key on a private broker). The host is normalized before the
/// check (lowercased, trailing dots stripped) and any subdomain of
/// `mqtt.meshtastic.org` is refused too. An IP literal that happens
/// to point at the public broker cannot be caught by a string
/// match — use a hostname for our broker; the hygiene doc says so.
/// The broker here must be ours, with our channel's PSK;
/// gateway-heard edges are sender -> gateway, and like all
/// Meshtastic data they are UNTRUSTED fusion input
/// (corroborate/upgrade, never veto; never veto a Silvus tripwire).
///
/// LOOP RISK (docs, fw >= 2.2.19): a gateway that uplinks LoRa->MQTT
/// and downlinks MQTT->LoRa can loop indefinitely. ALL infrastructure
/// nodes MUST set `lora.ignore_mqtt=true`, and downlink stays off
/// unless a use case needs it — see `docs/meshtastic_hygiene_config.md`
/// and [MeshtasticMeshConfig].
///
/// TRANSPORT / SECURITY: the `mqtt_client` package (QoS 0 subscribe;
/// the tap only ever subscribes, never publishes), plain TCP port
/// 1883 — credentials go in cleartext. LAN-ONLY: run the broker on
/// our own private network; there is no TLS option in this tap
/// (see the hygiene doc §7). The default topic `msh/#` ingests
/// every channel on the broker — scope it to our channel/region
/// when wiring (e.g. `msh/US/2/e/<channel>/#`).
///
/// RECONNECT (FIX, re-review 2026-11-28, item 1): the tap owns
/// its reconnect — library `autoReconnect` is OFF. mqtt_client
/// 10.14.0's auto-reconnect re-fires immediately on failure with
/// no delay and no backoff knob, so against a dead broker it would
/// spin TCP-connect attempts as fast as they fail (CPU / battery /
/// log spam on the EUD). Instead a broker drop schedules a
/// tap-owned reconnect with backoff — 5 s, then 30 s, then 60 s
/// (capped; see [defaultReconnectDelays] and
/// [reconnectDelayFor]) — and a circuit breaker stops after
/// [maxReconnectAttempts] consecutive failed reconnects, surfacing
/// the give-up in [lastError] (call [connect] to retry manually).
/// A successful reconnect resets the failure count and increments
/// [reconnectCount]. [disconnect] cancels any pending retry.
/// The library's own per-call retry loop is disabled too
/// (`maxConnectionAttempts: 1` on the client): it would otherwise
/// re-try a refused broker 3x with no delay inside one
/// [connect] call, behind the tap's back.
/// [connect] only reports success once the SUBSCRIBE is confirmed
/// (FIX, item 6): a broker that CONNACKs but never SUBACKs, or
/// SUBACKs a failure, makes [connect] return false with [lastError]
/// set — a rejected subscription is no longer indistinguishable
/// from a quiet mesh. [lastMessageAt] is the liveness signal for a
/// connected-but-silent broker.
///
/// Disconnects and parse failures are surfaced in [lastError] and
/// [disconnectCount] — never swallowed silently. The envelope decode
/// itself is pure ([MeshPacketInfo.decodeEnvelope]) and unit-tested
/// without a broker.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import 'meshtastic_link_series.dart';
import 'meshtastic_proto.dart';

/// The public Meshtastic broker. Never used by this tap: passing it
/// as [host] throws. Our channel belongs on our own private broker.
const String publicMeshtasticBroker = 'mqtt.meshtastic.org';

/// Normalize a broker host for comparison: trim, lowercase, strip
/// trailing dots (`mqtt.meshtastic.org.` is the same host).
String _normalizeHost(String host) {
  var h = host.trim().toLowerCase();
  while (h.endsWith('.')) {
    h = h.substring(0, h.length - 1);
  }
  return h;
}

/// True when [host] is the public Meshtastic broker or any of its
/// subdomains (e.g. `eu.mqtt.meshtastic.org`).
bool _isPublicBrokerHost(String host) {
  final h = _normalizeHost(host);
  return h == publicMeshtasticBroker ||
      h.endsWith('.$publicMeshtasticBroker');
}

/// MQTT gateway tap: subscribes to a private broker and feeds every
/// ServiceEnvelope into a [MeshLinkSeries].
class MeshtasticMqttTap {
  MeshtasticMqttTap({
    required this.host,
    this.port = 1883,
    this.topic = 'msh/#',
    this.clientId = 'outride-mqtt-tap',
    this.username,
    this.password,
    this.subscribeTimeout = const Duration(seconds: 5),
    this.connectTimeout = const Duration(seconds: 10),
    this.reconnectDelays = defaultReconnectDelays,
    this.maxReconnectAttempts = 10,
    MeshLinkSeries? linkSeries,
  }) : linkSeries = linkSeries ?? MeshLinkSeries() {
    if (host.trim().isEmpty) {
      throw ArgumentError('MQTT broker host must not be empty');
    }
    if (_isPublicBrokerHost(host)) {
      throw ArgumentError(
        'refusing the public broker $publicMeshtasticBroker (or a '
        'subdomain of it): use our own private broker for our '
        'channel (see docs/meshtastic_hygiene_config.md)',
      );
    }
  }

  final String host;
  final int port;

  /// Subscribe topic. Default `msh/#` (all regions/channels on our
  /// private broker). Gateway topics look like
  /// `msh/REGION/2/e/CHANNELNAME/USERID`. Scope this to our
  /// channel/region when wiring — the default ingests every channel
  /// on the broker.
  final String topic;
  final String clientId;
  final String? username;
  final String? password;

  /// How long [connect] waits for the SUBSCRIBE confirmation
  /// (SUBACK) before reporting failure.
  final Duration subscribeTimeout;

  /// How long [connect] waits for the broker's CONNACK before
  /// reporting failure.
  final Duration connectTimeout;

  /// Tap-owned reconnect backoff schedule: the delay before
  /// reconnect attempt N (0-based) is `reconnectDelays[N]`, capped
  /// at the last entry — 5 s, then 30 s, then 60 s. The tap never
  /// retries with no delay (see the file header).
  static const List<Duration> defaultReconnectDelays = [
    Duration(seconds: 5),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];

  /// Backoff schedule for this tap (defaults to
  /// [defaultReconnectDelays]).
  final List<Duration> reconnectDelays;

  /// Circuit breaker: after this many consecutive failed
  /// tap-owned reconnect attempts the tap stops retrying and
  /// surfaces the give-up in [lastError]. A manual [connect]
  /// resets the count; a successful reconnect resets it too.
  final int maxReconnectAttempts;

  /// Delay before reconnect attempt [attemptIndex] (0-based),
  /// capped at the last entry of [delays]. Pure, unit-tested:
  /// attempt 0 → 5 s, 1 → 30 s, 2+ → 60 s on the defaults.
  static Duration reconnectDelayFor(int attemptIndex,
      [List<Duration> delays = defaultReconnectDelays]) {
    if (delays.isEmpty) return const Duration(seconds: 60);
    final i = attemptIndex < 0
        ? 0
        : attemptIndex >= delays.length
            ? delays.length - 1
            : attemptIndex;
    return delays[i];
  }

  /// The series every gateway-heard packet is recorded into.
  final MeshLinkSeries linkSeries;

  MqttServerClient? _client;
  StreamSubscription? _sub;
  bool _intentionalDisconnect = false;
  Timer? _reconnectTimer;
  bool _reconnectInProgress = false;
  bool _connecting = false;
  int _consecutiveReconnectFailures = 0;

  /// Packets ingested from the tap (envelopes with a packet).
  int packetsSeen = 0;

  /// Envelopes that arrived but could not be decoded (counted and
  /// surfaced, never silently dropped without a trace).
  int malformedCount = 0;

  /// How many times the broker connection has dropped.
  int disconnectCount = 0;

  /// How many times the tap reconnected after a drop.
  int reconnectCount = 0;

  /// How many tap-owned reconnect attempts have been started
  /// (successful or not) since the last manual [connect] /
  /// [disconnect]. The circuit-breaker test reads this to prove
  /// retries stop.
  int reconnectAttempts = 0;

  /// Last failure reason, or null when healthy / never attempted.
  String? lastError;

  /// When the last message arrived from the broker (liveness
  /// signal: a connected-but-silent broker leaves this stale).
  DateTime? lastMessageAt;

  /// True once the broker has confirmed our subscription (SUBACK).
  /// False after a subscribe failure or before [connect].
  bool isSubscribed = false;

  bool get isConnected =>
      _client?.connectionStatus?.state ==
      MqttConnectionState.connected;

  /// Connect + subscribe. Returns true only when the subscription
  /// is CONFIRMED (SUBACK received). Returns false (with
  /// [lastError] set) on any failure — connect failure, subscribe
  /// refusal (SUBACK failure code), or subscribe-confirmation
  /// timeout. Does not throw.
  ///
  /// A manual [connect] supersedes any pending tap-owned retry.
  /// On EVERY failure path the local client is torn down before
  /// returning false (FIX, re-review item 2): a client left
  /// behind with `autoReconnect` on could complete connecting in
  /// the background and reconnect forever with no reference left
  /// to stop it, and a retry would create a second client with
  /// the same client ID, so the broker kicks one. The SUBACK
  /// failure path already tore down via [disconnect]; the
  /// connect-timeout / non-connected paths now match it.
  Future<bool> connect() async {
    if (_connecting) {
      lastError = 'MQTT connect already in progress';
      return false;
    }
    _connecting = true;
    try {
      lastError = null;
      _intentionalDisconnect = false;
      _cancelReconnectTimer();
      // Tear down any previous client first (e.g. the dead client
      // from a broker drop) so a retry never leaves two clients
      // alive with the same client ID.
      await _tearDownClient();
      final client = MqttServerClient.withPort(
        host,
        clientId,
        port,
        // The library's own connect loop retries a refused / silent
        // broker up to maxConnectionAttempts (default 3) with no
        // delay between tries — the same immediate spin item 1
        // removes. One TCP attempt per connect() call: the tap's
        // backoff + circuit breaker are the only retry policy.
        maxConnectionAttempts: 1,
      );
      client.logging(on: false);
      client.keepAlivePeriod = 30;
      // FIX (re-review item 1): library auto-reconnect is OFF.
      // mqtt_client 10.14.0 re-fires immediately on failure with
      // no delay and no backoff knob — against a dead broker it
      // spins TCP connects as fast as they fail. The tap owns its
      // reconnect instead (backoff + circuit breaker, see
      // [_onDisconnected] / [_scheduleReconnect]).
      client.autoReconnect = false;
      client.onDisconnected = _onDisconnected;
      _client = client;
      final status = await client
          .connect(username, password)
          .timeout(connectTimeout);
      if (_intentionalDisconnect) {
        // disconnect() was called while connecting: the client
        // was already torn down there; do not resurrect it.
        await _tearDownClient();
        return false;
      }
      if (status?.state != MqttConnectionState.connected) {
        lastError =
            'MQTT connect failed: ${status?.state} (${status?.returnCode})';
        await _tearDownClient();
        return false;
      }
      // Attach the updates listener BEFORE subscribing so a publish
      // that arrives immediately after the SUBACK cannot be missed.
      _sub = client.updates?.listen(_onMessages, onError: (Object e) {
        lastError = 'MQTT updates stream error: $e';
      });
      // FIX (review item 6): wait for the SUBACK — CONNACK alone
      // is not success. A broker that never SUBACKs, or SUBACKs a
      // failure, makes connect() return false.
      final subResult = Completer<bool>();
      client.onSubscribed = (String t) {
        isSubscribed = true;
        if (!subResult.isCompleted) subResult.complete(true);
      };
      client.onSubscribeFail = (String t) {
        isSubscribed = false;
        lastError = 'MQTT subscribe refused for topic $t';
        if (!subResult.isCompleted) subResult.complete(false);
      };
      client.subscribe(topic, MqttQos.atMostOnce);
      final confirmed = await subResult.future.timeout(
        subscribeTimeout,
        onTimeout: () {
          lastError ??= 'MQTT subscribe confirmation timed out after '
              '${subscribeTimeout.inSeconds}s (broker CONNACKed but '
              'never SUBACKed)';
          return false;
        },
      );
      if (_intentionalDisconnect) {
        await _tearDownClient();
        return false;
      }
      if (!confirmed) {
        isSubscribed = false;
        // Tear down directly (not via disconnect(): that would
        // set _intentionalDisconnect and stop a reconnect loop
        // that is legitimately retrying this failure).
        await _tearDownClient();
        return false;
      }
      _consecutiveReconnectFailures = 0;
      return true;
    } catch (e) {
      lastError = 'MQTT connect failed: $e';
      await _tearDownClient();
      return false;
    } finally {
      _connecting = false;
    }
  }

  /// Tear down the current client, if any: detach its callbacks
  /// (so tearing down a dead client cannot re-fire
  /// [_onDisconnected] and schedule a phantom reconnect),
  /// cancel the updates subscription, stop any reconnect loop,
  /// disconnect, and drop the reference. Safe to call when there
  /// is no client.
  ///
  /// Cancelling the retry timer here is the S1 fix (final delta
  /// check): a broker drop mid-handshake arms a timer via
  /// [_onDisconnected] while [connect] is still awaiting the
  /// SUBACK, and every [connect] failure path tears the client
  /// down here — so the timer must die here too, or the tap
  /// auto-retries after a failed manual connect(), contradicting
  /// "a manual connect() supersedes any pending tap-owned retry".
  /// Safe for [_attemptReconnect]: it schedules explicitly after
  /// [connect] returns.
  Future<void> _tearDownClient() async {
    _cancelReconnectTimer();
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    final c = _client;
    _client = null;
    if (c == null) return;
    try {
      c.onDisconnected = null;
      c.onAutoReconnect = null;
      c.onAutoReconnected = null;
      c.onSubscribed = null;
      c.onSubscribeFail = null;
      c.autoReconnect = false;
      c.disconnect();
    } catch (_) {}
  }

  void _cancelReconnectTimer() {
    try {
      _reconnectTimer?.cancel();
    } catch (_) {}
    _reconnectTimer = null;
  }

  /// Schedule the next tap-owned reconnect after a broker drop,
  /// with backoff ([reconnectDelayFor]) — unless a retry is
  /// already pending / in flight, the tap was intentionally
  /// disconnected, or the circuit breaker has tripped.
  void _scheduleReconnect() {
    if (_intentionalDisconnect ||
        _reconnectTimer != null ||
        _reconnectInProgress) {
      return;
    }
    if (_consecutiveReconnectFailures >= maxReconnectAttempts) {
      lastError = 'MQTT reconnect gave up after '
          '$maxReconnectAttempts consecutive failures; call connect() '
          'to retry manually';
      return;
    }
    final delay =
        reconnectDelayFor(_consecutiveReconnectFailures, reconnectDelays);
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_attemptReconnect());
    });
  }

  /// One tap-owned reconnect attempt: a full [connect] (fresh
  /// client + SUBACK confirmation). Success resets the failure
  /// count and counts in [reconnectCount]; failure increments it
  /// and schedules the next attempt (or trips the breaker).
  Future<void> _attemptReconnect() async {
    if (_intentionalDisconnect || _reconnectInProgress) return;
    _reconnectInProgress = true;
    bool ok;
    // N1 (final delta check): a manual connect() in flight makes
    // this attempt hit the _connecting guard and return false
    // instantly — that is not a failed reconnect and must not burn
    // a circuit-breaker count. (No await sits between this read
    // and the connect() call, so the guard state cannot change
    // under it.) The next attempt is still scheduled, so the
    // retry loop continues once the manual connect settles.
    final guardHit = _connecting;
    try {
      reconnectAttempts++;
      ok = await connect();
    } finally {
      // Clear before scheduling the next attempt: the schedule
      // guard refuses while an attempt is in flight, and this
      // attempt is over.
      _reconnectInProgress = false;
    }
    if (_intentionalDisconnect) return;
    if (ok) {
      reconnectCount++;
      _consecutiveReconnectFailures = 0;
    } else if (guardHit) {
      _scheduleReconnect();
    } else {
      _consecutiveReconnectFailures++;
      _scheduleReconnect();
    }
  }

  void _onDisconnected() {
    // An intentional disconnect() must not look like a broker
    // failure, and must not schedule a reconnect.
    if (_intentionalDisconnect) return;
    disconnectCount++;
    lastError ??= 'MQTT broker disconnected';
    _scheduleReconnect();
  }

  void _onMessages(List<MqttReceivedMessage<MqttMessage>> messages) {
    for (final m in messages) {
      final payload = m.payload;
      if (payload is! MqttPublishMessage) continue;
      ingestEnvelopeBytes(
          Uint8List.fromList(payload.payload.message));
    }
  }

  /// Ingest one raw ServiceEnvelope payload (the MQTT PUBLISH body).
  /// Returns the decoded packet, or null when the envelope carried
  /// no usable packet (counted in [malformedCount]).
  ///
  /// Packets with `from == 0` are dropped (the driver drops them
  /// too — FIX, review item 11: the tap used to record them), and
  /// a gateway id that does not parse as a `!hex` node id is
  /// skipped and counted as malformed instead of merging its edges
  /// into the local-node sentinel 0 (same item: 0 is
  /// `MeshLinkSeries.localNode`, "our node, number unknown").
  MeshPacketInfo? ingestEnvelopeBytes(Uint8List bytes) {
    final info = MeshPacketInfo.decodeEnvelope(bytes);
    if (info == null || info.from == 0) {
      malformedCount++;
      return null;
    }
    final gatewayNum = _gatewayNodeNum(info.gatewayId);
    if (gatewayNum == null) {
      malformedCount++;
      return null;
    }
    packetsSeen++;
    lastMessageAt = DateTime.now();
    // Gateway-heard edge: sender -> gateway.
    linkSeries.record(MeshLinkSample(
      timestamp: DateTime.now(),
      fromNode: info.from,
      toNode: gatewayNum,
      snr: info.rxSnr,
      rssi: info.rxRssi,
      hopCount: info.hopCount,
      portnum: info.portnum,
    ));
    return info;
  }

  /// Parse a gateway id string ("!a1b2c3d4" or "a1b2c3d4") to a node
  /// number. Returns null when it is not a hex node id (including
  /// a missing gateway id) — the caller skips the packet rather
  /// than recording it against the local-node sentinel 0.
  static int? _gatewayNodeNum(String? gatewayId) {
    if (gatewayId == null) return null;
    var s = gatewayId.trim();
    if (s.startsWith('!')) s = s.substring(1);
    if (s.isEmpty) return null;
    // FIX (re-review item 10): require all-hex, no sign.
    // int.tryParse with radix 16 accepts a leading minus, so a
    // gateway id of "-1" used to record an edge to node -1 instead
    // of counting as malformed. (A leading '+' is rejected the
    // same way.)
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(s)) return null;
    return int.tryParse(s, radix: 16);
  }

  /// Coverage stat: packets seen by the tap. Compare against the
  /// driver's own packet count on the bench: the tap should see
  /// >= 95% of the packets the local node's radio sees, plus
  /// packets from nodes out of the local node's range.
  int get coveragePacketsSeen => packetsSeen;

  /// Intentional disconnect: stops the tap, cancels any pending
  /// tap-owned reconnect, and tears the client down. Never
  /// schedules a reconnect (see [_onDisconnected]).
  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    isSubscribed = false;
    _cancelReconnectTimer();
    await _tearDownClient();
    _consecutiveReconnectFailures = 0;
  }

  void dispose() {
    unawaited(disconnect());
  }
}

/// Fleet chat service — text chat over the Outride auto-mesh.
///
/// Design note: `research_notes/outride-fleet-chat.md`. Two modes:
/// the fleet channel (every message out to all team members) and
/// 1:1 DMs (tap a team member to open their thread). Both ride the
/// existing encrypted mesh: each message is fanned out per peer,
/// encrypted with that peer's X25519 session key, inside the
/// existing `fleet_data` envelope on UDP 49160. No new crypto, no
/// group key, no cloud, no external service.
///
/// Reliability on UDP: message ids + acks + retry (3× at 2/4/8 s)
/// + dedup. A message is never lost silently — it ends `sent`,
/// `partial`, or `failed`, with the peers named.
///
/// Transport seams (tests): the send path is an injected
/// `sendEnvelope` sink (production binds its own ephemeral UDP
/// socket, same pattern as `FleetService._sendSocketFor`), and
/// inbound datagrams arrive through [handleHubText] — the same
/// shape as `FleetService.handleFleetDataText`. Production registers
/// [handleHubText] with `NodeUdpHub` in [start]; tests call it
/// directly with fabricated envelope text. The pump (send queue +
/// retries) runs on a 500 ms timer and is also drivable directly
/// in tests via [pumpForTest] with an injected clock.
library fleet_chat_service;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'fleet_chat.dart';
import 'fleet_crypto.dart';
import 'fleet_service.dart';
import 'node_udp_hub.dart';

/// Result of a send attempt. `ok` means the message was filed and
/// its fan-out started (delivery itself is async — the message
/// shows SENDING… until acks land). When `!ok`, `reason` is a
/// plain-words explanation and `message` is the filed message when
/// one was created (a failed send is still shown in the thread, so
/// the operator sees what happened and can retry it).
class FleetChatSendResult {
  const FleetChatSendResult({
    required this.ok,
    this.reason,
    this.message,
  });

  final bool ok;
  final String? reason;
  final FleetChatMessage? message;
}

/// One queued fan-out: one message to a fixed set of peers. The
/// pump sends at most one job per 500 ms.
class _ChatJob {
  _ChatJob({required this.message, required this.targets});

  final FleetChatMessage message;

  /// Peer node ids to send this copy to.
  final List<String> targets;
}

/// One message with retries still scheduled: attempts sent so far
/// (1 = initial send) and when the next retry is due. `sent` is
/// false until the first fan-out has actually run — a message
/// still waiting in the outbound queue must not also get a retry
/// job (the queue owns it until it runs; see [_pump]).
class _PendingChat {
  _PendingChat({required this.message, required this.nextRetryAt})
      : attemptsSent = 1;

  final FleetChatMessage message;
  int attemptsSent;
  bool sent = false;
  DateTime nextRetryAt;
}

/// One peer's inbound message count inside a 60 s window.
class _InboundWindow {
  _InboundWindow({required this.windowStart, required this.count});

  DateTime windowStart;
  int count;
}

class FleetChatService {
  FleetChatService({
    required Future<String> Function() ownNodeId,
    required String Function() ownCallsign,
    required String? Function() fleetId,
    required bool Function() inFleet,
    required List<FleetPeer> Function() peers,
    required Map<String, List<int>> Function() sessions,
    void Function()? onChanged,
    DateTime Function()? now,
    Future<void> Function(Map<String, dynamic> envelope, String address)?
        sendEnvelope,
  })  : _ownNodeIdFn = ownNodeId,
        _ownCallsign = ownCallsign,
        _fleetIdFn = fleetId,
        _inFleetFn = inFleet,
        _peersFn = peers,
        _sessionsFn = sessions,
        _onChanged = onChanged,
        _now = now ?? DateTime.now,
        _sendEnvelopeOverride = sendEnvelope;

  final Future<String> Function() _ownNodeIdFn;
  final String Function() _ownCallsign;
  final String? Function() _fleetIdFn;
  final bool Function() _inFleetFn;
  final List<FleetPeer> Function() _peersFn;
  final Map<String, List<int>> Function() _sessionsFn;
  final void Function()? _onChanged;
  final DateTime Function() _now;
  final Future<void> Function(Map<String, dynamic>, String)?
      _sendEnvelopeOverride;

  /// Threads, in arrival order, oldest first. Capped at
  /// [fleetChatMaxHistoryPerThread] per thread; oldest dropped.
  final Map<String, List<FleetChatMessage>> _threads = {};

  /// Seen inbound message ids, insertion-ordered, bounded at
  /// [fleetChatMaxSeenIds]. A duplicate is acked again but never
  /// displayed twice.
  final LinkedHashSet<String> _seenIds = LinkedHashSet<String>();

  /// Seen (nonce, sender) pairs for `fleet_data` replay rejection
  /// on the chat path. Independent of the fleet service's own set
  /// — each side records the nonces it decrypts.
  final Set<String> _seenNonces = {};

  /// Next own sequence number per thread (in-memory, from 1).
  final Map<String, int> _seq = {};

  /// Messages with retries still scheduled, keyed by message id.
  final Map<String, _PendingChat> _pending = {};

  /// Outbound fan-out jobs waiting for the 500 ms pacing window.
  final List<_ChatJob> _queue = [];

  /// Per-peer inbound counts for the 30/min cap.
  final Map<String, _InboundWindow> _inbound = {};

  /// Unread counts per thread. Incremented on an incoming message
  /// while another thread is open; cleared when the thread opens.
  final Map<String, int> _unread = {};

  /// Last non-null fleet id this service has seen. Chat history is
  /// scoped to the fleet: when the id changes, all of it is
  /// dropped (see [_maybeResetForFleet]).
  String? _lastFleetId;

  /// Thread currently open in the UI, or null for the thread list.
  String? _openThread;

  Timer? _pumpTimer;
  RawDatagramSocket? _sendSocket;
  bool _started = false;
  bool _disposed = false;
  String? _ownNodeIdCache;
  DateTime? _lastSendAt;

  /// The hub listener, stored once: `NodeUdpHub` removes listeners
  /// by identity, so registration and release must use the same
  /// closure instance (a fresh method tear-off each time would not
  /// match).
  void Function(String)? _hubListener;

  void _onHubText(String text) {
    unawaited(handleHubText(text));
  }

  /// False on web: there is no mesh there, so the service never
  /// binds a socket or registers a hub listener. The chat screen
  /// shows the simulated / no-fleet state instead.
  bool get available => !kIsWeb;

  bool get isStarted => _started;

  /// Drop all chat state when the fleet id changes. History is
  /// scoped to the fleet: joining a different fleet must never
  /// show the old fleet's messages — or its unread badge — as the
  /// new fleet's channel. Queued and pending jobs go too: their
  /// envelopes carry the old fleet id as AAD and would fail
  /// authentication on the new fleet anyway. Rejoining the SAME
  /// fleet id keeps history — the reset fires on change only, and
  /// a null id (not in a fleet) never resets, so forget-then-rejoin
  /// of the same fleet is a no-op. Deliberately silent: no notify
  /// here — the fleet change itself is notified by AppState, and
  /// every send path notifies after filing, so the thread list
  /// re-reads the cleared state on the next build. (Notifying
  /// from inside start() marked a ListenableBuilder dirty during
  /// build and failed the Fleet screen widget test.)
  void _maybeResetForFleet() {
    final id = _fleetIdFn();
    if (id == null || id == _lastFleetId) return;
    _lastFleetId = id;
    _threads.clear();
    _unread.clear();
    _seq.clear();
    _seenIds.clear();
    _pending.clear();
    _queue.clear();
  }

  /// Start the service: register the hub listener and arm the
  /// pump timer. Idempotent; never throws. On web this is a
  /// no-op (see [available]).
  Future<void> start() async {
    _maybeResetForFleet();
    if (_started || _disposed) return;
    _started = true;
    if (!available) return;
    // Arm the pump timer first: its lifecycle must not depend on
    // how long the hub bind takes (in a widget test's fake-async
    // zone the bind may complete after dispose).
    _pumpTimer ??= Timer.periodic(
      const Duration(milliseconds: fleetChatOutboundMinGapMs),
      (_) => unawaited(_pump()),
    );
    _hubListener ??= _onHubText;
    try {
      await NodeUdpHub.ensureListening(_hubListener!);
    } catch (_) {}
  }

  /// Stop the service: cancel the pump, release the hub listener,
  /// close the send socket. Idempotent; never throws.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _started = false;
    _pumpTimer?.cancel();
    _pumpTimer = null;
    final hubListener = _hubListener;
    if (hubListener != null) {
      try {
        NodeUdpHub.release(hubListener);
      } catch (_) {}
    }
    try {
      _sendSocket?.close();
    } catch (_) {}
    _sendSocket = null;
  }

  /// Messages in [threadId], oldest first. Empty when none.
  /// `'fleet'` is the fleet channel; `'dm:<node id>'` is a DM.
  List<FleetChatMessage> messagesFor(String threadId) {
    final list = _threads[threadId];
    if (list == null) return const [];
    return List.unmodifiable(list);
  }

  /// Thread ids that hold at least one message.
  Set<String> get threadIdsWithMessages => Set.of(_threads.keys);

  /// Unread count for [threadId] (0 when none).
  int unreadCount(String threadId) => _unread[threadId] ?? 0;

  /// Overall delivery state of [message], accounting for retries
  /// still scheduled: a message with retries pending shows
  /// SENDING… even when its peers are all `noSession` so far.
  FleetChatOverall overallFor(FleetChatMessage message) {
    if (_pending.containsKey(message.id)) return FleetChatOverall.sending;
    return message.overall;
  }

  /// Tell the service which thread the UI currently shows (null
  /// for the thread list). Opens the thread: clears its unread
  /// count. Incoming messages to the open thread do not increment
  /// its unread count.
  void openThread(String? threadId) {
    _openThread = threadId;
    if (threadId != null) {
      _unread.remove(threadId);
      _notify();
    }
  }

  /// Send [text] to the fleet channel — every team member. The
  /// message is filed immediately (SENDING…) and fanned out per
  /// peer. Returns a failure result when the text is invalid, the
  /// device is not in a fleet, or the send queue is full; a filed
  /// message is returned in the result either way.
  Future<FleetChatSendResult> sendFleet(String text) async {
    _maybeResetForFleet();
    final trimmed = text.trim();
    final err = fleetChatTextError(trimmed);
    if (err != null) {
      return FleetChatSendResult(ok: false, reason: err);
    }
    if (!_inFleetFn() || _fleetIdFn() == null) {
      return const FleetChatSendResult(ok: false, reason: 'NOT IN A FLEET');
    }
    if (_queue.length >= fleetChatOutboundQueueMax) {
      return const FleetChatSendResult(
          ok: false, reason: 'SEND QUEUE FULL — SLOW DOWN');
    }
    final ownId = await _ownNodeId();
    if (ownId == null) {
      return const FleetChatSendResult(
          ok: false, reason: 'NO NODE ID — TRY AGAIN');
    }
    final peers = _peersFn();
    final sessions = _sessionsFn();
    final peerStates = <String, FleetChatPeerState>{};
    final targets = <String>[];
    for (final p in peers) {
      if (sessions.containsKey(p.nodeId)) {
        peerStates[p.nodeId] = FleetChatPeerState.pending;
        targets.add(p.nodeId);
      } else {
        // Exchange still in flight: named, not silently dropped.
        // A retry after the exchange completes can deliver it.
        peerStates[p.nodeId] = FleetChatPeerState.noSession;
      }
    }
    final msg = _fileOutgoing(
      threadId: fleetChatThreadFleet,
      fromNode: ownId,
      text: trimmed,
      peerStates: peerStates,
    );
    if (targets.isNotEmpty) {
      _enqueueJob(_ChatJob(message: msg, targets: targets));
    }
    if (peerStates.values
        .any((s) => s == FleetChatPeerState.pending || s == FleetChatPeerState.noSession)) {
      _pending[msg.id] = _PendingChat(
        message: msg,
        nextRetryAt:
            _now().add(Duration(seconds: fleetChatRetryDelaysSec[0])),
      );
    }
    _notify();
    if (peers.isEmpty) {
      return FleetChatSendResult(
          ok: false, reason: 'NO TEAM MEMBERS TO SEND TO', message: msg);
    }
    if (targets.isEmpty) {
      return FleetChatSendResult(
          ok: false,
          reason: 'NO SECURE SESSION WITH ANY TEAM MEMBER YET',
          message: msg);
    }
    return FleetChatSendResult(ok: true, message: msg);
  }

  /// Send [text] as a DM to one peer. The message is encrypted
  /// with that peer's session key only and sent only to them.
  Future<FleetChatSendResult> sendDm(String peerNodeId, String text) async {
    _maybeResetForFleet();
    final trimmed = text.trim();
    final err = fleetChatTextError(trimmed);
    if (err != null) {
      return FleetChatSendResult(ok: false, reason: err);
    }
    if (!_inFleetFn() || _fleetIdFn() == null) {
      return const FleetChatSendResult(ok: false, reason: 'NOT IN A FLEET');
    }
    if (_queue.length >= fleetChatOutboundQueueMax) {
      return const FleetChatSendResult(
          ok: false, reason: 'SEND QUEUE FULL — SLOW DOWN');
    }
    final ownId = await _ownNodeId();
    if (ownId == null) {
      return const FleetChatSendResult(
          ok: false, reason: 'NO NODE ID — TRY AGAIN');
    }
    final peer = _peersFn().where((p) => p.nodeId == peerNodeId).firstOrNull;
    final threadId = fleetChatDmThread(peerNodeId);
    if (peer == null) {
      final msg = _fileOutgoing(
        threadId: threadId,
        fromNode: ownId,
        text: trimmed,
        peerStates: {peerNodeId: FleetChatPeerState.gone},
      );
      _notify();
      return FleetChatSendResult(
          ok: false, reason: 'EUD LEFT THE FLEET', message: msg);
    }
    final hasSession = _sessionsFn().containsKey(peerNodeId);
    final msg = _fileOutgoing(
      threadId: threadId,
      fromNode: ownId,
      text: trimmed,
      peerStates: {
        peerNodeId: hasSession
            ? FleetChatPeerState.pending
            : FleetChatPeerState.noSession
      },
    );
    if (hasSession) {
      _enqueueJob(_ChatJob(message: msg, targets: [peerNodeId]));
      _pending[msg.id] = _PendingChat(
        message: msg,
        nextRetryAt:
            _now().add(Duration(seconds: fleetChatRetryDelaysSec[0])),
      );
      _notify();
      return FleetChatSendResult(ok: true, message: msg);
    }
    _pending[msg.id] = _PendingChat(
      message: msg,
      nextRetryAt: _now().add(Duration(seconds: fleetChatRetryDelaysSec[0])),
    );
    _notify();
    return FleetChatSendResult(
        ok: false,
        reason: 'NO SECURE SESSION WITH THIS EUD YET',
        message: msg);
  }

  /// Manually retry a failed (or partial) message: re-sends to the
  /// peers that never acked. A message still SENDING… (retries
  /// scheduled) is a no-op — the automatic retries already cover
  /// it. Never throws.
  Future<void> retryMessage(String threadId, String messageId) async {
    try {
      if (_pending.containsKey(messageId)) return;
      final list = _threads[threadId];
      if (list == null) return;
      final msg = list.where((m) => m.id == messageId).firstOrNull;
      if (msg == null || !msg.outgoing) return;
      final sessions = _sessionsFn();
      // A fleet message filed when nobody was around has no peer
      // states at all: recompute its targets from whoever is in
      // the fleet now, so the retry can deliver it to late
      // arrivals instead of being a dead tap.
      if (msg.peerStates.isEmpty && msg.threadId == fleetChatThreadFleet) {
        for (final p in _peersFn()) {
          msg.peerStates[p.nodeId] = sessions.containsKey(p.nodeId)
              ? FleetChatPeerState.pending
              : FleetChatPeerState.noSession;
        }
      }
      final targets = <String>[];
      var changed = false;
      for (final entry in msg.peerStates.entries) {
        final state = entry.value;
        if (state == FleetChatPeerState.acked) continue;
        if (state == FleetChatPeerState.gone) continue;
        if (sessions.containsKey(entry.key)) {
          if (state != FleetChatPeerState.pending) {
            msg.peerStates[entry.key] = FleetChatPeerState.pending;
            changed = true;
          }
          targets.add(entry.key);
        } else if (state != FleetChatPeerState.noSession) {
          msg.peerStates[entry.key] = FleetChatPeerState.noSession;
          changed = true;
        }
      }
      if (targets.isEmpty && !changed) return;
      if (targets.isNotEmpty) {
        _enqueueJob(_ChatJob(message: msg, targets: targets));
      }
      _pending[msg.id] = _PendingChat(
        message: msg,
        nextRetryAt:
            _now().add(Duration(seconds: fleetChatRetryDelaysSec[0])),
      );
      _notify();
    } catch (_) {}
  }

  /// Handle one hub datagram's text (registered with NodeUdpHub in
  /// [start]; tests call it directly). Only `fleet_data` envelopes
  /// are touched; everything else is left for the hub's other
  /// listeners. Decrypts under the sender's pairwise session key
  /// and routes the inner JSON to the chat or ack handler. A failed
  /// decrypt drops the datagram silently. Never throws.
  Future<void> handleHubText(String text) async {
    try {
      _maybeResetForFleet();
      final t = text.trim();
      if (!t.startsWith('{') || !t.contains('fleet_data')) return;
      final decoded = jsonDecode(t);
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['type'] != 'fleet_data') return;
      final fromNode = '${decoded['from_node'] ?? ''}';
      if (fromNode.isEmpty) return;
      final fleetId = _fleetIdFn();
      if (fleetId == null) return;
      // Not in a fleet (stale fleet id, record already forgotten):
      // ignore chat datagrams. The fleet-id check above covers the
      // normal case; this is the belt to its braces.
      if (!_inFleetFn()) return;
      final session = _sessionsFn()[fromNode];
      if (session == null) return;
      final ownId = await _ownNodeId();
      if (ownId == null || fromNode == ownId) return;
      final inner = await fleetDecryptEnvelope(
        decoded,
        sessionKey: session,
        expectedFleetId: fleetId,
        seenNonces: _seenNonces,
      );
      if (inner == null) return;
      if (_seenNonces.length > 4096) _seenNonces.clear();
      final innerDecoded = jsonDecode(inner);
      if (innerDecoded is! Map<String, dynamic>) return;
      final type = '${innerDecoded['type'] ?? ''}';
      if (type == 'fleet_chat') {
        await _handleChat(innerDecoded, fromNode);
      } else if (type == 'fleet_chat_ack') {
        _handleAck(innerDecoded, fromNode);
      }
      // Anything else inside the envelope is sensor data — the
      // fleet service's job, not chat's.
    } catch (_) {}
  }

  /// Test hook: run one pump cycle (one queued job + due retries).
  /// The 500 ms timer calls the same code in production.
  @visibleForTesting
  Future<void> pumpForTest() => _pump();

  /// Test hook: messages with retries still scheduled.
  @visibleForTesting
  int get pendingCountForTest => _pending.length;

  /// Test hook: queued fan-out jobs.
  @visibleForTesting
  int get queueLengthForTest => _queue.length;

  /// Test hook: seen inbound message ids.
  @visibleForTesting
  int get seenIdsForTest => _seenIds.length;

  Future<String?> _ownNodeId() async {
    final cached = _ownNodeIdCache;
    if (cached != null) return cached;
    try {
      final id = await _ownNodeIdFn();
      _ownNodeIdCache = id;
      return id;
    } catch (_) {
      return null;
    }
  }

  FleetChatMessage _fileOutgoing({
    required String threadId,
    required String fromNode,
    required String text,
    required Map<String, FleetChatPeerState> peerStates,
  }) {
    final seq = (_seq[threadId] ?? 0) + 1;
    _seq[threadId] = seq;
    final msg = FleetChatMessage(
      id: fleetChatRandomId(),
      threadId: threadId,
      fromNode: fromNode,
      fromCallsign: _ownCallsign(),
      text: text,
      sentAt: _now(),
      seq: seq,
      outgoing: true,
      peerStates: peerStates,
    );
    final list = _threads.putIfAbsent(threadId, () => []);
    list.add(msg);
    if (list.length > fleetChatMaxHistoryPerThread) {
      list.removeRange(0, list.length - fleetChatMaxHistoryPerThread);
    }
    return msg;
  }

  void _enqueueJob(_ChatJob job) {
    _queue.add(job);
  }

  Future<void> _pump() async {
    if (_disposed || !_started) return;
    final now = _now();
    // One queued fan-out per 500 ms window.
    if (_queue.isNotEmpty &&
        (_lastSendAt == null ||
            now.difference(_lastSendAt!).inMilliseconds >=
                fleetChatOutboundMinGapMs)) {
      final job = _queue.removeAt(0);
      _lastSendAt = now;
      await _runJob(job);
    }
    // Retries due.
    for (final entry in _pending.values.toList()) {
      if (_disposed) return;
      final msg = entry.message;
      if (now.isBefore(entry.nextRetryAt)) continue;
      // A job for this message is already queued (the initial
      // fan-out is still waiting on the 500 ms pacing): the queue
      // owns it — do not stack a second job for the same message.
      // Re-check after the pacing window. This also keeps a rapid
      // burst of sends from duplicating itself: without it, every
      // message still queued when its retry timer fires at +2 s
      // would get a second copy in the queue.
      if (_queue.any((j) => identical(j.message, msg))) {
        entry.nextRetryAt = now.add(const Duration(
            milliseconds: fleetChatOutboundMinGapMs));
        continue;
      }
      if (entry.attemptsSent >= 1 + fleetChatMaxRetries) {
        // Retries exhausted: pending peers fail; no-session peers
        // keep their (honest) state. The message leaves the
        // pending set and its overall state goes final.
        var changed = false;
        for (final e in msg.peerStates.entries) {
          if (e.value == FleetChatPeerState.pending) {
            msg.peerStates[e.key] = FleetChatPeerState.failed;
            changed = true;
          }
        }
        _pending.remove(msg.id);
        if (changed) _notify();
        continue;
      }
      // Re-evaluate targets: peers that left are gone; peers whose
      // exchange has since completed get another chance.
      final peersNow = {for (final p in _peersFn()) p.nodeId};
      final sessionsNow = _sessionsFn();
      final targets = <String>[];
      var changed = false;
      for (final e in msg.peerStates.entries) {
        final state = e.value;
        if (state == FleetChatPeerState.acked) continue;
        if (!peersNow.contains(e.key)) {
          if (state != FleetChatPeerState.gone) {
            msg.peerStates[e.key] = FleetChatPeerState.gone;
            changed = true;
          }
          continue;
        }
        if (sessionsNow.containsKey(e.key)) {
          if (state != FleetChatPeerState.pending) {
            msg.peerStates[e.key] = FleetChatPeerState.pending;
            changed = true;
          }
          targets.add(e.key);
        } else if (state != FleetChatPeerState.noSession) {
          msg.peerStates[e.key] = FleetChatPeerState.noSession;
          changed = true;
        }
      }
      if (targets.isNotEmpty) {
        _enqueueJob(_ChatJob(message: msg, targets: targets));
      }
      entry.attemptsSent++;
      if (entry.attemptsSent < 1 + fleetChatMaxRetries) {
        entry.nextRetryAt = now.add(Duration(
            seconds: fleetChatRetryDelaysSec[entry.attemptsSent - 1]));
      }
      // Peers that left while retries were pending finish the
      // message immediately instead of waiting out the retry
      // schedule (a peer still no-session keeps it scheduled).
      _maybeFinishPending(msg);
      if (changed) _notify();
    }
  }

  Future<void> _runJob(_ChatJob job) async {
    final msg = job.message;
    final fleetId = _fleetIdFn();
    if (fleetId == null) return;
    final ownId = await _ownNodeId();
    if (ownId == null) return;
    final channel =
        fleetChatIsDmThread(msg.threadId) ? 'dm' : 'fleet';
    var sentAny = false;
    for (final nodeId in job.targets) {
      try {
        final session = _sessionsFn()[nodeId];
        if (session == null) {
          if (msg.peerStates[nodeId] != FleetChatPeerState.noSession) {
            msg.peerStates[nodeId] = FleetChatPeerState.noSession;
          }
          continue;
        }
        final inner = fleetChatMessageToJson(
          msgId: msg.id,
          channel: channel,
          toNode: channel == 'dm' ? nodeId : null,
          fromNode: ownId,
          fromCallsign: _ownCallsign(),
          seq: msg.seq,
          tMs: msg.sentAt.millisecondsSinceEpoch,
          text: msg.text,
        );
        final envelope = await fleetEncryptEnvelope(
          sessionKey: session,
          fleetId: fleetId,
          fromNode: ownId,
          innerJson: inner,
        );
        final peer = _peersFn()
            .where((p) => p.nodeId == nodeId)
            .firstOrNull;
        if (peer == null) {
          msg.peerStates[nodeId] = FleetChatPeerState.gone;
          continue;
        }
        await _sendEnvelope(envelope, peer.address);
        sentAny = true;
        if (msg.peerStates[nodeId] != FleetChatPeerState.acked) {
          msg.peerStates[nodeId] = FleetChatPeerState.pending;
        }
      } catch (_) {
        msg.peerStates[nodeId] = FleetChatPeerState.failed;
      }
    }
    // The retry clock starts at the actual first send, not at
    // filing time — a message that sat in the queue behind a burst
    // gets its full 2 s before the first retry is due.
    final pending = _pending[msg.id];
    if (sentAny && pending != null && !pending.sent) {
      pending.sent = true;
      pending.nextRetryAt =
          _now().add(Duration(seconds: fleetChatRetryDelaysSec[0]));
    }
    _maybeFinishPending(msg);
    _notify();
  }

  /// A message leaves the pending set when no peer is pending or
  /// no-session any more (acked / failed / gone are terminal).
  void _maybeFinishPending(FleetChatMessage msg) {
    if (!_pending.containsKey(msg.id)) return;
    final open = msg.peerStates.values.any((s) =>
        s == FleetChatPeerState.pending ||
        s == FleetChatPeerState.noSession);
    if (!open) _pending.remove(msg.id);
  }

  Future<void> _handleChat(
      Map<String, dynamic> inner, String envelopeFrom) async {
    final ownId = await _ownNodeId();
    if (ownId == null) return;
    final msg = fleetChatMessageTryParse(inner, ourNodeId: ownId);
    if (msg == null) return;
    if (msg.fromNode != envelopeFrom) return;
    if (!_inboundOk(msg.fromNode)) return;
    if (_seenIds.contains(msg.id)) {
      // Duplicate (a retry whose first copy already landed):
      // ack again so the sender's state stays correct, but never
      // display twice.
      await _sendAck(msg);
      return;
    }
    _seenIds.add(msg.id);
    while (_seenIds.length > fleetChatMaxSeenIds) {
      _seenIds.remove(_seenIds.first);
    }
    final list = _threads.putIfAbsent(msg.threadId, () => []);
    list.add(msg);
    if (list.length > fleetChatMaxHistoryPerThread) {
      list.removeRange(0, list.length - fleetChatMaxHistoryPerThread);
    }
    if (_openThread != msg.threadId) {
      _unread[msg.threadId] = (_unread[msg.threadId] ?? 0) + 1;
    }
    await _sendAck(msg);
    _notify();
  }

  void _handleAck(Map<String, dynamic> inner, String envelopeFrom) {
    final ack = fleetChatAckTryParse(inner);
    if (ack == null) return;
    if (ack.fromNode != envelopeFrom) return;
    final threadId = ack.channel == 'fleet'
        ? fleetChatThreadFleet
        : fleetChatDmThread(ack.fromNode);
    final list = _threads[threadId];
    if (list == null) return;
    for (var i = list.length - 1; i >= 0; i--) {
      final m = list[i];
      if (m.id != ack.msgId || !m.outgoing) continue;
      final state = m.peerStates[ack.fromNode];
      if (state == null || state == FleetChatPeerState.acked) return;
      m.peerStates[ack.fromNode] = FleetChatPeerState.acked;
      _maybeFinishPending(m);
      _notify();
      return;
    }
  }

  /// Inbound per-peer rate cap: at most
  /// [fleetChatInboundPerPeerPerMin] messages per minute from one
  /// peer. Beyond that the message is dropped silently (and not
  /// acked). Never throws.
  bool _inboundOk(String fromNode) {
    try {
      final now = _now();
      final w = _inbound[fromNode];
      if (w == null) {
        _inbound[fromNode] = _InboundWindow(windowStart: now, count: 1);
        return true;
      }
      if (now.difference(w.windowStart) >= const Duration(minutes: 1)) {
        w.windowStart = now;
        w.count = 1;
        return true;
      }
      if (w.count >= fleetChatInboundPerPeerPerMin) return false;
      w.count++;
      return true;
    } catch (_) {
      return true;
    }
  }

  /// Send one ack for a received message, best-effort, no retry.
  /// Skipped when the sender has no session or is not addressable
  /// any more. Never throws.
  Future<void> _sendAck(FleetChatMessage msg) async {
    try {
      final fleetId = _fleetIdFn();
      if (fleetId == null) return;
      final ownId = await _ownNodeId();
      if (ownId == null) return;
      final session = _sessionsFn()[msg.fromNode];
      if (session == null) return;
      final peer =
          _peersFn().where((p) => p.nodeId == msg.fromNode).firstOrNull;
      if (peer == null) return;
      final channel =
          fleetChatIsDmThread(msg.threadId) ? 'dm' : 'fleet';
      final ack = fleetChatAckToJson(
        msgId: msg.id,
        channel: channel,
        fromNode: ownId,
        tMs: _now().millisecondsSinceEpoch,
      );
      final envelope = await fleetEncryptEnvelope(
        sessionKey: session,
        fleetId: fleetId,
        fromNode: ownId,
        innerJson: ack,
      );
      await _sendEnvelope(envelope, peer.address);
    } catch (_) {}
  }

  Future<void> _sendEnvelope(
      Map<String, dynamic> envelope, String address) async {
    final override = _sendEnvelopeOverride;
    if (override != null) {
      await override(envelope, address);
      return;
    }
    final sock = await _sendSocketFor();
    final bytes = utf8.encode(jsonEncode(envelope));
    sock.send(bytes, InternetAddress(address), NodeUdpHub.port);
  }

  Future<RawDatagramSocket> _sendSocketFor() async {
    final cur = _sendSocket;
    if (cur != null) return cur;
    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _sendSocket = sock;
    return sock;
  }

  void _notify() {
    if (_disposed) return;
    _onChanged?.call();
  }
}

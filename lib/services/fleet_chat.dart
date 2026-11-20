/// Fleet chat — pure wire codec + message model for Outride fleet
/// text chat (design note: `research_notes/outride-fleet-chat.md`).
///
/// No I/O, no clock, no Flutter imports: every function here is
/// unit-testable in isolation. The transport lives in
/// `fleet_chat_service.dart`; this file is the message and its
/// encoding only.
///
/// Wire: chat travels as an inner JSON message inside the existing
/// encrypted `fleet_data` envelope on UDP 49160 — the same envelope
/// the sensor peer-data path uses. Two inner types:
///
///   `fleet_chat`     — one chat message (fleet channel or DM)
///   `fleet_chat_ack` — delivery acknowledgement for one message
///
/// CoT chat (`b-t-f` GeoChat) was evaluated and rejected for v1:
/// CoT multicast is plaintext, so it would leak chat content to
/// every CoT listener on the segment, and the app has no CoT chat
/// parser. ATAK interop is a gateway-translation follow-up, outside
/// the fleet.
library fleet_chat;

import 'dart:math';

/// Thread id of the shared fleet channel. Every fleet message goes
/// to all team members; there is no per-peer thread for the channel.
const String fleetChatThreadFleet = 'fleet';

/// Thread id of a 1:1 DM thread with [peerNodeId] (16 hex chars).
String fleetChatDmThread(String peerNodeId) => 'dm:$peerNodeId';

/// True when [threadId] names a DM thread (vs the fleet channel).
bool fleetChatIsDmThread(String threadId) => threadId.startsWith('dm:');

/// The peer node id of a DM thread id, or null for the fleet channel.
String? fleetChatDmPeer(String threadId) {
  if (!fleetChatIsDmThread(threadId)) return null;
  final peer = threadId.substring(3);
  return peer.isEmpty ? null : peer;
}

/// Maximum message text, in characters. A datagram budget, not a
/// UI choice: the hub drops received datagrams over 16,384 bytes,
/// and a 1000-character message stays inside it with margin even
/// at 4 UTF-8 bytes per character after JSON escaping + base64
/// (~8.2 KB worst case). See the design note §4.
const int fleetChatMaxTextLength = 1000;

/// Messages kept per thread, in memory. Oldest dropped first.
/// History is lost on restart in v1 (design note §6).
const int fleetChatMaxHistoryPerThread = 200;

/// Seen message ids kept for dedup, oldest evicted first.
/// Ids are 128-bit random, so the bound is a memory cap, not a
/// correctness limit.
const int fleetChatMaxSeenIds = 1000;

/// Automatic retries after the first send attempt.
const int fleetChatMaxRetries = 3;

/// Retry delays in seconds, by attempt (attempt 1 at 2 s, 2 at 4 s,
/// 3 at 8 s). A retry reuses the message id (dedup) with a fresh
/// GCM nonce each time (so the fleet replay set does not drop it).
const List<int> fleetChatRetryDelaysSec = <int>[2, 4, 8];

/// Minimum gap between one message's fan-out and the next, in
/// milliseconds. A small send queue paces faster taps.
const int fleetChatOutboundMinGapMs = 500;

/// Most messages waiting in the outbound queue. Beyond this a send
/// is rejected with a plain-words reason instead of growing a
/// backlog nobody will read.
const int fleetChatOutboundQueueMax = 10;

/// Most inbound messages accepted from one peer per minute.
/// Beyond this the peer's messages are dropped silently without
/// an ack (the hub's 2000-datagrams/s flood guard still applies
/// on top).
const int fleetChatInboundPerPeerPerMin = 30;

/// Delivery state of one outgoing message for one peer.
enum FleetChatPeerState {
  /// Sent, awaiting the peer's ack.
  pending,

  /// The peer acked receipt (delivered to their device, not read).
  acked,

  /// Retries exhausted without an ack.
  failed,

  /// No session key with this peer yet (exchange still in flight).
  /// A retry after the exchange completes can succeed.
  noSession,

  /// The peer left the fleet while the message was in flight.
  gone,
}

/// Delivery state of one outgoing message overall, derived from
/// its per-peer states.
enum FleetChatOverall {
  /// At least one peer still pending.
  sending,

  /// Every peer acked.
  sent,

  /// Some peers acked, the rest terminally failed.
  partial,

  /// No peer acked and every peer is terminally failed — including
  /// zero peers at send time.
  failed,
}

/// Derive the overall delivery state from per-peer states.
/// Pure and unit-tested: empty ⇒ failed; all acked ⇒ sent; any
/// pending ⇒ sending (retries may still land); some acked and the
/// rest terminal ⇒ partial; none acked and none pending ⇒ failed.
FleetChatOverall fleetChatOverall(
    Map<String, FleetChatPeerState> peerStates) {
  if (peerStates.isEmpty) return FleetChatOverall.failed;
  final values = peerStates.values.toSet();
  if (values.length == 1 &&
      values.contains(FleetChatPeerState.acked)) {
    return FleetChatOverall.sent;
  }
  if (values.contains(FleetChatPeerState.pending)) {
    return FleetChatOverall.sending;
  }
  if (values.contains(FleetChatPeerState.acked)) {
    return FleetChatOverall.partial;
  }
  return FleetChatOverall.failed;
}

/// One chat message, in either direction.
///
/// Outgoing messages carry their per-peer delivery states (empty
/// for incoming messages). Messages are immutable except for
/// [peerStates], which the service updates as acks arrive — the
/// map itself is the same object the UI already holds, so the
/// service notifies listeners after mutating it.
class FleetChatMessage {
  const FleetChatMessage({
    required this.id,
    required this.threadId,
    required this.fromNode,
    required this.fromCallsign,
    required this.text,
    required this.sentAt,
    required this.seq,
    required this.outgoing,
    Map<String, FleetChatPeerState>? peerStates,
  }) : peerStates = peerStates ?? const {};

  /// 32 lowercase hex chars (128-bit random).
  final String id;

  /// `'fleet'`, or `'dm:<peer node id>'`.
  final String threadId;

  /// Sender's stable node id (16 hex chars).
  final String fromNode;

  /// Sender's callsign at send time (self-asserted; shown with
  /// the short node id so two EUDs claiming one callsign are
  /// distinguishable).
  final String fromCallsign;

  final String text;

  /// Sender's wall clock at send time — indicative, not
  /// authoritative (fleet clocks tolerate 30 s of skew).
  final DateTime sentAt;

  /// Per-sender, per-thread incrementing sequence (in-memory,
  /// from 1). Display order is arrival order; `seq` exists so a
  /// future version can order deterministically.
  final int seq;

  final bool outgoing;

  /// Per-peer delivery states (outgoing only; empty when incoming).
  /// Mutable by design — see the class doc.
  final Map<String, FleetChatPeerState> peerStates;

  /// Overall delivery state (incoming messages are always
  /// received, so this is meaningful for outgoing only).
  FleetChatOverall get overall => fleetChatOverall(peerStates);

  /// Short node id for display (`abc123`).
  String get shortFrom =>
      fromNode.length >= 6 ? fromNode.substring(0, 6) : fromNode;

  /// `HH:MM` local time for display.
  String get timeLabel {
    final t = sentAt.toLocal();
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

/// 128-bit random message id as 32 lowercase hex chars.
String fleetChatRandomId() {
  final r = Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Text validation for an outbound message: non-empty after
/// trimming, at most [fleetChatMaxTextLength] characters.
/// Returns a plain-words rejection reason, or null when the text
/// is sendable. Never throws.
String? fleetChatTextError(String text) {
  if (text.trim().isEmpty) return 'EMPTY MESSAGE';
  if (text.length > fleetChatMaxTextLength) {
    return 'TOO LONG ($fleetChatMaxTextLength CHARACTERS MAX)';
  }
  return null;
}

/// Build the inner JSON for one chat message (the plaintext that
/// goes inside the encrypted `fleet_data` envelope). [toNode] is
/// set only for DMs.
Map<String, dynamic> fleetChatMessageToJson({
  required String msgId,
  required String channel,
  String? toNode,
  required String fromNode,
  required String fromCallsign,
  required int seq,
  required int tMs,
  required String text,
}) {
  final j = <String, dynamic>{
    'type': 'fleet_chat',
    'v': 1,
    'msg_id': msgId,
    'channel': channel,
    'from_node': fromNode,
    'from_callsign': fromCallsign,
    'seq': seq,
    't': tMs,
    'text': text,
  };
  if (toNode != null) j['to_node'] = toNode;
  return j;
}

/// Strict parse of an inner `fleet_chat` JSON object. Returns null
/// for any malformed input — wrong type / version, bad ids, a DM
/// not addressed to us, empty or over-long text, bad timestamp or
/// sequence. Never throws. Unknown fields are ignored.
///
/// [ourNodeId] is this device's node id: a DM is accepted only
/// when its `to_node` equals it. Fleet-channel messages carry no
/// `to_node` and are accepted for any member.
FleetChatMessage? fleetChatMessageTryParse(
  Map<String, dynamic> j, {
  required String ourNodeId,
}) {
  try {
    if (j['type'] != 'fleet_chat') return null;
    if (j['v'] != 1) return null;
    final msgId = '${j['msg_id'] ?? ''}';
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(msgId)) return null;
    final channel = '${j['channel'] ?? ''}';
    if (channel != 'fleet' && channel != 'dm') return null;
    final fromNode = '${j['from_node'] ?? ''}';
    if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(fromNode)) return null;
    if (fromNode == ourNodeId) return null; // our own, looped back
    final fromCallsign = '${j['from_callsign'] ?? ''}';
    if (fromCallsign.isEmpty) return null;
    String threadId;
    if (channel == 'dm') {
      final toNode = '${j['to_node'] ?? ''}';
      if (toNode != ourNodeId) return null; // not for us
      threadId = fleetChatDmThread(fromNode);
    } else {
      // A fleet message must not carry to_node: a sender that
      // puts one on a broadcast is buggy or probing.
      if (j.containsKey('to_node')) return null;
      threadId = fleetChatThreadFleet;
    }
    final text = '${j['text'] ?? ''}';
    if (text.isEmpty || text.length > fleetChatMaxTextLength) {
      return null;
    }
    final t = j['t'];
    if (t is! num || !t.isFinite || t < 0) return null;
    final seq = j['seq'];
    if (seq is! num || seq < 1) return null;
    return FleetChatMessage(
      id: msgId,
      threadId: threadId,
      fromNode: fromNode,
      fromCallsign: fromCallsign,
      text: text,
      sentAt: DateTime.fromMillisecondsSinceEpoch(t.toInt()),
      seq: seq.toInt(),
      outgoing: false,
    );
  } catch (_) {
    return null;
  }
}

/// Build the inner JSON for one delivery ack. The ack echoes the
/// original message's channel so the sender files it in the right
/// thread. Acks are best-effort with no retry of their own.
Map<String, dynamic> fleetChatAckToJson({
  required String msgId,
  required String channel,
  required String fromNode,
  required int tMs,
}) =>
    <String, dynamic>{
      'type': 'fleet_chat_ack',
      'v': 1,
      'msg_id': msgId,
      'channel': channel,
      'from_node': fromNode,
      't': tMs,
    };

/// A parsed ack: (message id, channel, acking peer node id).
/// Returns null for any malformed input. Never throws.
({String msgId, String channel, String fromNode})?
    fleetChatAckTryParse(Map<String, dynamic> j) {
  try {
    if (j['type'] != 'fleet_chat_ack') return null;
    if (j['v'] != 1) return null;
    final msgId = '${j['msg_id'] ?? ''}';
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(msgId)) return null;
    final channel = '${j['channel'] ?? ''}';
    if (channel != 'fleet' && channel != 'dm') return null;
    final fromNode = '${j['from_node'] ?? ''}';
    if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(fromNode)) return null;
    return (msgId: msgId, channel: channel, fromNode: fromNode);
  } catch (_) {
    return null;
  }
}

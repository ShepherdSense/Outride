/// Fleet chat screen — text chat over the auto-mesh (EXPERIMENTAL).
///
/// Design note: `research_notes/outride-fleet-chat.md`. Two modes:
/// the fleet channel (every message out to all team members) and
/// 1:1 DMs (tap a team member to open their thread). Reached from
/// the Fleet screen — never a bottom-nav destination (the
/// restructure is Picture / Sensors / Settings only).
///
/// The screen owns no state of its own beyond which thread is
/// open; messages, delivery states, and unread counts live in
/// `FleetChatService` via `AppState`. History is in-memory only
/// and is lost on restart (v1).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/fleet_chat.dart';
import '../services/fleet_service.dart';
import '../state/app_state.dart';
import '../theme.dart';

class FleetChatScreen extends StatefulWidget {
  const FleetChatScreen({
    super.key,
    required this.state,
    this.initialDmPeer,
  });

  final AppState state;

  /// Peer node id to open a DM thread with on entry (tap a team
  /// member on the Fleet screen). Null opens the thread list.
  final String? initialDmPeer;

  @override
  State<FleetChatScreen> createState() => _FleetChatScreenState();
}

class _FleetChatScreenState extends State<FleetChatScreen> {
  /// Open thread id, or null for the thread list.
  String? _threadId;
  final TextEditingController _composer = TextEditingController();
  final ScrollController _scroll = ScrollController();
  String? _sendError;
  int _lastMessageCount = 0;

  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    unawaited(_state.startFleetChat());
    final peer = widget.initialDmPeer;
    if (peer != null) {
      _threadId = fleetChatDmThread(peer);
      _state.openChatThread(_threadId);
    }
  }

  @override
  void dispose() {
    _state.openChatThread(null);
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _openThread(String threadId) {
    setState(() {
      _threadId = threadId;
      _lastMessageCount = 0;
    });
    _state.openChatThread(threadId);
  }

  void _backToList() {
    setState(() => _threadId = null);
    _state.openChatThread(null);
  }

  Future<void> _send() async {
    final text = _composer.text;
    if (text.trim().isEmpty) return;
    final threadId = _threadId;
    if (threadId == null) return;
    setState(() => _sendError = null);
    final result = fleetChatIsDmThread(threadId)
        ? await _state.sendDmChatMessage(
            fleetChatDmPeer(threadId)!, text)
        : await _state.sendFleetChatMessage(text);
    if (!mounted) return;
    if (result.ok) {
      _composer.clear();
      setState(() {});
    } else {
      setState(() => _sendError = result.reason ?? 'SEND FAILED');
    }
  }

  /// Keep the newest message in view: jump to the bottom after a
  /// rebuild that added messages to the open thread.
  void _maybeScrollToBottom(int count) {
    if (count == _lastMessageCount) return;
    _lastMessageCount = count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final threadId = _threadId;
    return Scaffold(
      appBar: AppBar(
        leading: threadId == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _backToList,
              ),
        title: Text(
          threadId == null
              ? 'FLEET CHAT'
              : threadId == fleetChatThreadFleet
                  ? 'FLEET CHANNEL'
                  : _dmTitle(threadId),
        ),
      ),
      body: PopScope(
        canPop: threadId == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _backToList();
        },
        child: ListenableBuilder(
          listenable: _state,
          builder: (context, _) {
            if (!_state.inFleet) {
              return _notInFleet();
            }
            if (threadId == null) return _threadList();
            return _threadView(threadId);
          },
        ),
      ),
    );
  }

  String _dmTitle(String threadId) {
    final peerId = fleetChatDmPeer(threadId);
    final peer = peerId == null
        ? null
        : _state.fleetPeers
            .where((p) => p.nodeId == peerId)
            .firstOrNull;
    return peer?.callsign ?? 'DM ${peerId?.substring(0, 6).toUpperCase() ?? ''}';
  }

  Widget _notInFleet() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: const [
        OutridePanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('NOT IN A FLEET',
                  style: TextStyle(
                      color: OutrideColors.muted, fontSize: 13)),
              SizedBox(height: 8),
              Text(
                'Join a fleet to chat. Fleet chat is encrypted '
                'between fleet members only — no cloud, no server.',
                style: TextStyle(
                    color: OutrideColors.muted, fontSize: 12),
              ),
            ],
          ),
        ),
        SizedBox(height: 12),
        Text('FLEET CHAT — EXPERIMENTAL',
            style: TextStyle(color: OutrideColors.muted, fontSize: 11)),
      ],
    );
  }

  Widget _threadList() {
    final peers = _state.fleetPeers;
    final channelMessages = _state.fleetChannelMessages;
    final channelUnread = _state.chatUnread(fleetChatThreadFleet);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const OutridePanel(
          child: Text(
            'FLEET CHAT — EXPERIMENTAL. Messages go only to fleet '
            'members, encrypted with each member\u2019s session key. '
            'History is on this device only and is lost on restart.',
            style: TextStyle(color: OutrideColors.muted, fontSize: 12),
          ),
        ),
        const SizedBox(height: 12),
        _sectionTitle('FLEET CHANNEL'),
        const SizedBox(height: 8),
        _threadRow(
          title: 'FLEET CHANNEL',
          subtitle: channelMessages.isEmpty
              ? 'No messages yet — say hi to the team.'
              : _preview(channelMessages.last),
          unread: channelUnread,
          onTap: () => _openThread(fleetChatThreadFleet),
        ),
        const SizedBox(height: 16),
        _sectionTitle('DIRECT MESSAGES'),
        const SizedBox(height: 8),
        if (peers.isEmpty)
          const Text(
            'No team members yet — other EUDs join by dialing the '
            'same 4-digit PIN.',
            style: TextStyle(color: OutrideColors.muted, fontSize: 12),
          ),
        for (final p in peers) ...[
          const SizedBox(height: 8),
          _dmRow(p),
        ],
      ],
    );
  }

  Widget _dmRow(FleetPeer p) {
    final threadId = fleetChatDmThread(p.nodeId);
    final messages = _state.dmMessages(p.nodeId);
    final unread = _state.chatUnread(threadId);
    return _threadRow(
      title: p.callsign,
      subtitle: messages.isEmpty
          ? '${p.roleLabel} · TAP TO MESSAGE'
          : _preview(messages.last),
      unread: unread,
      onTap: () => _openThread(threadId),
    );
  }

  Widget _threadRow({
    required String title,
    required String subtitle,
    required int unread,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: OutridePanel(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: OutrideType.rowValue(OutrideColors.onDark)),
                  const SizedBox(height: 4),
                  Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: OutrideColors.muted, fontSize: 12)),
                ],
              ),
            ),
            if (unread > 0) ...[
              const SizedBox(width: 8),
              OutrideChip(label: '$unread', color: OutrideColors.purple),
            ],
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, color: OutrideColors.purple),
          ],
        ),
      ),
    );
  }

  static String _preview(FleetChatMessage m) {
    final who = m.outgoing ? 'YOU' : m.fromCallsign;
    final text = m.text.replaceAll('\n', ' ');
    return '$who: $text';
  }

  Widget _threadView(String threadId) {
    final messages = fleetChatIsDmThread(threadId)
        ? _state.dmMessages(fleetChatDmPeer(threadId)!)
        : _state.fleetChannelMessages;
    _maybeScrollToBottom(messages.length);
    final sendError = _sendError;
    return Column(
      children: [
        Expanded(
          child: messages.isEmpty
              ? const Center(
                  child: Text(
                    'No messages yet.',
                    style: TextStyle(
                        color: OutrideColors.muted, fontSize: 12),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: messages.length,
                  itemBuilder: (context, i) =>
                      _messageRow(messages[i]),
                ),
        ),
        if (sendError != null)
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(sendError,
                style: const TextStyle(
                    color: OutrideColors.amber, fontSize: 12)),
          ),
        _composerRow(threadId),
      ],
    );
  }

  Widget _messageRow(FleetChatMessage m) {
    final own = m.outgoing;
    final bubble = OutridePanel(
      glow: own ? OutrideColors.green : null,
      child: Column(
        crossAxisAlignment:
            own ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (!own)
            Text('${m.fromCallsign} · ${m.shortFrom.toUpperCase()}',
                style: const TextStyle(
                    color: OutrideColors.muted, fontSize: 11)),
          if (!own) const SizedBox(height: 4),
          Text(m.text,
              style: const TextStyle(
                  color: OutrideColors.onDark, fontSize: 14)),
          const SizedBox(height: 4),
          Text(
            own ? '${m.timeLabel} · ${_deliveryLabel(m)}' : m.timeLabel,
            style: const TextStyle(
                color: OutrideColors.muted, fontSize: 11),
          ),
        ],
      ),
    );
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (own) const Spacer(),
        Flexible(flex: 4, child: bubble),
        if (!own) const Spacer(),
      ],
    );
    if (!own) return Padding(padding: const EdgeInsets.only(bottom: 8), child: row);
    final tappable = _state.fleetChatService.overallFor(m) ==
            FleetChatOverall.failed ||
        _state.fleetChatService.overallFor(m) ==
            FleetChatOverall.partial;
    final padded = Padding(padding: const EdgeInsets.only(bottom: 8), child: row);
    if (!tappable) return padded;
    return InkWell(
      onTap: () => _retry(m),
      child: padded,
    );
  }

  String _deliveryLabel(FleetChatMessage m) {
    final overall = _state.fleetChatService.overallFor(m);
    switch (overall) {
      case FleetChatOverall.sending:
        return 'SENDING…';
      case FleetChatOverall.sent:
        return 'SENT';
      case FleetChatOverall.partial:
        final acked = m.peerStates.values
            .where((s) => s == FleetChatPeerState.acked)
            .length;
        return 'SENT TO $acked OF ${m.peerStates.length} — TAP TO RETRY';
      case FleetChatOverall.failed:
        if (m.peerStates.values
            .any((s) => s == FleetChatPeerState.noSession)) {
          return 'NO SESSION — TAP TO RETRY';
        }
        return 'FAILED — TAP TO RETRY';
    }
  }

  Future<void> _retry(FleetChatMessage m) async {
    await _state.retryChatMessage(m.threadId, m.id);
    if (!mounted) return;
    setState(() {});
  }

  Widget _composerRow(String threadId) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: const BoxDecoration(
        color: OutrideColors.surface,
        border: Border(top: BorderSide(color: OutrideColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _composer,
              maxLines: 4,
              minLines: 1,
              maxLength: fleetChatMaxTextLength,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(color: OutrideColors.onDark),
              decoration: const InputDecoration(
                hintText: 'Message the team…',
                hintStyle: TextStyle(color: OutrideColors.muted),
                counterText: '',
                border: InputBorder.none,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.send, color: OutrideColors.purple),
            onPressed:
                _composer.text.trim().isEmpty ? null : () => _send(),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) =>
      Text(title, style: OutrideType.section());
}

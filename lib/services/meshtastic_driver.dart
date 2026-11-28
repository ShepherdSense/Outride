import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/link_sample.dart';
import 'meshtastic_link_series.dart';
import 'meshtastic_mesh_config.dart';
import 'meshtastic_proto.dart';
import 'meshtastic_probe.dart';
import 'radio_driver.dart';

/// Meshtastic LoRa-mesh driver.
///
/// DESIGN DECISION — RX-only stance CHANGED (2026-11-28, improvement
/// #2; see also `docs/meshtastic_driver_spec.md` and
/// `docs/meshtastic_hygiene_config.md`): this driver historically
/// never transmitted on the mesh. It still does NOT transmit by
/// default. When the operator explicitly opts in to probing
/// ([MeshtasticProbeSender.enabled]), Outride transmits normal
/// Meshtastic broadcast packets on OUR OWN channel via the local
/// node's client API — a link-report on private portnum 300. That is
/// legitimate operation of our own mesh, not an attack; nothing here
/// jams, deauths, spoofs, or touches any other network. The probe
/// sender lives in `meshtastic_probe.dart` and is OFF by default.
///
/// Connects to a Meshtastic node's client API on TCP port 4403,
/// performs the `want_config` handshake, and maintains the mesh's
/// NodeDB: per-node GPS position, last-heard SNR/RSSI, and neighbor
/// edges (from the NeighborInfo module when the mesh broadcasts it).
///
/// What Outride gets from this:
/// - every mesh node on the map (GPS → node position, auto-placed)
/// - per-packet link samples: EVERY received MeshPacket is logged
///   into [linkSeries] as sender → our node, with `rx_snr`,
///   `rx_rssi`, timestamp, hop count, and portnum — a per-edge time
///   series, not just last-heard SNR
/// - coarse link-health samples: `meshtastic:local → meshtastic:!<id>`
///   (SNR/RSSI at which OUR node heard that node) and
///   `meshtastic:!<a> → meshtastic:!<b>` (neighbor edges with SNR)
/// - channel-utilization telemetry (ChUtil / AirUtil, portnum 67)
///
/// HONEST SCOPE: Meshtastic telemetry is coarse — positions update on
/// the mesh's own slow cadence (often minutes) and per-packet SNR/RSSI
/// is a single number per packet, not a fast disturbance signal. A
/// step change in the series is CONSISTENT WITH a link disturbance,
/// never proof of one. This driver gives you node presence,
/// node-loss, and coarse link health. It is NOT tripwire-grade
/// sensing; fine disturbance detection is the job of the SX1276 LoRa
/// backhaul nodes (field_kit/esp32/lora_node), whose events arrive
/// as proper tripwire links.
///
/// Protocol notes (meshtastic/protobufs, verified against mesh.proto,
/// telemetry.proto, mqtt.proto, toradio.proto on 2026-11-28):
/// TCP framing is 4 bytes [0x94, 0xC3, lenMSB, lenLSB] + protobuf.
/// Client → radio: ToRadio; radio → client: FromRadio. On connect we
/// send ToRadio{want_config_id} and the radio streams its NodeDB as
/// FromRadio{node_info} packets, then live MeshPackets. Protobuf is
/// decoded by the SHARED minimal wire reader in
/// `meshtastic_proto.dart` ([MeshProtoReader]) — the driver used to
/// carry its own private copy, which is how the len-0 bug existed
/// in two places at once (FIX, review 2026-11-28, small item:
/// unified onto the shared reader; there is now one reader).
/// FromRadio{packet=2,my_info=3,node_info=4},
/// MyNodeInfo{my_node_num=1}, NodeInfo{num=1,position=3,snr=4,
/// device_metrics=6}, Position{latitude_i=1,longitude_i=2
/// (sfixed32, x1e-7 deg)},
/// MeshPacket{from=1,to=2,decoded=4,rx_snr=8 float,hop_limit=9
/// varint,rx_rssi=12 int32 varint,hop_start=15 varint},
/// Data{portnum=1,payload=2},
/// Telemetry{device_metrics=2},
/// DeviceMetrics{channel_utilization=3 float,air_util_tx=4 float},
/// NeighborInfo{neighbors=4} / Neighbor{node_id=1,snr=2},
/// NEIGHBORINFO_APP portnum = 71, TELEMETRY_APP portnum = 67,
/// Outride probe portnum = 300 (private range 256-511).
/// CORRECTION: `rx_rssi` is field 12, NOT field 9 (field 9 is
/// hop_limit — the deep-dive report got this wrong). `rx_rssi` is
/// int32 varint: negatives arrive sign-extended (10 bytes); the
/// reader sign-extends from 32 bits.
class MeshtasticDriver extends RadioDriver {
  MeshtasticDriver({
    required this.host,
    required this.port,
    MeshLinkSeries? linkSeries,
    this.meshConfig,
  }) : linkSeries = linkSeries ?? MeshLinkSeries();

  /// The per-edge link time series every received packet feeds.
  /// Shared with the MQTT tap when the app wires both to one store.
  /// Public on purpose (review 2026-11-28, item 16): the bench
  /// reads the series through this field — `driver.linkSeries` —
  /// so the package is exercisable without settings UI or app wiring.
  final MeshLinkSeries linkSeries;

  /// Locked mesh config, when the app supplies one. Its
  /// [MeshtasticMeshConfig.authenticated] (AEAD authenticates, or
  /// STRICT signing without AEAD) decides whether emitted
  /// [LinkSample]s are marked authenticated; false (default) means
  /// UNTRUSTED fusion input.
  final MeshtasticMeshConfig? meshConfig;

  /// True when this channel counts as authenticated (AEAD, or
  /// STRICT signing). Default false = untrusted.
  bool get authenticated => meshConfig?.authenticated ?? false;

  /// Packets / payloads that arrived but could not be decoded
  /// (malformed probe reports; corrupt frame lengths). Counted and
  /// surfaced, never silently dropped without a trace — matches
  /// the MQTT tap's `malformedCount` (FIX, review small item).
  int malformedCount = 0;

  /// Our local node's number, once `FromRadio.my_info` arrives.
  /// 0 = not yet learned; series edges to the local node use
  /// [MeshLinkSeries.localNode] (0) until then.
  int get localNodeNum => _localNodeNum;
  int _localNodeNum = 0;

  /// Latest channel-utilization telemetry per node (ChUtil/AirUtil).
  final MeshChannelUtilization channelUtilization =
      MeshChannelUtilization();

  factory MeshtasticDriver.fromAddress(String address) {
    var addr = address.trim();
    if (addr.toLowerCase().startsWith('serial:')) {
      throw ArgumentError(
        'USB serial needs a TCP bridge: run the Meshtastic serial-to-TCP '
        'bridge on the PC (e.g. `meshtastic --tcp-bridge`), then add the '
        'bridge address here. Raw serial ports are not opened directly.',
      );
    }
    var host = '127.0.0.1';
    var port = 4403;
    if (addr.isNotEmpty) {
      // Strip scheme if the user pasted a URL.
      final scheme = addr.indexOf('://');
      if (scheme >= 0) addr = addr.substring(scheme + 3);
      final i = addr.lastIndexOf(':');
      if (i > 0 && !addr.endsWith(']')) {
        host = addr.substring(0, i);
        port = int.tryParse(addr.substring(i + 1)) ?? port;
      } else {
        host = addr;
      }
    }
    return MeshtasticDriver(host: host, port: port);
  }

  final String host;
  final int port;

  /// Node number → mesh state.
  final Map<int, _MeshNode> _nodes = {};

  Socket? _socket;
  final BytesBuilder _inbox = BytesBuilder();
  bool _configRequested = false;

  /// Outride node ID for a Meshtastic node number: the `!` + 8-hex
  /// convention from the Meshtastic ecosystem (e.g. `!a1b2c3d4`).
  static String nodeIdOf(int num) =>
      'meshtastic:!${num.toRadixString(16).padLeft(8, '0')}';

  /// GPS positions for map placement, keyed by Outride node ID.
  Map<String, ({double lat, double lon})> meshPositions() {
    final out = <String, ({double lat, double lon})>{};
    for (final n in _nodes.values) {
      if (n.lat != null && n.lon != null) {
        out[nodeIdOf(n.num)] = (lat: n.lat!, lon: n.lon!);
      }
    }
    return out;
  }

  @override
  String get driverId => 'meshtastic';

  @override
  String get label => 'MESHTASTIC';

  @override
  bool get isImplemented => true;

  @override
  String get emptyHint =>
      'No Meshtastic nodes seen — is a node reachable at $host:$port?';

  /// Meshtastic telemetry moves on the mesh's own slow cadence
  /// (minutes); don't treat a few-minute-old SNR as dead evidence.
  @override
  Duration? get sampleMaxAge => const Duration(minutes: 15);

  Future<void> _ensureConnected() async {
    if (_socket != null) return;
    final s = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 5),
    );
    s.setOption(SocketOption.tcpNoDelay, true);
    _socket = s;
    _inbox.clear();
    _configRequested = false;
    // The radio may emit debug text before we speak protobuf; the
    // framer skips anything that isn't a frame header.
    s.listen(
      (data) {
        _inbox.add(data);
        _drainFrames();
      },
      onError: (_) => _drop(),
      onDone: () => _drop(),
      cancelOnError: true,
    );
  }

  void _drop() {
    try {
      _socket?.destroy();
    } catch (_) {}
    _socket = null;
    _configRequested = false;
  }

  /// Send ToRadio{want_config_id} with the 4-byte stream framing.
  void _requestConfig() {
    final s = _socket;
    if (s == null || _configRequested) return;
    _configRequested = true;
    // want_config_id = field 3, varint → tag 0x18, value 42.
    const payload = [0x18, 0x2A];
    s.add([0x94, 0xC3, 0x00, payload.length, ...payload]);
  }

  /// Pull complete frames off the inbox and parse them.
  void _drainFrames() {
    final bytes = _inbox.toBytes();
    var i = 0;
    final keep = <int>[];
    while (i + 4 <= bytes.length) {
      if (bytes[i] != 0x94 || bytes[i + 1] != 0xC3) {
        i++; // debug text / resync: skip one byte
        continue;
      }
      final len = (bytes[i + 2] << 8) | bytes[i + 3];
      if (len > 512 || len < 0) {
        malformedCount++;
        i += 2; // corrupt length: resync past the header
        continue;
      }
      if (i + 4 + len > bytes.length) break; // incomplete frame
      _parseFromRadio(bytes.sublist(i + 4, i + 4 + len));
      i += 4 + len;
    }
    keep.addAll(bytes.sublist(i));
    _inbox.clear();
    _inbox.add(keep);
  }

  void _parseFromRadio(Uint8List pb) {
    final r = MeshProtoReader(pb);
    while (!r.done) {
      final tag = r.readTag();
      final field = tag >> 3;
      final wire = tag & 7;
      if (field == 2 && wire == 2) {
        _parseMeshPacket(r.readBytes());
      } else if (field == 3 && wire == 2) {
        _parseMyNodeInfo(r.readBytes());
      } else if (field == 4 && wire == 2) {
        _parseNodeInfo(r.readBytes());
      } else {
        r.skip(wire);
      }
    }
  }

  /// FromRadio.my_info → MyNodeInfo{my_node_num=1}: our own node
  /// number, so direct series edges can name the real local node
  /// instead of the 0 sentinel.
  void _parseMyNodeInfo(Uint8List pb) {
    final r = MeshProtoReader(pb);
    while (!r.done) {
      final tag = r.readTag();
      final field = tag >> 3;
      final wire = tag & 7;
      if (field == 1 && wire == 0) {
        final num = r.readVarint();
        if (num != 0) _localNodeNum = num;
      } else {
        r.skip(wire);
      }
    }
  }

  void _parseNodeInfo(Uint8List pb) {
    final r = MeshProtoReader(pb);
    var num = 0;
    double? lat, lon, snr, chUtil, airUtil;
    while (!r.done) {
      final tag = r.readTag();
      final field = tag >> 3;
      final wire = tag & 7;
      if (field == 1 && wire == 0) {
        num = r.readVarint();
      } else if (field == 3 && wire == 2) {
        final p = _parsePosition(r.readBytes());
        lat = p.$1;
        lon = p.$2;
      } else if (field == 4 && wire == 5) {
        snr = r.readFloat();
      } else if (field == 6 && wire == 2) {
        // NodeInfo.device_metrics → DeviceMetrics{chUtil=3, airUtil=4}
        final m = _parseDeviceMetrics(r.readBytes());
        chUtil = m.$1;
        airUtil = m.$2;
      } else {
        r.skip(wire);
      }
    }
    if (num == 0) return;
    final n = _nodes.putIfAbsent(num, () => _MeshNode(num));
    if (lat != null && lon != null && lat != 0 && lon != 0) {
      n.lat = lat;
      n.lon = lon;
    }
    if (snr != null && snr.isFinite) {
      n.snr = snr;
      n.snrAt = DateTime.now();
    }
    if (chUtil != null || airUtil != null) {
      n.chUtil = chUtil;
      n.airUtil = airUtil;
      channelUtilization.record(num, chUtil, airUtil);
    }
    n.lastHeard = DateTime.now();
  }

  /// DeviceMetrics{channel_utilization=3 float, air_util_tx=4 float}
  /// (telemetry.proto). Returns (chUtil, airUtil); either may be null.
  (double?, double?) _parseDeviceMetrics(Uint8List pb) {
    final r = MeshProtoReader(pb);
    double? chUtil, airUtil;
    while (!r.done) {
      final tag = r.readTag();
      final field = tag >> 3;
      final wire = tag & 7;
      if (field == 3 && wire == 5) {
        final v = r.readFloat();
        if (v.isFinite) chUtil = v;
      } else if (field == 4 && wire == 5) {
        final v = r.readFloat();
        if (v.isFinite) airUtil = v;
      } else {
        r.skip(wire);
      }
    }
    return (chUtil, airUtil);
  }

  /// Returns (lat, lon) in degrees, or (null, null).
  (double?, double?) _parsePosition(Uint8List pb) {
    final r = MeshProtoReader(pb);
    double? lat, lon;
    while (!r.done) {
      final tag = r.readTag();
      final field = tag >> 3;
      final wire = tag & 7;
      if (field == 1 && wire == 5) {
        lat = r.readSfixed32() * 1e-7;
      } else if (field == 2 && wire == 5) {
        lon = r.readSfixed32() * 1e-7;
      } else {
        r.skip(wire);
      }
    }
    return (lat, lon);
  }

  void _parseMeshPacket(Uint8List pb) {
    final r = MeshProtoReader(pb);
    var from = 0;
    double? rxSnr;
    double? rxRssi;
    int? hopLimit;
    int? hopStart;
    var hasHopStart = false;
    Uint8List? decoded;
    while (!r.done) {
      final tag = r.readTag();
      final field = tag >> 3;
      final wire = tag & 7;
      if (field == 1 && wire == 5) {
        from = r.readFixed32();
      } else if (field == 4 && wire == 2) {
        decoded = r.readBytes();
      } else if (field == 8 && wire == 5) {
        final v = r.readFloat();
        if (v.isFinite) rxSnr = v;
      } else if (field == 9 && wire == 0) {
        // hop_limit — NOT rx_rssi (deep-dive field-number error,
        // corrected 2026-11-28; see header).
        hopLimit = r.readVarint();
      } else if (field == 12 && wire == 0) {
        // rx_rssi, int32 varint, sign-extended from 32 bits.
        rxRssi = r.readSignedVarint32().toDouble();
      } else if (field == 15 && wire == 0) {
        hopStart = r.readVarint();
        hasHopStart = true;
      } else {
        r.skip(wire);
      }
    }
    if (from == 0) return;
    final now = DateTime.now();
    int? hopCount;
    if (hasHopStart && hopStart != null && hopStart > 0 && hopLimit != null) {
      hopCount = hopStart - hopLimit;
      if (hopCount < 0) hopCount = 0;
    }
    // Per-packet link stream (#1): EVERY packet is a link sample,
    // sender → our node. Recorded before any portnum filtering, so
    // telemetry / text / probe packets all count.
    final node = _nodes.putIfAbsent(from, () => _MeshNode(from));
    node.lastHeard = now;
    if (rxSnr != null) {
      node.snr = rxSnr;
      node.snrAt = now;
    }
    if (rxRssi != null) {
      node.rssi = rxRssi;
      node.rssiAt = now;
    }
    int? portnum;
    double? chUtil, airUtil;
    if (decoded != null) {
      final parsed = _parseData(from, decoded);
      portnum = parsed.$1;
      chUtil = parsed.$2;
      airUtil = parsed.$3;
    }
    linkSeries.record(MeshLinkSample(
      timestamp: now,
      fromNode: from,
      toNode: _localNodeNum,
      snr: rxSnr,
      rssi: rxRssi,
      hopCount: hopCount,
      portnum: portnum,
      chUtil: chUtil,
      airUtil: airUtil,
    ));
  }

  /// Parse `Data{portnum=1, payload=2}`. Returns (portnum, chUtil,
  /// airUtil) — the utilization fields are set only for telemetry
  /// packets, so the caller can attach them to the single per-packet
  /// series record instead of double-counting the packet.
  /// Dispatches by portnum: 71 NeighborInfo, 67 Telemetry, 300
  /// Outride probe; anything else is ignored (but the packet itself
  /// was already recorded in the series by [_parseMeshPacket]).
  (int?, double?, double?) _parseData(int from, Uint8List pb) {
    final r = MeshProtoReader(pb);
    var portnum = 0;
    Uint8List? payload;
    while (!r.done) {
      final tag = r.readTag();
      final field = tag >> 3;
      final wire = tag & 7;
      if (field == 1 && wire == 0) {
        portnum = r.readVarint();
      } else if (field == 2 && wire == 2) {
        payload = r.readBytes();
      } else {
        r.skip(wire);
      }
    }
    if (payload == null) {
      // FIX (review small item): a Data with a known portnum but no
      // payload used to return (null, null, null), discarding the
      // portnum from the series record. Keep the portnum.
      return (portnum == 0 ? null : portnum, null, null);
    }
    final now = DateTime.now();
    if (portnum == 71) {
      _parseNeighborInfo(from, payload, now);
      return (portnum, null, null);
    } else if (portnum == 67) {
      final m = _parseTelemetry(from, payload, now);
      return (portnum, m.$1, m.$2);
    } else if (portnum == outrideProbePortnum) {
      _parseProbeReport(from, payload, now);
      return (portnum, null, null);
    }
    return (portnum, null, null);
  }

  void _parseNeighborInfo(int from, Uint8List payload, DateTime now) {
    final pr = MeshProtoReader(payload);
    while (!pr.done) {
      final tag = pr.readTag();
      if ((tag >> 3) == 4 && (tag & 7) == 2) {
        final nb = _parseNeighbor(pr.readBytes());
        if (nb != null && from != 0) {
          final a = _nodes.putIfAbsent(from, () => _MeshNode(from));
          a.neighbors[nb.$1] = nb.$2;
          a.neighborsAt = now;
          a.lastHeard = now;
        }
      } else {
        pr.skip(tag & 7);
      }
    }
  }

  /// Telemetry{device_metrics=2} → DeviceMetrics{chUtil=3, airUtil=4}
  /// (telemetry.proto). Returns (chUtil, airUtil); the caller
  /// attaches them to the single per-packet series record.
  (double?, double?) _parseTelemetry(
      int from, Uint8List payload, DateTime now) {
    double? chUtil, airUtil;
    final tr = MeshProtoReader(payload);
    while (!tr.done) {
      final tag = tr.readTag();
      if ((tag >> 3) == 2 && (tag & 7) == 2) {
        final m = _parseDeviceMetrics(tr.readBytes());
        chUtil = m.$1;
        airUtil = m.$2;
      } else {
        tr.skip(tag & 7);
      }
    }
    if (chUtil == null && airUtil == null) return (null, null);
    final n = _nodes.putIfAbsent(from, () => _MeshNode(from));
    n.chUtil = chUtil;
    n.airUtil = airUtil;
    n.lastHeard = now;
    channelUtilization.record(from, chUtil, airUtil, at: now);
    return (chUtil, airUtil);
  }

  /// Outride probe report (portnum 300): each neighbor triple is an
  /// observation the sender made of that neighbor, recorded as
  /// reporter -> heard (sender -> neighbor) — the NeighborInfo /
  /// LinkSample convention, so the series edge and the neighbor
  /// table agree on direction (FIX, review item 8: the series edge
  /// used to be neighbor -> sender while the neighbor table emitted
  /// sender -> neighbor for the same observation).
  /// The report's `senderNodeNum` is cross-checked against the
  /// packet's `from` (FIX, review small item): a mismatch is
  /// malformed — the report is dropped, counted, and the packet
  /// itself was already series-recorded. A malformed report is
  /// ignored otherwise — it must never break packet parsing.
  void _parseProbeReport(int from, Uint8List payload, DateTime now) {
    MeshtasticProbeReport report;
    try {
      report = MeshtasticProbePayload.decode(payload);
    } catch (_) {
      malformedCount++;
      return;
    }
    if (report.senderNodeNum != from) {
      malformedCount++;
      return;
    }
    final sender = _nodes.putIfAbsent(from, () => _MeshNode(from));
    sender.lastHeard = now;
    for (final nb in report.neighbors) {
      linkSeries.record(MeshLinkSample(
        timestamp: now,
        fromNode: from,
        toNode: nb.nodeNum,
        snr: nb.snr,
        rssi: nb.rssi,
        portnum: outrideProbePortnum,
      ));
      sender.neighbors[nb.nodeNum] = nb.snr;
    }
    sender.neighborsAt = now;
  }

  (int, double)? _parseNeighbor(Uint8List pb) {
    final r = MeshProtoReader(pb);
    var id = 0;
    double? snr;
    while (!r.done) {
      final tag = r.readTag();
      final field = tag >> 3;
      final wire = tag & 7;
      if (field == 1 && wire == 0) {
        id = r.readVarint();
      } else if (field == 2 && wire == 5) {
        snr = r.readFloat();
      } else {
        r.skip(wire);
      }
    }
    if (id == 0 || snr == null || !snr.isFinite) return null;
    return (id, snr);
  }

  /// Test hook: feed raw stream bytes (framed or debug text) through
  /// the same framer/parser the socket listener uses.
  @visibleForTesting
  void ingestBytesForTest(List<int> bytes) {
    _inbox.add(bytes);
    _drainFrames();
  }

  /// Test hook: build link samples from the current node table without
  /// touching the socket.
  @visibleForTesting
  List<LinkSample> buildSamplesForTest() => _buildSamples(DateTime.now());

  /// Test hook: move a node's per-field measurement timestamps
  /// (used by the staleness test: a fresh RSSI must not carry a
  /// stale SNR as current). Only the fields given are moved;
  /// [lastHeard] is untouched, so the node itself is not pruned.
  @visibleForTesting
  void setNodeMeasurementTimesForTest(
    int nodeNum, {
    DateTime? snrAt,
    DateTime? rssiAt,
  }) {
    final n = _nodes[nodeNum];
    if (n == null) return;
    if (snrAt != null) n.snrAt = snrAt;
    if (rssiAt != null) n.rssiAt = rssiAt;
  }

  @override
  Future<List<LinkSample>> poll() async {
    try {
      await _ensureConnected();
    } catch (_) {
      _drop();
      return [];
    }
    _requestConfig();
    // Give the radio a beat to answer; frames already arrived are
    // parsed by the socket listener. A short settle keeps poll()
    // from returning before the first NodeDB burst lands.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    _drainFrames();
    return _buildSamples(DateTime.now());
  }

  List<LinkSample> _buildSamples(DateTime now) {
    final maxAge = sampleMaxAge!;
    final out = <LinkSample>[];

    // Prune nodes silent too long; they are node-LOSS, not links.
    _nodes.removeWhere((_, n) => now.difference(n.lastHeard) > maxAge * 2);

    for (final n in _nodes.values) {
      final id = nodeIdOf(n.num);
      // Direct edge: SNR/RSSI at which OUR node heard this node.
      // FIX (re-review item 12): each field is checked against
      // maxAge on its own timestamp. The old code used
      // lastHeardAt = max(snrAt, rssiAt), so a fresh RSSI carried
      // a >15-min-old SNR presented as current (bounded by the
      // 15-min sampleMaxAge, but still a mislabel). A stale field
      // is now emitted as null, never as current; the sample is
      // dropped only when nothing is fresh.
      final snrFresh = n.snr != null &&
          n.snrAt != null &&
          now.difference(n.snrAt!) <= maxAge;
      final rssiFresh = n.rssi != null &&
          n.rssiAt != null &&
          now.difference(n.rssiAt!) <= maxAge;
      if (snrFresh || rssiFresh) {
        out.add(LinkSample(
          timestamp: now,
          fromNode: 'meshtastic:local',
          toNode: id,
          snr: snrFresh ? n.snr : null,
          rssi: rssiFresh ? n.rssi : null,
          authenticated: authenticated,
        ));
      }
      // Neighbor edges reported by this node.
      if (n.neighborsAt != null &&
          now.difference(n.neighborsAt!) <= maxAge) {
        for (final e in n.neighbors.entries) {
          out.add(LinkSample(
            timestamp: now,
            fromNode: id,
            toNode: nodeIdOf(e.key),
            snr: e.value,
            authenticated: authenticated,
          ));
        }
      }
    }
    return out;
  }

  @override
  Future<bool> probe() async {
    Socket? s;
    try {
      s = await Socket.connect(host, port,
          timeout: const Duration(seconds: 4));
      // want_config handshake; a real node answers with framed FromRadio.
      s.add(const [0x94, 0xC3, 0x00, 0x02, 0x18, 0x2A]);
      final completer = Completer<bool>();
      var seen = BytesBuilder();
      late StreamSubscription<List<int>> sub;
      sub = s.listen(
        (data) {
          seen.add(data);
          final b = seen.toBytes();
          for (var i = 0; i + 1 < b.length; i++) {
            if (b[i] == 0x94 && b[i + 1] == 0xC3) {
              if (!completer.isCompleted) completer.complete(true);
              sub.cancel();
              return;
            }
          }
          if (seen.length > 4096 && !completer.isCompleted) {
            completer.complete(false);
            sub.cancel();
          }
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete(false);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(false);
        },
        cancelOnError: true,
      );
      return await completer.future.timeout(
        const Duration(seconds: 4),
        onTimeout: () => false,
      );
    } catch (_) {
      return false;
    } finally {
      try {
        s?.destroy();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _drop();
    _nodes.clear();
  }
}

class _MeshNode {
  _MeshNode(this.num);
  final int num;
  double? lat;
  double? lon;
  double? snr;
  DateTime? snrAt;
  double? rssi;
  DateTime? rssiAt;
  double? chUtil;
  double? airUtil;
  DateTime lastHeard = DateTime.now();
  final Map<int, double> neighbors = {};
  DateTime? neighborsAt;
}

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/tracking.dart';
import '../services/gps_positioning.dart';
import '../services/operator_pose.dart';
import '../services/tracker.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../utils/field_map_transform.dart';
import '../utils/hull.dart';
import 'airframe_overlay.dart';
import 'offline_maps_screen.dart';
import 'sensor_overlay.dart';
import 'tile_pack_layer.dart';

/// Tracking tab in the RuView observatory style: dark field map with
/// glowing nodes, fused track readout as technical rows, node heights.
///
/// Honest by construction: altitude shows "unknown" when nodes are
/// coplanar, heading/speed appear only once the target moves between
/// fixes, and the type guess is always labeled low-confidence.
/// UI label for the fused RTI disturbance image (rti_imaging_weights).
/// Honesty contract: "estimated disturbance location (ground
/// projection)" — probability mass over the ground plane, never a
/// located object, never an identified target, never confirmed.
const String rtiImageLabel =
    'ESTIMATED DISTURBANCE LOCATION (GROUND PROJECTION)';

class TrackingScreen extends StatefulWidget {  const TrackingScreen({super.key, required this.state});

  final AppState state;

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen> {
  /// nodeId being dragged, 'defended', or null.
  String? _dragging;

  /// Transform captured at pan start, used for the whole drag.
  /// Follow mode re-centers the map on the operator, so the
  /// visible transform changes when follow turns off mid-grab;
  /// mapping pan updates through the pan-start transform keeps
  /// the grabbed node under the finger instead of teleporting it
  /// by the operator's distance from the field centroid.
  FieldMapTransform? _dragTransform;

  /// Shadow (attenuation) heatmap overlay on the field map.
  bool _showShadow = true;

  /// Fused RTI disturbance image overlay (rtiImageLabel).
  bool _showRti = true;

  /// Node health overlay: recolor node dots by link freshness
  /// (green/amber/red/grey) instead of driver color.
  bool _showHealth = false;

  /// Universal sensor observation overlay (lidar arcs, acoustic
  /// bearings, camera motion…). Needs a GPS origin to project.
  bool _showSensors = true;

  /// Cooperative-contacts layer: CoT friendly platforms (air AND
  /// ground), Remote ID contacts, operator points. Renamed from
  /// AIR in v0.23.0 — the layer stopped being air-only when
  /// PRC-163 ground PLI joined it; the toggle copy now says what
  /// it gates.
  bool _showContacts = true;

  /// Map zoom (wheel / buttons). Pinch is reserved for node dragging.
  double _mapZoom = 1.0;

  /// Fullscreen field map: the map fills the whole tab area.
  bool _mapFullscreen = false;

  /// What the tile-pack layer is currently rendering (pack name +
  /// zoom), for the status line under the map. Null = no tiles.
  /// Starts as web on web so the first frame never claims tiles
  /// are unavailable there — the loader is the tile source, even
  /// before its first tile lands.
  TileLayerStatus _tileStatus = const TileLayerStatus(web: kIsWeb);

  /// Compact layer-toggle buttons for the field-map header: tight
  /// padding so all four fit across a phone-width card when wrapped.
  static final _toggleStyle = TextButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    minimumSize: const Size(0, 32),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  void _bumpMapZoom(double f) => setState(() {
        _mapZoom = (_mapZoom * f).clamp(0.5, 4.0);
      });

  AppState get state => widget.state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final nodes = state.effectiveNodes.values.toList();
        final live = !state.settings.simulatedMode;
        if (_mapFullscreen) {
          return Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: _mapVisualization(nodes, live, expand: true),
                ),
              ),
              Positioned(
                top: 12,
                left: 12,
                child: _fullscreenChip(),
              ),
            ],
          );
        }
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _mapCard(nodes, live),
            const SizedBox(height: 12),
            if (live) ...[
              _gpsCard(nodes),
              const SizedBox(height: 12),
            ],
            _readoutCard(),
            const SizedBox(height: 12),
            if (state.airframeRecords.isNotEmpty ||
                state.groundTrackRecords.isNotEmpty ||
                state.ridContacts.isNotEmpty ||
                state.settings.remoteIdEnabled) ...[
              _airContactsCard(),
              const SizedBox(height: 12),
            ],
            if (live) ...[
              _nodeHeightsCard(nodes),
              const SizedBox(height: 12),
            ],
            const _TrackScopeNote(),
          ],
        );
      },
    );
  }

  Widget _mapCard(List<NodePosition> nodes, bool live) {
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: title + mode label + fullscreen on the first row;
          // the four layer toggles get their own wrapping row below.
          // They used to share the title row, which overflowed the
          // card on phone widths — HEALTH clipped mid-word and
          // SENSORS fell off the screen entirely (field report
          // 2026-10-20).
          Row(
            children: [
              Text('FIELD MAP', style: OutrideType.section()),
              const Spacer(),
              IconButton(
                tooltip: 'FULLSCREEN',
                icon: const Icon(Icons.fullscreen,
                    color: OutrideColors.muted, size: 20),
                onPressed: () =>
                    setState(() => _mapFullscreen = true),
              ),
            ],
          ),
          Wrap(
            spacing: 4,
            runSpacing: 0,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                style: _toggleStyle,
                onPressed: () =>
                    setState(() => _showShadow = !_showShadow),
                child: Text(
                    _showShadow ? 'SHADOW ON' : 'SHADOW OFF'),
              ),
              TextButton(
                style: _toggleStyle,
                onPressed: () => setState(() => _showRti = !_showRti),
                child: Text(_showRti ? 'RTI ON' : 'RTI OFF'),
              ),
              TextButton(
                style: _toggleStyle,
                onPressed: () =>
                    setState(() => _showHealth = !_showHealth),
                child: Text(
                    _showHealth ? 'HEALTH ON' : 'HEALTH OFF'),
              ),
              TextButton(
                style: _toggleStyle,
                onPressed: () =>
                    setState(() => _showSensors = !_showSensors),
                child: Text(
                    _showSensors ? 'SENSORS ON' : 'SENSORS OFF'),
              ),
              TextButton(
                style: _toggleStyle,
                onPressed: () =>
                    setState(() => _showContacts = !_showContacts),
                child: Text(_showContacts ? 'CONTACTS ON' : 'CONTACTS OFF'),
              ),
              // Live GPS (v0.28.0, EXPERIMENTAL): continuous position
              // stream for the "you are here" marker. Denied or
              // unavailable falls back to the simulated operator
              // position — the map still works.
              TextButton(
                style: _toggleStyle,
                onPressed: () {
                  if (state.liveGpsState == LiveGpsState.off ||
                      state.liveGpsState == LiveGpsState.denied ||
                      state.liveGpsState == LiveGpsState.unavailable) {
                    unawaited(state.startLiveGps());
                  } else {
                    unawaited(state.stopLiveGps());
                  }
                },
                child: Text(switch (state.liveGpsState) {
                  LiveGpsState.off => 'LIVE GPS OFF',
                  LiveGpsState.starting => 'LIVE GPS…',
                  LiveGpsState.live => 'LIVE GPS ON',
                  LiveGpsState.denied => 'LIVE GPS DENIED',
                  LiveGpsState.unavailable => 'LIVE GPS N/A',
                }),
              ),
              // Follow mode: keep the map centered on the operator.
              // Any map drag turns it off (the operator took over).
              TextButton(
                style: _toggleStyle,
                onPressed: state.mapOperatorPosition == null
                    ? null
                    : () => state.setLiveGpsFollow(!state.liveGpsFollow),
                child: Text(
                    state.liveGpsFollow ? 'FOLLOW ON' : 'FOLLOW OFF'),
              ),
              TextButton(
                style: _toggleStyle,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => OfflineMapsScreen(state: state),
                  ),
                ),
                child: const Text('OFFLINE MAPS'),
              ),
              // Mode label rides the toggle wrap: in the title row it
              // still overflowed narrow cards under fallback fonts.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  live ? 'LIVE LAYOUT' : 'SIMULATED LAYOUT',
                  style: OutrideType.section(10).copyWith(
                    color:
                        live ? OutrideColors.green : OutrideColors.orange,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'DRAG NODES TO THEIR REAL SPOTS. DRAG THE RED MARKER TO MOVE THE DEFENDED POINT. '
            'THE SHADOW IS WHERE THE RF FIELD DIMS — WHAT THE WAVES ARE HITTING. '
            'SCROLL OR USE +/− TO ZOOM. ONE MAP, EVERY RADIO: NODE COLORS MARK THE DRIVER.',
            style: OutrideType.section(10),
          ),
          const SizedBox(height: 6),
          Text(
            'FUSED IMAGE: $rtiImageLabel — PROBABILITY MASS OVER THE GROUND PLANE FROM THE '
            'DIRECTION-SPLIT, AREA-NORMALIZED RTI LAYER. AN ESTIMATE OF WHERE THE FIELD IS '
            'DISTURBED — NEVER A POSITION FIX, NEVER AN IDENTIFICATION.',
            style: OutrideType.section(10),
          ),
          const SizedBox(height: 8),
          if (_showHealth) _healthLegend() else _driverLegend(nodes),
          const SizedBox(height: 8),
          _mapVisualization(nodes, live),
          const SizedBox(height: 6),
          _mapStatusLine(),
          if (live) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: state.resetLayout,
                child: const Text('RESET LAYOUT'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The interactive field map visualization. With [expand], it fills
  /// whatever space the parent gives it (fullscreen mode); otherwise
  /// it renders at the standard card height.
  Widget _mapVisualization(List<NodePosition> nodes, bool live,
      {bool expand = false}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final h = expand ? constraints.maxHeight : 320.0;
        final size =
            Size(constraints.maxWidth, h.isFinite ? h : 320.0);
        final tr = _buildTransform(size, nodes);
        final origin = state.gpsOrigin;
        return Stack(
          children: [
            // Offline tile packs (v0.28.0, EXPERIMENTAL): pack tiles
            // under the field overlay. No origin or no packs means
            // no layer — the field canvas is exactly as before. On
            // web the packs are unavailable by design and the layer
            // fetches USGS tiles live through the web loader instead
            // (v0.29.3) — same cap, same grid fallback.
            if (state.displayOrigin != null)
              TilePackMapLayer(
                transform: tr,
                origin: state.displayOrigin!,
                size: size,
                tilePacks: state.tilePacks,
                webTiles: state.webTiles,
                onStatus: (s) => setState(() => _tileStatus = s),
              ),
            Listener(
              onPointerSignal: (signal) {
                if (signal is PointerScrollEvent) {
                  _bumpMapZoom(signal.scrollDelta.dy < 0
                      ? 1.12
                      : 1 / 1.12);
                }
              },
              child: GestureDetector(
                onPanStart: (d) =>
                    _onPanStart(d.localPosition, size, nodes, live),
                onPanUpdate: (d) =>
                    _onPanUpdate(d.localPosition, size, live),
                onPanEnd: (_) => setState(() {
                  _dragging = null;
                  _dragTransform = null;
                }),
                child: CustomPaint(
                  size: size,
                  painter: TrackingMapPainter(
                    transform: tr,
                    nodes: nodes,
                    disturbedPairs: state.disturbedPairs,
                    defended: state.defended,
                    track: state.track,
                    shadow: state.shadow,
                    showShadow: _showShadow,
                    rti: state.rtiImage,
                    showRti: _showRti,
                    showHealth: _showHealth,
                    nodeHealth: _showHealth ? state.nodeHealthMap : const {},
                    operatorPos: state.mapOperatorMeters,
                    operatorAccuracyM: state.mapOperatorAccuracyM,
                    operatorLive: state.mapOperatorIsLive,
                  ),
                ),
              ),
            ),
            // Universal sensor observations (lidar arcs, acoustic
            // bearings, camera motion…). Above tracks reads best.
            // Needs a GPS origin to project lat/lon → map.
            if (_showSensors && origin != null)
              ...sensorObservationLayer(
                observations: state.sensorObservations,
                project: (lat, lon) {
                  final m = latLonToMeters(lat, lon, origin.lat, origin.lon);
                  return tr.toScreen(m.x, m.y);
                },
                metersToPx: tr.scale,
              ),
            // Airframes (Skydio P1/P2): friendly platforms, Remote ID
            // contacts, operator points. Diamonds = aircraft,
            // squares = operator/takeoff. Needs the GPS origin.
            if (_showContacts && origin != null)
              ...airframeLayer(
                records: state.airframeRecords,
                ridContacts: state.ridContacts,
                project: (lat, lon) {
                  final m = latLonToMeters(lat, lon, origin.lat, origin.lon);
                  return tr.toScreen(m.x, m.y);
                },
              ),
            // Friendly ground tracks (PRC-163 PLI, v0.23.0): person
            // glyphs — never diamonds — under the same CONTACTS
            // toggle. Projection uses the display origin (the GPS
            // origin, or the sim demo anchor in simulated mode).
            if (_showContacts && state.displayOrigin != null)
              ...groundLayer(
                records: state.groundTrackRecords,
                project: (lat, lon) {
                  final o = state.displayOrigin!;
                  final m = latLonToMeters(lat, lon, o.lat, o.lon);
                  return tr.toScreen(m.x, m.y);
                },
              ),
            Positioned(
              right: 4,
              top: 4,
              child: OutrideZoomControls(
                onZoomIn: () => _bumpMapZoom(1.25),
                onZoomOut: () => _bumpMapZoom(1 / 1.25),
                onReset: () => setState(() => _mapZoom = 1.0),
              ),
            ),
            // Compass rose: the map is north-up (world +y = north renders
            // toward the top), so this is a fixed orientation reference.
            const Positioned(
              left: 8,
              top: 8,
              child: _CompassRose(),
            ),
          ],
        );
      },
    );
  }

  FieldMapTransform _buildTransform(Size size, List<NodePosition> nodes) {
    final pts = <math.Point<double>>[];
    for (final n in nodes) {
      pts.add(math.Point(n.x, n.y));
    }
    pts.add(math.Point(state.defended.x, state.defended.y));
    final t = state.track;
    if (t != null) pts.add(math.Point(t.x, t.y));
    final fit = FieldMapTransform.fit(size, pts, zoom: _mapZoom);
    // Follow mode (v0.28.0 live GPS): keep the map centered on the
    // operator at the same zoom — only the center moves.
    final op = state.liveGpsFollow ? state.mapOperatorMeters : null;
    if (op != null) {
      return FieldMapTransform.centered(
        size: size,
        centerX: op.x,
        centerY: op.y,
        scale: fit.scale,
      );
    }
    return fit;
  }

  void _onPanStart(
      Offset p, Size size, List<NodePosition> nodes, bool live) {
    final tr = _buildTransform(size, nodes);
    // Defended point first (topmost).
    final d = tr.toScreen(state.defended.x, state.defended.y);
    if ((p - d).distance < 26) {
      // A real drag takes over from follow mode (hit-tested against
      // the visible, follow-centered transform first). The drag
      // then maps through the captured transform, so turning
      // follow off here cannot move the grabbed point.
      if (state.liveGpsFollow) state.setLiveGpsFollow(false);
      _dragTransform = tr;
      setState(() => _dragging = 'defended');
      return;
    }
    if (!live) return; // sim layout is fixed
    for (final n in nodes) {
      final s = tr.toScreen(n.x, n.y);
      if ((p - s).distance < 26) {
        if (state.liveGpsFollow) state.setLiveGpsFollow(false);
        _dragTransform = tr;
        setState(() => _dragging = n.nodeId);
        return;
      }
    }
  }

  void _onPanUpdate(Offset p, Size size, bool live) {
    final drag = _dragging;
    if (drag == null) return;
    // The pan-start transform, frozen for the drag — never the
    // live rebuild, which would jump when follow mode turns off.
    final tr = _dragTransform ??
        _buildTransform(size, state.effectiveNodes.values.toList());
    final wx = tr.toWorldX(p.dx);
    final wy = tr.toWorldY(p.dy);
    if (drag == 'defended') {
      state.moveDefended(wx, wy);
    } else if (live) {
      state.moveNode(drag, wx, wy);
    }
  }

  /// One-line map status: where YOU are (live GPS / simulated /
  /// denied fallback) and what tiles are rendering. Honest about
  /// distance: when the operator is far from the defended point
  /// the line says so and points at FOLLOW.
  Widget _mapStatusLine() {
    final op = state.mapOperatorPosition;
    final String you;
    if (state.mapOperatorIsLive) {
      final acc = state.mapOperatorAccuracyM;
      final dist = state.mapOperatorDistanceToDefendedM;
      final distText = dist != null && dist > 100
          ? ' · ${dist >= 1000 ? '${(dist / 1000).toStringAsFixed(1)} KM' : '${dist.toStringAsFixed(0)} M'} FROM DEFENDED'
          : '';
      you = 'YOU: LIVE GPS${acc != null ? ' ±${acc.toStringAsFixed(0)} M' : ''}$distText'
          '${state.liveGpsFollow ? ' · FOLLOWING' : ''}';
    } else if (state.liveGpsState == LiveGpsState.denied ||
        state.liveGpsState == LiveGpsState.unavailable) {
      // "SIMULATED FALLBACK" is only true when a fallback marker
      // is actually drawn (simulated mode's demo anchor). Live
      // mode with GPS denied and no fix draws no YOU marker, so
      // the line must say NO POSITION instead (v0.29.2 review).
      you = op != null
          ? 'YOU: GPS ${state.liveGpsState == LiveGpsState.denied ? 'DENIED' : 'UNAVAILABLE'} — SIMULATED FALLBACK'
          : 'YOU: NO POSITION — TAP LIVE GPS';
    } else if (op != null) {
      you = 'YOU: SIMULATED (DEMO ANCHOR)';
    } else {
      you = 'YOU: NO POSITION — TAP LIVE GPS';
    }
    final tiles = _tileStatus.hasTiles && _tileStatus.tilesLoaded > 0
        ? 'TILES: ${_tileStatus.packName} · Z${_tileStatus.zoom}'
        : _tileStatus.web
            // Web loader is the tile source but nothing loaded
            // (offline, or outside USGS coverage): the grid is the
            // map, said plainly.
            ? 'TILES: WEB — NO TILES — GRID ONLY'
            : !state.tilePacks.supported
                ? 'TILES: NOT AVAILABLE ON WEB — GRID ONLY'
                : 'TILES: NONE — GRID ONLY';
    return Text(
      '$you · $tiles',
      style: OutrideType.section(10),
    );
  }

  /// Legend: which driver color marks which radio family on the map.
  Widget _driverLegend(List<NodePosition> nodes) {
    final drivers = <String>{};
    for (final n in nodes) {
      drivers.add(driverOf(n.nodeId));
    }
    if (drivers.length < 2) return const SizedBox.shrink();
    return Wrap(
      spacing: 14,
      runSpacing: 4,
      children: [
        for (final d in drivers)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: driverColor(d),
                ),
              ),
              const SizedBox(width: 5),
              Text(d.isEmpty ? 'UNKNOWN' : d.toUpperCase(),
                  style: OutrideType.section(10)),
            ],
          ),
      ],
    );
  }

  /// Legend for the node-health overlay: dot color = link freshness.
  Widget _healthLegend() {
    const items = [
      (OutrideColors.green, 'ALL LINKS LIVE'),
      (OutrideColors.amber, 'SOME STALE'),
      (OutrideColors.red, 'ALL STALE'),
      (OutrideColors.muted, 'NO LINKS'),
    ];
    return Wrap(
      spacing: 14,
      runSpacing: 4,
      children: [
        for (final (c, label) in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c,
                ),
              ),
              const SizedBox(width: 5),
              Text(label, style: OutrideType.section(10)),
            ],
          ),
      ],
    );
  }

  /// Floating exit-fullscreen chip shown over fullscreen views.
  Widget _fullscreenChip() {
    return Material(
      color: OutrideColors.surface2.withAlpha(220),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => setState(() => _mapFullscreen = false),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.fullscreen_exit,
                  color: OutrideColors.onDark, size: 16),
              const SizedBox(width: 6),
              Text('EXIT FULLSCREEN',
                  style: OutrideType.section(10)
                      .copyWith(color: OutrideColors.onDark)),
            ],
          ),
        ),
      ),
    );
  }

  /// Contacts readout (Skydio P1/P2; ground tracks v0.23.0): what
  /// the cooperative feeds report — friendly air platforms,
  /// friendly ground units, and Remote ID broadcasts. Copy is the
  /// honesty contract: RID identity is a CLAIM, coverage is
  /// broadcast-only, and an empty card never means an empty sky
  /// (or an empty field).
  Widget _airContactsCard() {
    final records = state.airframeRecords;
    final ground = state.groundTrackRecords;
    final contacts = state.ridContacts;
    String ageText(DateTime? seen) {
      if (seen == null) return '—';
      final s = DateTime.now().difference(seen).inSeconds;
      return s < 2 ? 'NOW' : '${s}s AGO';
    }

    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('CONTACTS', style: OutrideType.section()),
          const SizedBox(height: 8),
          if (records.isEmpty && contacts.isEmpty && ground.isEmpty)
            Text(
              'NOTHING HEARD YET. FRIENDLY AIRCRAFT ARRIVE VIA THE '
              'CONTROLLER COT FEED AND FRIENDLY GROUND UNITS '
              '(PRC-163 PLI) VIA THE SAME TAK FEED; CIVIL DRONES VIA '
              'REMOTE ID BROADCAST WHEN THE RECEIVER IS ON '
              '(SETTINGS → DRONES).',
              style: OutrideType.section(10).copyWith(height: 1.6),
            ),
          for (final r in records) ...[
            _row(
              r.displayName,
              '${r.affiliationLabel} · ${r.classLabel} · ${ageText(r.lastSeen)}',
              airframeAffiliationColor(r.affiliationLabel),
            ),
            const SizedBox(height: 4),
          ],
          for (final c in contacts)
            if (c.serial == null ||
                !records.any((r) =>
                    r.serial?.toUpperCase() == c.serial!.toUpperCase())) ...[
              _row(
                c.serial ?? 'RID · NO ID',
                'UNKNOWN · CLASS C · BROADCAST CONTACT (${c.sourceKind}) '
                    '· ${ageText(c.lastSeen)}',
                OutrideColors.amber,
              ),
              const SizedBox(height: 4),
            ],
          if (ground.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('GROUND TRACKS — FRIENDLY PLI VIA THE TAK FEED',
                style: OutrideType.section()),
            const SizedBox(height: 6),
            for (final g in ground) ...[
              _row(
                g.displayName,
                '${g.affiliationLabel} · GROUND'
                    '${g.batteryPct != null ? ' · BATT ${g.batteryPct!.round()}%' : ''}'
                    '${g.speedMps != null ? ' · ${g.speedMps!.toStringAsFixed(1)} M/S' : ''}'
                    ' · ${ageText(g.lastSeen)}',
                airframeAffiliationColor(g.affiliationLabel),
              ),
              const SizedBox(height: 4),
            ],
            Text(
              'A PRC-163 APPEARS HERE AS A POSITION ONLY: THE RADIO '
              'REPORTS WHERE ITS CARRIER IS (PLI) OVER THE TAK FEED. '
              'IT IS NOT A SENSING NODE — NO LINK METRICS EXIST FOR '
              'IT, AND ITS SILENCE REMOVES NOTHING.',
              style: OutrideType.section(10).copyWith(height: 1.6),
            ),
            const SizedBox(height: 4),
          ],
          const SizedBox(height: 4),
          Text(
            'REMOTE ID IS A BROADCAST CLAIM — UNAUTHENTICATED AND '
            'SPOOFABLE. A WHITELIST MATCH RENDERS "FRIENDLY (CLAIMED)" '
            'UNTIL A COOPERATIVE FEED CORROBORATES IT. BROADCAST-ONLY '
            'COVERAGE: MILITARY D-MODEL AIRCRAFT MAY TRANSMIT NO '
            'REMOTE ID AT ALL — NO CONTACT NEVER MEANS NO DRONE.',
            style: OutrideType.section(10).copyWith(height: 1.6),
          ),
        ],
      ),
    );
  }

  Widget _readoutCard() {
    final t = state.track;
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('TRACK ESTIMATE', style: OutrideType.section()),
              const Spacer(),
              if (t != null) _relationChip(t.relation),
            ],
          ),
          const SizedBox(height: 12),
          if (t == null)
            Text(
              state.disturbedLinks.isNotEmpty
                  ? 'DISTURBANCE DETECTED, BUT THERE IS NOT ENOUGH GEOMETRY TO '
                      'PLACE IT. LOCALIZING NEEDS 3+ NODES WITH POSITIONS '
                      '(SPECTRUM-BAND ALERTS NEVER LOCALIZE).'
                  : 'NO ACTIVE TARGET. DISTURB A LINK AND THE ESTIMATE APPEARS HERE.',
              style: OutrideType.rowLabel(),
            )
          else ...[
            _row('POSITION', t.positionLabel, OutrideColors.onDark),
            _row('ALTITUDE', '', OutrideColors.muted),
            _altitudeBody(t),
            _row(
                'SPEED',
                t.speedMps == null
                    ? '—'
                    : '${t.speedMps!.toStringAsFixed(1)} M/S EST',
                OutrideColors.blue),
            _row(
                'HEADING',
                t.headingDeg == null
                    ? '—  TARGET NOT MOVING YET'
                    : '${t.headingCompass} ${t.headingDeg!.toStringAsFixed(0)}° EST',
                OutrideColors.blue),
            _row('SIZE', '${t.sizeClass} EST', OutrideColors.onDark),
            _row('TYPE GUESS', '${t.typeGuess} — LOW CONFIDENCE',
                OutrideColors.muted),
            _row('LINKS USED', '${t.linksUsed}', OutrideColors.muted),
            if (state.trackConfidence != null)
              _row(
                'CONFIDENCE',
                '${(state.trackConfidence!.displayed * 100).toStringAsFixed(0)}% EST'
                ' — RF ${(state.trackConfidence!.base * 100).toStringAsFixed(0)}%'
                '${state.trackConfidence!.upgrade > 0.005 ? ' +${(state.trackConfidence!.upgrade * 100).toStringAsFixed(0)}% ${state.trackConfidence!.applied.length} SENSOR${state.trackConfidence!.applied.length == 1 ? '' : 'S'}' : ''}',
                OutrideColors.green,
              ),
            if (state.trackConsistency != null &&
                !state.trackConsistency!.consistent)
              _row(
                'TRACK STATE',
                'INCONSISTENT — ${state.trackConsistency!.reason ?? 'fix jumps exceed the motion model'}',
                OutrideColors.red,
              ),
            if (t.stitchLabel != null)
              _row(
                  'STITCH',
                  '${t.stitchLabel} — AI ${(t.stitchConfidence! * 100).toStringAsFixed(0)}% SAME MOVER EST',
                  OutrideColors.purple),
          ],
        ],
      ),
    );
  }

  Widget _altitudeBody(TrackEstimate t) {
    if (t.altitudeM == null) {
      return Padding(
        padding: const EdgeInsets.only(left: 116, bottom: 4),
        child: Text(
          'UNKNOWN — NODES ARE COPLANAR. PUT ONE RADIO ON A MAST, ROOF OR HILL TO UNLOCK ALTITUDE.',
          style: OutrideType.section(10).copyWith(height: 1.6),
        ),
      );
    }
    final conf = t.altitudeConfidence;
    final qual = conf < 0.4 ? 'ROUGH' : conf < 0.7 ? 'MODERATE' : 'GOOD';
    return Padding(
      padding: const EdgeInsets.only(left: 116, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '≈ ${t.altitudeM!.toStringAsFixed(1)} M ABOVE GROUND — EST, $qual',
            style: OutrideType.readout(16, OutrideColors.green),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: 180,
            child: LinearProgressIndicator(
              value: conf,
              color: OutrideColors.green,
              backgroundColor: OutrideColors.surface2,
              minHeight: 3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _relationChip(String relation) {
    final color = switch (relation) {
      'INBOUND' || 'OVERHEAD' => OutrideColors.red,
      'OUTBOUND' => OutrideColors.green,
      'TRANSITING' => OutrideColors.amber,
      _ => OutrideColors.muted,
    };
    final icon = switch (relation) {
      'INBOUND' => Icons.arrow_downward,
      'OUTBOUND' => Icons.arrow_upward,
      'OVERHEAD' => Icons.warning_amber_rounded,
      'TRANSITING' => Icons.swap_horiz,
      'HOLDING' => Icons.pause,
      _ => Icons.help_outline,
    };
    return OutrideChip(label: relation, color: color, icon: icon);
  }

  Widget _row(String label, String value, Color color) {
    if (value.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text(label, style: OutrideType.rowLabel()),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 108, child: Text(label, style: OutrideType.rowLabel())),
          Expanded(child: Text(value, style: OutrideType.rowValue(color))),
        ],
      ),
    );
  }

  Future<void> _editCallsign(
      BuildContext context, AppState state, NodePosition n) async {
    final ctl = TextEditingController(text: n.callsign ?? '');
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: OutrideColors.surface2,
          title: Text('CALLSIGN — ${n.nodeId}',
              style: OutrideType.rowValue(OutrideColors.onDark)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('SHOWN OVER THIS NODE ON THE MAP. A-Z 0-9 DASH, UP TO 16 CHARACTERS. EMPTY CLEARS IT.',
                  style: OutrideType.section(10)),
              const SizedBox(height: 10),
              TextField(
                controller: ctl,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                maxLength: 16,
                style: OutrideType.rowValue(OutrideColors.onDark),
                decoration: InputDecoration(
                  hintText: 'e.g. RAPTOR-1',
                  errorText: error,
                  counterText: '',
                ),
                onChanged: (_) => setD(() => error = null),
              ),
              if (n.callsign != null && !n.callsignByUser)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('CURRENTLY FROM THE NODE\u2019S BEACON — TYPING YOUR OWN OVERRIDES IT.',
                      style: OutrideType.section(10)),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('CANCEL'),
            ),
            if (n.callsignByUser)
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(''),
                child: const Text('CLEAR'),
              ),
            ElevatedButton(
              onPressed: () {
                final clean = AppState.cleanCallsign(ctl.text);
                if (ctl.text.trim().isNotEmpty && clean == null) {
                  setD(() => error = 'A-Z 0-9, DASH, UP TO 16 CHARS');
                  return;
                }
                Navigator.of(ctx).pop(ctl.text);
              },
              child: const Text('SAVE'),
            ),
          ],
        ),
      ),
    );
    ctl.dispose();
    if (result != null && context.mounted) {
      final ok = state.setNodeCallsign(n.nodeId, result);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('INVALID CALLSIGN')),
        );
      }
    }
  }

  /// GPS-assisted positioning: walk to each node with the device and tap
  /// the target button — the node's map position is set from the GPS fix,
  /// in meters east/north of the stored origin. The first capture sets
  /// the origin. Fix accuracy is always reported; coarse desktop fixes
  /// are labeled as such, never silently trusted.
  Widget _gpsCard(List<NodePosition> nodes) {
    final origin = state.gpsOrigin;
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title alone on its row: title + button shared a row and
          // overflowed phone-width cards (same class as the FIELD
          // MAP header). Both capture buttons live in one wrap below.
          Text('GPS POSITIONING', style: OutrideType.section()),
          const SizedBox(height: 6),
          Text(
            'WALK TO EACH NODE WITH THIS DEVICE AND TAP THE TARGET BUTTON ON ITS ROW — ITS MAP POSITION IS SET FROM THE GPS FIX. '
            'THE FIRST CAPTURE SETS THE ORIGIN. ON WINDOWS, ENABLE LOCATION IN SETTINGS → PRIVACY & SECURITY → LOCATION.',
            style: OutrideType.section(10).copyWith(height: 1.6),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('ORIGIN  ', style: OutrideType.rowLabel()),
              Expanded(
                child: Text(
                  origin?.label ?? 'NOT SET — FIRST CAPTURE SETS IT',
                  style: OutrideType.rowValue(origin == null
                      ? OutrideColors.muted
                      : OutrideColors.green),
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 4,
            runSpacing: 0,
            children: [
              TextButton(
                style: _toggleStyle,
                onPressed:
                    state.gpsBusy ? null : state.setGpsOriginHere,
                child: const Text('SET ORIGIN HERE'),
              ),
              TextButton(
                style: _toggleStyle,
                onPressed:
                    state.gpsBusy ? null : state.captureDefendedGps,
                child: const Text('SET DEFENDED HERE'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final n in nodes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 88,
                    child: Text(n.callsign ?? shortNodeId(n.nodeId),
                        style:
                            OutrideType.rowValue(OutrideColors.onDark)
                                .copyWith(fontSize: 12),
                        overflow: TextOverflow.ellipsis),
                  ),
                  Expanded(
                    child: Text(n.gpsLabel,
                        style: OutrideType.rowValue(OutrideColors.muted)
                            .copyWith(fontSize: 11),
                        overflow: TextOverflow.ellipsis),
                  ),
                  SizedBox(
                    width: 118,
                    child: Text(
                        '${n.x.toStringAsFixed(1)}, ${n.y.toStringAsFixed(1)} M',
                        style: OutrideType.rowLabel(),
                        textAlign: TextAlign.right),
                  ),
                  IconButton(
                    icon: const Icon(Icons.gps_fixed, size: 18),
                    color: OutrideColors.green,
                    tooltip:
                        'Capture GPS position for ${n.nodeId}',
                    onPressed: state.gpsBusy
                        ? null
                        : () => state.captureNodeGps(n.nodeId),
                  ),
                  IconButton(
                    icon: const Icon(Icons.badge, size: 18),
                    color: OutrideColors.purple,
                    tooltip: 'Set callsign for ${n.nodeId}',
                    onPressed: () => _editCallsign(context, state, n),
                  ),
                ],
              ),
            ),
          if (state.gpsBusy || state.gpsMessage != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                if (state.gpsBusy)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (state.gpsBusy) const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    state.gpsBusy
                        ? 'ACQUIRING GPS FIX…'
                        : (state.gpsMessage ?? ''),
                    style: OutrideType.section(10).copyWith(
                      height: 1.6,
                      color: state.gpsBusy
                          ? OutrideColors.blue
                          : OutrideColors.amber,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _nodeHeightsCard(List<NodePosition> nodes) {    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('NODE HEIGHTS + ANTENNAS', style: OutrideType.section()),
          const SizedBox(height: 6),
          Text(
            'HEIGHT ABOVE GROUND PER NODE. ALTITUDE NEEDS NODES AT DIFFERENT HEIGHTS — A MAST OR ROOFTOP NODE UNLOCKS IT. '
            'SET EACH NODE\'S ANTENNA TYPE FOR THE 3D BEAM VIEW (PANEL AIM AUTO-POINTS AT THE NEAREST NODE).',
            style: OutrideType.section(10).copyWith(height: 1.6),
          ),
          const SizedBox(height: 8),
          for (final n in nodes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 96,
                    child: Text(n.callsign ?? shortNodeId(n.nodeId),
                        style: OutrideType.rowValue(OutrideColors.onDark)
                            .copyWith(fontSize: 12),
                        overflow: TextOverflow.ellipsis),
                  ),
                  SizedBox(
                    width: 92,
                    child: DropdownButton<String>(
                      value: n.antenna,
                      isDense: true,
                      underline: const SizedBox(),
                      dropdownColor: OutrideColors.surface2,
                      style: OutrideType.rowValue(OutrideColors.blue)
                          .copyWith(fontSize: 12),
                      items: const [
                        DropdownMenuItem(
                            value: 'whip', child: Text('WHIP')),
                        DropdownMenuItem(
                            value: 'panel', child: Text('PANEL')),
                      ],
                      onChanged: (v) {
                        if (v != null) state.setNodeAntenna(n.nodeId, v);
                      },
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: n.height.clamp(0.0, 60.0),
                      min: 0,
                      max: 60,
                      divisions: 60,
                      label: '${n.height.toStringAsFixed(0)} m',
                      onChanged: (v) =>
                          state.setNodeHeight(n.nodeId, v),
                    ),
                  ),
                  SizedBox(
                    width: 52,
                    child: Text('${n.height.toStringAsFixed(0)} M',
                        style: OutrideType.rowLabel(),
                        textAlign: TextAlign.right),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TrackScopeNote extends StatelessWidget {
  const _TrackScopeNote();

  @override
  Widget build(BuildContext context) {
    return OutridePanel(
      child: Text(
        'TRACKING HONESTY — ONE TARGET AT A TIME (TWO SIMULTANEOUS MOVERS BLEND INTO ONE ESTIMATE). '
        'POSITION COMES FROM A COARSE 3D TOMOGRAPHIC GRID SEARCH OVER THE DISTURBED LINKS — AN ESTIMATE, NOT A FIX. '
        'ALTITUDE IS THE WEAKEST AXIS AND STAYS "UNKNOWN" UNTIL NODES SIT AT DIFFERENT HEIGHTS. '
        'TYPE GUESSES ARE HEURISTICS, NEVER IDENTIFICATION.',
        style: OutrideType.section(10).copyWith(height: 1.7),
      ),
    );
  }
}

class TrackingMapPainter extends CustomPainter {
  TrackingMapPainter({
    required this.transform,
    required this.nodes,
    required this.disturbedPairs,
    required this.defended,
    required this.track,
    required this.shadow,
    required this.showShadow,
    this.rti = const [],
    this.showRti = true,
    this.showHealth = false,
    this.nodeHealth = const {},
    this.operatorPos,
    this.operatorAccuracyM,
    this.operatorLive = false,
  });

  final FieldMapTransform transform;
  final List<NodePosition> nodes;
  final Set<String> disturbedPairs;
  final DefendedPoint defended;
  final TrackEstimate? track;
  final List<ShadowCell> shadow;
  final bool showShadow;

  /// Fused RTI disturbance image cells ([rtiImageLabel]).
  final List<RtiCell> rti;
  final bool showRti;

  /// When true, node dots are colored by link freshness instead of
  /// driver color. Disturbed nodes still glow amber on top.
  final bool showHealth;
  final Map<String, NodeHealthStatus> nodeHealth;

  /// Live "you are here" marker (v0.28.0, EXPERIMENTAL): operator
  /// position in field meters, or null when there is none to draw.
  /// [operatorAccuracyM] is the live GPS accuracy ring radius in
  /// meters (null = no ring, e.g. the simulated marker).
  /// [operatorLive] distinguishes the live fix (green) from the
  /// simulated fallback (blue, labeled SIM).
  final ({double x, double y})? operatorPos;
  final double? operatorAccuracyM;
  final bool operatorLive;

  static String _pairKey(String a, String b) {
    final ids = [a, b]..sort();
    return '${ids[0]}|${ids[1]}';
  }

  @override
  void paint(Canvas canvas, Size size) {
    final tr = transform;

    // Faint 10 m grid.
    final gridPaint = Paint()
      ..color = OutrideColors.border.withAlpha(80)
      ..strokeWidth = 1;
    final x0 = tr.toWorldX(0), x1 = tr.toWorldX(size.width);
    final y0 = tr.toWorldY(size.height), y1 = tr.toWorldY(0);
    for (var gx = (x0 / 10).floor() * 10.0; gx <= x1; gx += 10) {
      canvas.drawLine(
          tr.toScreen(gx, y0), tr.toScreen(gx, y1), gridPaint);
    }
    for (var gy = (y0 / 10).floor() * 10.0; gy <= y1; gy += 10) {
      canvas.drawLine(
          tr.toScreen(x0, gy), tr.toScreen(x1, gy), gridPaint);
    }

    // Field boundary: convex hull of the nodes, lit in purple so the
    // watched area reads at a glance.
    if (nodes.length >= 2) {
      final hull =
          convexHull([for (final n in nodes) math.Point(n.x, n.y)]);
      final pts = [for (final h in hull) tr.toScreen(h.x, h.y)];
      final halo = Paint()
        ..color = OutrideColors.purple.withAlpha(45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      final edge = Paint()
        ..color = OutrideColors.purple.withAlpha(190)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      if (pts.length == 2) {
        canvas.drawLine(pts[0], pts[1], halo);
        canvas.drawLine(pts[0], pts[1], edge);
      } else if (pts.length >= 3) {
        final path = Path()..addPolygon(pts, true);
        canvas.drawPath(path, halo);
        canvas.drawPath(path, edge);
      }
    }

    // Shadow heat, pinned to the intruder: only cells near the current
    // track glow. No track, no heat — the lit boundary above carries the
    // "where we watch" information on its own.
    final t0 = track;
    if (showShadow && t0 != null && shadow.isNotEmpty) {
      // Heat halo radius in meters: gaussian falloff around the track.
      const sigmaM = 14.0;
      double falloff(ShadowCell c) {
        final dx = c.x - t0.x, dy = c.y - t0.y;
        return math.exp(-(dx * dx + dy * dy) / (2 * sigmaM * sigmaM));
      }

      // Overlapping soft discs so cells blend into one continuous shadow.
      final r = 2.5 * tr.scale * 0.85;
      for (final c in shadow) {
        final fall = falloff(c);
        if (fall < 0.03) continue;
        final p = tr.toScreen(c.x, c.y);
        canvas.drawCircle(
            p,
            r,
            Paint()
              ..color = OutrideColors.amber
                  .withAlpha((c.v * 130 * fall).round()));
      }
      // Hot core: redraw the strongest cells brighter for definition.
      for (final c in shadow) {
        if (c.v < 0.55) continue;
        final fall = falloff(c);
        if (fall < 0.03) continue;
        canvas.drawCircle(
            tr.toScreen(c.x, c.y),
            r * 0.55,
            Paint()
              ..color = OutrideColors.orange
                  .withAlpha((c.v * 150 * fall).round()));
      }
    }

    // Fused RTI disturbance image (rti_imaging_weights_spec): purple
    // probability-mass discs, drawn under the track dot. This is the
    // estimated disturbance location (ground projection) — never a
    // located object.
    if (showRti && rti.isNotEmpty) {
      final rr = 2.2 * tr.scale * 0.85;
      for (final c in rti) {
        canvas.drawCircle(
            tr.toScreen(c.x, c.y),
            rr,
            Paint()
              ..color =
                  OutrideColors.purple.withAlpha((c.v * 110).round()));
      }
      for (final c in rti) {
        if (c.v < 0.55) continue;
        canvas.drawCircle(
            tr.toScreen(c.x, c.y),
            rr * 0.55,
            Paint()
              ..color =
                  OutrideColors.purple.withAlpha((c.v * 170).round()));
      }
    }

    // Links between every pair of nodes.
    final faintLink = Paint()
      ..color = OutrideColors.border
      ..strokeWidth = 1.5;
    final hotLink = Paint()
      ..color = OutrideColors.amber.withAlpha(220)
      ..strokeWidth = 3;
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        final a = tr.toScreen(nodes[i].x, nodes[i].y);
        final b = tr.toScreen(nodes[j].x, nodes[j].y);
        final hot = disturbedPairs
            .contains(_pairKey(nodes[i].nodeId, nodes[j].nodeId));
        canvas.drawLine(a, b, hot ? hotLink : faintLink);
      }
    }

    // Defended point: red crosshair.
    final dp = tr.toScreen(defended.x, defended.y);
    final dpPaint = Paint()
      ..color = OutrideColors.red
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(dp, 11, dpPaint);
    canvas.drawLine(
        dp + const Offset(-17, 0), dp + const Offset(17, 0), dpPaint);
    canvas.drawLine(
        dp + const Offset(0, -17), dp + const Offset(0, 17), dpPaint);

    // Line from defended point to track.
    final t = track;
    if (t != null) {
      final tp = tr.toScreen(t.x, t.y);
      canvas.drawLine(
          dp,
          tp,
          Paint()
            ..color = OutrideColors.red.withAlpha(100)
            ..strokeWidth = 1.5);
    }

    // Nodes — driver-colored dots (one unified map for all radios),
    // amber when disturbed. With the health overlay on, the base color
    // is link freshness instead of driver color.
    final disturbedNodes = <String>{};
    for (final key in disturbedPairs) {
      disturbedNodes.addAll(key.split('|'));
    }
    for (final n in nodes) {
      final p = tr.toScreen(n.x, n.y);
      final hot = disturbedNodes.contains(n.nodeId);
      final healthColor = switch (nodeHealth[n.nodeId]) {
        NodeHealthStatus.ok => OutrideColors.green,
        NodeHealthStatus.degraded => OutrideColors.amber,
        NodeHealthStatus.dead => OutrideColors.red,
        _ => OutrideColors.muted,
      };
      final base =
          showHealth ? healthColor : driverColor(driverOf(n.nodeId));
      final color = hot ? OutrideColors.amber : base;
      canvas.drawCircle(p, 14, Paint()..color = color.withAlpha(45));
      canvas.drawCircle(p, 8, Paint()..color = color.withAlpha(140));
      canvas.drawCircle(p, 4.5, Paint()..color = color);
      _label(canvas, n.callsign ?? shortNodeId(n.nodeId), p + const Offset(16, -24),
          OutrideColors.onDark);
      if (n.height >= 0.5) {
        _label(canvas, '${n.height.toStringAsFixed(0)}m',
            p + const Offset(16, -10), OutrideColors.muted);
      }
    }

    // Track dot — amber glow with white core.
    if (t != null) {
      final p = tr.toScreen(t.x, t.y);
      canvas.drawCircle(
          p, 18, Paint()..color = OutrideColors.amber.withAlpha(50));
      canvas.drawCircle(
          p, 10, Paint()..color = OutrideColors.amber.withAlpha(160));
      canvas.drawCircle(p, 5, Paint()..color = Colors.white);
      _label(canvas, 'TRACK', p + const Offset(16, 6),
          OutrideColors.amber);
      // Heading arrow — points along the track's compass heading
      // (0° = N = screen-up). Drawn only once the target has moved
      // enough for a heading estimate to exist.
      final hd = t.headingDeg;
      if (hd != null) {
        final a = hd * math.pi / 180;
        final dir = Offset(math.sin(a), -math.cos(a));
        final arrowPaint = Paint()
          ..color = OutrideColors.amber
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round;
        final tip = p + dir * 30;
        final base = p + dir * 14;
        canvas.drawLine(base, tip, arrowPaint);
        final perp = Offset(-dir.dy, dir.dx);
        canvas.drawLine(
            tip, tip - dir * 8 + perp * 4.5, arrowPaint);
        canvas.drawLine(
            tip, tip - dir * 8 - perp * 4.5, arrowPaint);
      }
    }

    // Operator marker (v0.28.0 live GPS, EXPERIMENTAL): "you are
    // here", drawn last so it sits on top of tracks and nodes. The
    // accuracy ring is the live GPS accuracy in meters, scaled to
    // screen pixels; the simulated marker has no ring and is
    // labeled SIM so it is never mistaken for a real fix.
    final op = operatorPos;
    if (op != null) {
      final p = tr.toScreen(op.x, op.y);
      final color =
          operatorLive ? OutrideColors.green : OutrideColors.blue;
      final acc = operatorAccuracyM;
      if (operatorLive && acc != null && acc > 0) {
        final rPx = acc * tr.scale;
        if (rPx >= 3) {
          canvas.drawCircle(
              p, rPx, Paint()..color = color.withAlpha(18));
          canvas.drawCircle(
              p,
              rPx,
              Paint()
                ..color = color.withAlpha(90)
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.5);
        }
      }
      canvas.drawCircle(p, 12, Paint()..color = color.withAlpha(45));
      canvas.drawCircle(p, 7, Paint()..color = color.withAlpha(160));
      canvas.drawCircle(p, 4, Paint()..color = Colors.white);
      _label(canvas, operatorLive ? 'YOU' : 'YOU · SIM',
          p + const Offset(16, 6), color);
    }
  }

  void _label(Canvas canvas, String text, Offset at, Color color) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontFamily: OutrideType.mono,
            letterSpacing: 1.2,
          )),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant TrackingMapPainter old) => true;
}

/// Compass rose overlay for the tracking map. The map is north-up, so
/// this is a fixed orientation reference — not a live magnetometer
/// reading. Kept static on purpose: no new sensor permissions, no
/// calibration UX, nothing to go wrong in the field.
class _CompassRose extends StatelessWidget {
  const _CompassRose();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: OutrideColors.surface2.withAlpha(210),
        border: Border.all(color: OutrideColors.border, width: 1),
      ),
      child: CustomPaint(painter: _CompassRosePainter()),
    );
  }
}

class _CompassRosePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 3;

    // Tick marks every 45°; cardinal ticks run longer.
    final tickPaint = Paint()
      ..color = OutrideColors.muted
      ..strokeWidth = 1.5;
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      final dir = Offset(math.sin(a), -math.cos(a));
      final inner = i % 2 == 0 ? r - 8 : r - 5;
      canvas.drawLine(c + dir * inner, c + dir * r, tickPaint);
    }

    // North pointer triangle.
    final northPaint = Paint()..color = OutrideColors.amber;
    canvas.drawPath(
      Path()
        ..moveTo(c.dx, c.dy - r + 2)
        ..lineTo(c.dx - 4.5, c.dy - 8)
        ..lineTo(c.dx + 4.5, c.dy - 8)
        ..close(),
      northPaint,
    );

    _cardinal(canvas, c, r, 'N', 0, OutrideColors.amber);
    _cardinal(canvas, c, r, 'E', 90, OutrideColors.onDark);
    _cardinal(canvas, c, r, 'S', 180, OutrideColors.muted);
    _cardinal(canvas, c, r, 'W', 270, OutrideColors.muted);
  }

  void _cardinal(Canvas canvas, Offset c, double r, String label,
      double deg, Color color) {
    final a = deg * math.pi / 180;
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          fontFamily: OutrideType.mono,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final pos =
        c + Offset(math.sin(a), -math.cos(a)) * (r - 15);
    tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _CompassRosePainter old) => false;
}

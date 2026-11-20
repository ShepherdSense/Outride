/// Offline map packs screen (Outride v0.28.0, EXPERIMENTAL).
///
/// Two tiers, one tile fetcher (see
/// `~/workspace/research_notes/outride-tile-packs.md`):
///
/// * Tier 1 — state pack: one tap per US state (+ DC), whole state
///   at zoom 0–12. The base map a team loads once when they join.
/// * Tier 2 — area pack: center + size around the search area, zoom
///   0–16 (capped — USGS Topo and Imagery both top out at level
///   16), built per mission on the device.
///
/// Every estimate is shown BEFORE the download starts (tile count +
/// ~MB at 20 KB/tile typical). Packs download from USGS endpoints
/// only — the store refuses any other source, because OSM Standard
/// and Esri World Imagery prohibit bulk / offline downloading.
///
/// Reached from Settings → "OFFLINE MAP PACKS" and from the Field
/// map header ("OFFLINE MAPS").
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/geo_projection.dart';
import '../services/offline_map_source.dart';
import '../services/tile_pack.dart';
import '../services/tile_pack_store.dart';
import '../state/app_state.dart';
import '../theme.dart';

class OfflineMapsScreen extends StatefulWidget {
  const OfflineMapsScreen({super.key, required this.state});

  final AppState state;

  @override
  State<OfflineMapsScreen> createState() => _OfflineMapsScreenState();
}

class _OfflineMapsScreenState extends State<OfflineMapsScreen> {
  final _areaName = TextEditingController(text: 'SEARCH AREA');
  final _areaWidthKm = TextEditingController(text: '20');
  final _areaHeightKm = TextEditingController(text: '20');
  final _customLat = TextEditingController();
  final _customLon = TextEditingController();
  String _areaCenterMode = 'defended';
  int _areaMaxZoom = kAreaPackDefaultMaxZoom;
  String _areaSourceId = 'usgs_topo';

  AppState get state => widget.state;
  TilePackStore get store => widget.state.tilePacks;

  @override
  void dispose() {
    _areaName.dispose();
    _areaWidthKm.dispose();
    _areaHeightKm.dispose();
    _customLat.dispose();
    _customLon.dispose();
    super.dispose();
  }

  /// Resolved area-pack center for the current center mode, or null
  /// when it cannot be resolved yet (no origin / no defended point
  /// / unparsable custom coordinates).
  ({double lat, double lon})? _areaCenter() {
    switch (_areaCenterMode) {
      case 'defended':
        final origin = state.displayOrigin;
        if (origin == null) return null;
        final geo =
            GeoProjection(originLat: origin.lat, originLon: origin.lon);
        final ll = geo.metersToLatLon(state.defended.x, state.defended.y);
        return (lat: ll.lat, lon: ll.lon);
      case 'origin':
        final origin = state.gpsOrigin;
        if (origin == null) return null;
        return (lat: origin.lat, lon: origin.lon);
      default:
        final lat = double.tryParse(_customLat.text.trim());
        final lon = double.tryParse(_customLon.text.trim());
        if (lat == null || lon == null) return null;
        if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
        return (lat: lat, lon: lon);
    }
  }

  ({double north, double south, double west, double east})? _areaBounds() {
    final center = _areaCenter();
    if (center == null) return null;
    final wKm = double.tryParse(_areaWidthKm.text.trim());
    final hKm = double.tryParse(_areaHeightKm.text.trim());
    if (wKm == null || hKm == null || wKm <= 0 || hKm <= 0) return null;
    final halfLatDeg = (hKm / 2) / 110.54;
    final halfLonDeg = (wKm / 2) /
        (111.32 * math.cos(center.lat * math.pi / 180.0));
    return (
      north: center.lat + halfLatDeg,
      south: center.lat - halfLatDeg,
      west: center.lon - halfLonDeg,
      east: center.lon + halfLonDeg,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('OFFLINE MAP PACKS')),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final packs = store.packs;
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _headerCard(packs.length),
              const SizedBox(height: 12),
              if (packs.isNotEmpty) ...[
                _downloadedSection(packs),
                const SizedBox(height: 12),
              ],
              _statePackSection(packs),
              const SizedBox(height: 12),
              _areaPackSection(),
              const SizedBox(height: 12),
              _footerNote(),
            ],
          );
        },
      ),
    );
  }

  Widget _headerCard(int packCount) {
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('OFFLINE MAP PACKS — EXPERIMENTAL',
              style: OutrideType.section()),
          const SizedBox(height: 6),
          Text(
            'DOWNLOAD A MAP BEFORE YOU LEAVE WI-FI. THE FIELD MAP '
            'THEN RENDERS FROM THE PACK WITH NO CONNECTIVITY. TILES: '
            'USGS NATIONAL MAP (U.S. PUBLIC DOMAIN — FREE, NO '
            'RESTRICTIONS). OSM STANDARD AND ESRI ARE NOT OFFERED '
            'FOR PACKS: THEIR TERMS PROHIBIT BULK / OFFLINE '
            'DOWNLOADING.',
            style: OutrideType.section(10).copyWith(height: 1.6),
          ),
          const SizedBox(height: 8),
          Text(
            store.supported
                ? '$packCount PACK${packCount == 1 ? '' : 'S'} · '
                    '${formatBytes(store.totalBytes)} ON DISK'
                : 'TILE PACKS ARE NOT AVAILABLE ON WEB — THE MAP '
                    'RENDERS THE FIELD CANVAS ONLY.',
            style: OutrideType.rowValue(store.supported
                ? OutrideColors.green
                : OutrideColors.amber),
          ),
        ],
      ),
    );
  }

  Widget _downloadedSection(List<TilePackMeta> packs) {
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('DOWNLOADED PACKS', style: OutrideType.section()),
          const SizedBox(height: 8),
          for (final pack in packs) ...[
            _packRow(pack),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _packRow(TilePackMeta pack) {
    final statusText = switch (pack.status) {
      TilePackStatus.downloading =>
        'DOWNLOADING — ${pack.downloadedTiles} / ${pack.expectedTiles} TILES '
            '(${(pack.progress * 100).toStringAsFixed(0)}%)',
      TilePackStatus.paused =>
        'PAUSED — ${pack.downloadedTiles} / ${pack.expectedTiles} TILES',
      TilePackStatus.complete =>
        '${pack.expectedTiles} TILES · ${formatBytes(pack.bytesOnDisk)}',
      TilePackStatus.error => pack.error ?? 'DOWNLOAD FAILED',
    };
    final statusColor = switch (pack.status) {
      TilePackStatus.complete => OutrideColors.green,
      TilePackStatus.error => OutrideColors.red,
      TilePackStatus.paused => OutrideColors.amber,
      TilePackStatus.downloading => OutrideColors.blue,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                pack.displayName,
                style: OutrideType.rowValue(OutrideColors.onDark),
              ),
            ),
            Text(
              pack.kind == TilePackKind.state ? 'STATE' : 'AREA',
              style: OutrideType.section(10)
                  .copyWith(color: OutrideColors.muted),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          '${pack.sourceId.toUpperCase()} · Z${pack.minZoom}–${pack.maxZoom}',
          style: OutrideType.section(10),
        ),
        const SizedBox(height: 4),
        if (pack.status == TilePackStatus.downloading)
          LinearProgressIndicator(
            value: pack.progress,
            color: OutrideColors.purple,
            backgroundColor: OutrideColors.surface2,
            minHeight: 4,
          ),
        if (pack.status == TilePackStatus.downloading)
          const SizedBox(height: 4),
        Text(statusText,
            style: OutrideType.section(10).copyWith(color: statusColor)),
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          children: [
            if (pack.status == TilePackStatus.downloading) ...[
              TextButton(
                onPressed: () => store.pausePack(pack.id),
                child: const Text('PAUSE'),
              ),
              TextButton(
                onPressed: () => store.cancelPack(pack.id),
                child: const Text('CANCEL'),
              ),
            ],
            if (pack.status == TilePackStatus.paused ||
                pack.status == TilePackStatus.error)
              TextButton(
                onPressed: () => store.resumePack(pack.id),
                child: const Text('RESUME'),
              ),
            TextButton(
              onPressed: () => _confirmDelete(pack),
              child: const Text('DELETE'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _confirmDelete(TilePackMeta pack) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: OutrideColors.surface2,
        title: Text('DELETE ${pack.displayName}?',
            style: OutrideType.rowValue(OutrideColors.onDark)),
        content: Text(
          'THE PACK FILE IS DELETED FROM THIS DEVICE. RE-DOWNLOAD '
          'TO GET IT BACK.',
          style: OutrideType.section(10),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('DELETE'),
          ),
        ],
      ),
    );
    if (ok == true) await store.deletePack(pack.id);
  }

  Widget _statePackSection(List<TilePackMeta> packs) {
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('STATE PACKS — TIER 1 (BASE)', style: OutrideType.section()),
          const SizedBox(height: 6),
          Text(
            'ONE TAP PER STATE. WHOLE STATE AT ZOOM 0–12 — STAGING, '
            'DRIVING, MUTUAL AID. A WHOLE STATE AT STREET-LEVEL '
            'ZOOM 16 IS GIGABYTES AND IS NOT THE PLAN: THE STATE '
            'PACK IS THE BASE MAP, THE AREA PACK BELOW CARRIES THE '
            'DETAIL. SEARCHING NEAR A STATE LINE? GRAB THE '
            'NEIGHBORING STATE TOO — EACH IS CHEAP AT MEDIUM ZOOM.',
            style: OutrideType.section(10).copyWith(height: 1.6),
          ),
          const SizedBox(height: 8),
          for (final def in kStatePackDefs)
            _stateRow(def, packs),
        ],
      ),
    );
  }

  Widget _stateRow(StatePackDef def, List<TilePackMeta> packs) {
    final existing =
        store.packById('state_${def.abbr.toLowerCase()}');
    final bounds = statePackBounds(def);
    final tiles = tileCountForBounds(
      bounds.north,
      bounds.south,
      bounds.west,
      bounds.east,
      kStatePackMinZoom,
      kStatePackMaxZoom,
    );
    final estimate = def.oneTap
        ? '$tiles TILES · EST. ${formatBytes(estimateBytesForTiles(tiles))}'
        : 'SPANS THE DATELINE — TOO LARGE FOR ONE TAP';
    final largeNote = def.oneTap && tiles > 25000 ? ' — LARGE, USE WI-FI' : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${def.name.toUpperCase()} (${def.abbr})',
                  style: OutrideType.rowValue(OutrideColors.onDark)
                      .copyWith(fontSize: 12),
                ),
                Text(
                  existing != null
                      ? _packStatusLine(existing)
                      : '$estimate$largeNote',
                  style: OutrideType.section(10).copyWith(
                    color: existing != null
                        ? OutrideColors.green
                        : OutrideColors.muted,
                  ),
                ),
              ],
            ),
          ),
          if (!store.supported)
            Text('NOT ON WEB', style: OutrideType.section(10))
          else if (!def.oneTap)
            Text('USE AN AREA PACK', style: OutrideType.section(10))
          else if (existing == null)
            TextButton(
              onPressed: () => store.startStatePack(
                def,
                selectTileSource('usgs_topo'),
              ),
              child: const Text('DOWNLOAD'),
            )
          else if (existing.status == TilePackStatus.downloading)
            TextButton(
              onPressed: () => store.pausePack(existing.id),
              child: const Text('PAUSE'),
            )
          else if (existing.status == TilePackStatus.paused ||
              existing.status == TilePackStatus.error)
            TextButton(
              onPressed: () => store.resumePack(existing.id),
              child: const Text('RESUME'),
            )
          else
            TextButton(
              onPressed: () => _confirmDelete(existing),
              child: const Text('DELETE'),
            ),
        ],
      ),
    );
  }

  String _packStatusLine(TilePackMeta pack) {
    return switch (pack.status) {
      TilePackStatus.complete =>
        'DOWNLOADED · ${formatBytes(pack.bytesOnDisk)}',
      TilePackStatus.downloading =>
        'DOWNLOADING ${(pack.progress * 100).toStringAsFixed(0)}%',
      TilePackStatus.paused => 'PAUSED',
      TilePackStatus.error => 'ERROR — TAP RESUME TO RETRY',
    };
  }

  Widget _areaPackSection() {
    final bounds = _areaBounds();
    final center = _areaCenter();
    final tiles = bounds == null
        ? 0
        : tileCountForBounds(
            bounds.north,
            bounds.south,
            bounds.west,
            bounds.east,
            kAreaPackMinZoom,
            _areaMaxZoom,
          );
    final tooBig = tiles > 100000;
    final large = tiles > 25000;
    // USGS covers the US only — a pack centered outside coverage
    // fetches nothing, so the download is refused here instead of
    // failing tile-by-tile (see [usgsCovers]).
    final outsideCoverage =
        center != null && !usgsCovers(center.lat, center.lon);
    final canDownload = store.supported &&
        bounds != null &&
        tiles > 0 &&
        !tooBig &&
        !outsideCoverage;
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('AREA PACK — TIER 2 (DETAIL)', style: OutrideType.section()),
          const SizedBox(height: 6),
          Text(
            'A RECTANGLE AROUND THE SEARCH AREA, UP TO ZOOM 16. '
            'Z17 IS NOT OFFERED — USGS TOPO AND IMAGERY BOTH TOP '
            'OUT AT LEVEL 16, SO A Z17 PACK COULD NEVER COMPLETE. '
            'THIS IS WHERE THE FIELD DETAIL LIVES. THE SIZE '
            'ESTIMATE UPDATES AS YOU TYPE — NOTHING DOWNLOADS '
            'UNTIL YOU TAP DOWNLOAD.',
            style: OutrideType.section(10).copyWith(height: 1.6),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _areaName,
            textCapitalization: TextCapitalization.characters,
            style: OutrideType.rowValue(OutrideColors.onDark),
            decoration: const InputDecoration(labelText: 'PACK NAME'),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _areaCenterMode,
            dropdownColor: OutrideColors.surface2,
            style: OutrideType.rowValue(OutrideColors.onDark),
            decoration: const InputDecoration(labelText: 'CENTER ON'),
            items: const [
              DropdownMenuItem(
                  value: 'defended', child: Text('DEFENDED POINT')),
              DropdownMenuItem(value: 'origin', child: Text('GPS ORIGIN')),
              DropdownMenuItem(
                  value: 'custom', child: Text('CUSTOM LAT / LON')),
            ],
            onChanged: (v) =>
                setState(() => _areaCenterMode = v ?? 'defended'),
          ),
          if (_areaCenterMode == 'custom') ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _customLat,
                    keyboardType: const TextInputType.numberWithOptions(
                        signed: true, decimal: true),
                    style: OutrideType.rowValue(OutrideColors.onDark),
                    decoration:
                        const InputDecoration(labelText: 'LATITUDE'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _customLon,
                    keyboardType: const TextInputType.numberWithOptions(
                        signed: true, decimal: true),
                    style: OutrideType.rowValue(OutrideColors.onDark),
                    decoration:
                        const InputDecoration(labelText: 'LONGITUDE'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
          ],
          if (center != null) ...[
            const SizedBox(height: 6),
            Text(
              'CENTER: ${center.lat.toStringAsFixed(5)}, '
              '${center.lon.toStringAsFixed(5)}',
              style: OutrideType.section(10),
            ),
          ],
          if (center == null) ...[
            const SizedBox(height: 6),
            Text(
              'NO CENTER YET — SET A GPS ORIGIN, PLACE THE DEFENDED '
              'POINT, OR PICK CUSTOM LAT / LON.',
              style: OutrideType.section(10)
                  .copyWith(color: OutrideColors.amber),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _areaWidthKm,
                  keyboardType: TextInputType.number,
                  style: OutrideType.rowValue(OutrideColors.onDark),
                  decoration:
                      const InputDecoration(labelText: 'WIDTH (KM)'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _areaHeightKm,
                  keyboardType: TextInputType.number,
                  style: OutrideType.rowValue(OutrideColors.onDark),
                  decoration:
                      const InputDecoration(labelText: 'HEIGHT (KM)'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            children: [
              for (final (label, w, h) in [
                ('10 × 10 KM', '10', '10'),
                ('20 × 20 KM', '20', '20'),
                ('40 × 40 KM', '40', '40'),
              ])
                TextButton(
                  onPressed: () => setState(() {
                    _areaWidthKm.text = w;
                    _areaHeightKm.text = h;
                  }),
                  child: Text(label),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: _areaMaxZoom,
                  dropdownColor: OutrideColors.surface2,
                  style: OutrideType.rowValue(OutrideColors.onDark),
                  decoration:
                      const InputDecoration(labelText: 'MAX ZOOM'),
                  items: const [
                    DropdownMenuItem(value: 16, child: Text('16')),
                  ],
                  onChanged: (v) =>
                      setState(() => _areaMaxZoom = v ?? 16),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _areaSourceId,
                  dropdownColor: OutrideColors.surface2,
                  style: OutrideType.rowValue(OutrideColors.onDark),
                  decoration:
                      const InputDecoration(labelText: 'MAP STYLE'),
                  items: const [
                    DropdownMenuItem(
                        value: 'usgs_topo', child: Text('USGS TOPO')),
                    DropdownMenuItem(
                        value: 'usgs_imagery',
                        child: Text('USGS IMAGERY')),
                  ],
                  onChanged: (v) =>
                      setState(() => _areaSourceId = v ?? 'usgs_topo'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            bounds == null
                ? 'SIZE ESTIMATE: —'
                : 'SIZE ESTIMATE: $tiles TILES · EST. '
                    '${formatBytes(estimateBytesForTiles(tiles))}',
            style: OutrideType.rowValue(
              tooBig
                  ? OutrideColors.red
                  : large
                      ? OutrideColors.amber
                      : OutrideColors.green,
            ),
          ),
          if (tooBig)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'OVER THE 100,000-TILE USGS EXPORT CAP — SHRINK THE '
                'AREA OR LOWER THE MAX ZOOM.',
                style: OutrideType.section(10)
                    .copyWith(color: OutrideColors.red),
              ),
            ),
          if (large && !tooBig)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'LARGE DOWNLOAD — USE WI-FI.',
                style: OutrideType.section(10)
                    .copyWith(color: OutrideColors.amber),
              ),
            ),
          if (outsideCoverage)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'OUTSIDE USGS COVERAGE — THIS PACK WILL FETCH '
                'NOTHING. USGS TOPO AND IMAGERY COVER THE UNITED '
                'STATES ONLY; MOVE THE CENTER INSIDE THE US.',
                style: OutrideType.section(10)
                    .copyWith(color: OutrideColors.red),
              ),
            ),
          const SizedBox(height: 10),
          ElevatedButton(
            onPressed: canDownload ? _downloadAreaPack : null,
            child: const Text('DOWNLOAD AREA PACK'),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadAreaPack() async {
    final bounds = _areaBounds();
    if (bounds == null) return;
    // Belt-and-braces: the button is disabled outside coverage,
    // but never start a pack that fetches nothing.
    final center = _areaCenter();
    if (center != null && !usgsCovers(center.lat, center.lon)) return;
    final name = _areaName.text.trim().isEmpty
        ? 'AREA PACK'
        : _areaName.text.trim();
    await store.startAreaPack(
      name: name,
      source: selectTileSource(_areaSourceId),
      north: bounds.north,
      south: bounds.south,
      west: bounds.west,
      east: bounds.east,
      maxZoom: _areaMaxZoom,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('AREA PACK DOWNLOAD STARTED')),
      );
    }
  }

  Widget _footerNote() {
    return OutridePanel(
      child: Text(
        'PACKS LIVE IN THE APP DOCUMENTS FOLDER (tile_packs/) AS ONE '
        '.mbtiles FILE EACH. A PACK IS A SNAPSHOT — RE-DOWNLOAD TO '
        'REFRESH IT. A STATE PACK IS IDENTICAL FOR EVERYONE IN THE '
        'STATE, SO IT CAN BE PRE-BUILT ONCE AND SHARED; AREA PACKS '
        'ARE BUILT PER MISSION ON THIS DEVICE. USGS TOPO / IMAGERY '
        'COVER THE UNITED STATES ONLY.',
        style: OutrideType.section(10).copyWith(height: 1.6),
      ),
    );
  }
}

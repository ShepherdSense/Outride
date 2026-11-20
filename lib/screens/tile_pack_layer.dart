/// Tile-pack layer for the Field map (Outride v0.28.0, EXPERIMENTAL).
///
/// Renders downloaded MBTiles packs UNDER the existing field overlay.
/// The overlay (nodes, links, defended point, track, drag handling,
/// zoom) is untouched — tiles are background only, painted by a
/// plain [CustomPaint] as the first child of the map's [Stack].
///
/// What renders, and what does not:
/// * One pack per view (the first [TilePackStore.renderPacks] entry
///   whose bounds contain the view center — area packs first by
///   maxZoom desc, then state packs). No blending in v1.
/// * Best zoom from [bestZoomForView], clamped to the pack's zooms.
/// * Tiles are read from the pack DB, decoded to [ui.Image], and
///   cached in memory (max 128 images, oldest dropped first).
/// * A missing tile renders as NOTHING — the field canvas's own
///   10 m grid shows through. Never a crash, never an invented map.
/// * No packs / no origin / web / a view the packs do not cover:
///   the layer paints nothing and the map is exactly the field
///   canvas it always was.
///
/// Projection note: tile bounds are Web-Mercator lat/lon, projected
/// through the [GeoProjection] anchored on the display origin — the
/// same equirectangular approximation the overlays already use. Over
/// field-sized views the error is sub-pixel; a low-zoom state tile
/// (tens of km wide) may sit a few pixels off its true spot when the
/// view is zoomed far out. That is the documented v1 tradeoff, not a
/// silent correction.
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/geo_projection.dart';
import '../services/gps_positioning.dart';
import '../services/offline_map_source.dart';
import '../services/tile_pack.dart';
import '../services/tile_pack_store.dart';
import '../utils/field_map_transform.dart';

/// What the tile layer is currently rendering, for the map status
/// line. [packName] is null when no pack covers the view.
class TileLayerStatus {
  const TileLayerStatus({this.packName, this.zoom, this.tilesLoaded = 0});

  final String? packName;
  final int? zoom;
  final int tilesLoaded;

  bool get hasTiles => packName != null;

  @override
  bool operator ==(Object other) =>
      other is TileLayerStatus &&
      packName == other.packName &&
      zoom == other.zoom &&
      tilesLoaded == other.tilesLoaded;

  @override
  int get hashCode => Object.hash(packName, zoom, tilesLoaded);
}

/// Max tiles fetched for one view. A field-sized view needs a
/// handful; past this the user is zoomed too far out for packs and
/// the layer paints nothing instead of hammering the DB.
const int kTileLayerMaxTilesPerView = 100;

/// Max decoded tile images held in memory.
const int kTileLayerMaxCachedImages = 128;

class TilePackMapLayer extends StatefulWidget {
  const TilePackMapLayer({
    super.key,
    required this.transform,
    required this.origin,
    required this.size,
    required this.tilePacks,
    this.onStatus,
  });

  final FieldMapTransform transform;
  final GpsOrigin origin;
  final Size size;
  final TilePackStore tilePacks;

  /// Fired (post-frame, only when changed) with what the layer is
  /// rendering, so the map status line can say so.
  final ValueChanged<TileLayerStatus>? onStatus;

  @override
  State<TilePackMapLayer> createState() => _TilePackMapLayerState();
}

class _TilePackMapLayerState extends State<TilePackMapLayer> {
  final Map<String, ui.Image> _images = {};
  final Set<String> _loading = {};
  String _signature = '';
  TileLayerStatus _lastStatus = const TileLayerStatus();
  List<TileCoord> _viewTiles = [];
  String? _viewPackId;
  int? _viewZoom;

  @override
  void initState() {
    super.initState();
    widget.tilePacks.addListener(_onPacksChanged);
  }

  @override
  void didUpdateWidget(covariant TilePackMapLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tilePacks != widget.tilePacks) {
      oldWidget.tilePacks.removeListener(_onPacksChanged);
      widget.tilePacks.addListener(_onPacksChanged);
    }
  }

  void _onPacksChanged() {
    // Pack set changed (a download finished, a pack was deleted):
    // the signature recomputes on the next build and reloads.
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.tilePacks.removeListener(_onPacksChanged);
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    super.dispose();
  }

  String _signatureFor() {
    final packs = widget.tilePacks.renderPacks
        .map((p) => '${p.id}:${p.status.name}:${p.maxZoom}')
        .join(',');
    final t = widget.transform;
    return '${t.scale.toStringAsFixed(3)}|${t.ox.toStringAsFixed(1)}|'
        '${t.oy.toStringAsFixed(1)}|'
        '${widget.size.width.toStringAsFixed(0)}x'
        '${widget.size.height.toStringAsFixed(0)}|'
        '${widget.origin.lat.toStringAsFixed(6)}|'
        '${widget.origin.lon.toStringAsFixed(6)}|$packs';
  }

  @override
  Widget build(BuildContext context) {
    final sig = _signatureFor();
    if (sig != _signature) {
      _signature = sig;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadForView();
      });
    }
    return CustomPaint(
      size: widget.size,
      painter: _TilePackPainter(placements: _placements()),
    );
  }

  List<TilePlacement> _placements() {
    if (_viewPackId == null || _viewZoom == null) return const [];
    final geo = GeoProjection(
      originLat: widget.origin.lat,
      originLon: widget.origin.lon,
    );
    final out = <TilePlacement>[];
    for (final coord in _viewTiles) {
      final image = _images['$_viewPackId|${coord.z}|${coord.x}|${coord.y}'];
      if (image == null) continue;
      final b = tileBounds(coord);
      final nw = geo.latLonToMeters(b.north, b.west);
      final se = geo.latLonToMeters(b.south, b.east);
      final topLeft = widget.transform.toScreen(nw.x, nw.y);
      final bottomRight = widget.transform.toScreen(se.x, se.y);
      out.add(TilePlacement(
        rect: Rect.fromPoints(topLeft, bottomRight),
        coord: coord,
        image: image,
      ));
    }
    return out;
  }

  void _reportStatus(TileLayerStatus status) {
    if (status == _lastStatus) return;
    _lastStatus = status;
    final cb = widget.onStatus;
    if (cb != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) cb(status);
      });
    }
  }

  Future<void> _loadForView() async {
    final store = widget.tilePacks;
    if (!store.supported) {
      _setView(null, null, const []);
      _reportStatus(const TileLayerStatus());
      return;
    }
    final packs = store.renderPacks;
    if (packs.isEmpty) {
      _setView(null, null, const []);
      _reportStatus(const TileLayerStatus());
      return;
    }
    final scale = widget.transform.scale;
    if (scale <= 0 || !scale.isFinite) {
      _setView(null, null, const []);
      _reportStatus(const TileLayerStatus());
      return;
    }
    // View lat/lon bounds: screen corners -> world meters -> WGS84.
    final geo = GeoProjection(
      originLat: widget.origin.lat,
      originLon: widget.origin.lon,
    );
    final corners = [
      (widget.transform.toWorldX(0), widget.transform.toWorldY(0)),
      (widget.transform.toWorldX(widget.size.width),
          widget.transform.toWorldY(0)),
      (widget.transform.toWorldX(0),
          widget.transform.toWorldY(widget.size.height)),
      (widget.transform.toWorldX(widget.size.width),
          widget.transform.toWorldY(widget.size.height)),
    ];
    var north = -90.0, south = 90.0, west = 180.0, east = -180.0;
    for (final (x, y) in corners) {
      final ll = geo.metersToLatLon(x, y);
      if (ll.lat > north) north = ll.lat;
      if (ll.lat < south) south = ll.lat;
      if (ll.lon < west) west = ll.lon;
      if (ll.lon > east) east = ll.lon;
    }
    final centerLat = (north + south) / 2;
    final centerLon = (west + east) / 2;
    final viewMpp = 1 / scale;

    TilePackMeta? chosen;
    for (final pack in packs) {
      if (centerLat <= pack.north &&
          centerLat >= pack.south &&
          centerLon >= pack.west &&
          centerLon <= pack.east) {
        chosen = pack;
        break;
      }
    }
    if (chosen == null) {
      _setView(null, null, const []);
      _reportStatus(const TileLayerStatus());
      return;
    }
    final zoom = bestZoomForView(
      viewMetersPerPixel: viewMpp,
      latitude: centerLat,
      minZoom: chosen.minZoom,
      maxZoom: chosen.maxZoom,
    );
    final tiles = tilesForBounds(north, south, west, east, zoom);
    if (tiles.length > kTileLayerMaxTilesPerView) {
      _setView(null, null, const []);
      _reportStatus(const TileLayerStatus());
      return;
    }
    final packId = chosen.id;
    _setView(packId, zoom, tiles);
    _reportStatus(TileLayerStatus(
      packName: chosen.displayName,
      zoom: zoom,
      tilesLoaded: _loadedCount(packId, tiles),
    ));
    for (final coord in tiles) {
      final key = '$packId|${coord.z}|${coord.x}|${coord.y}';
      if (_images.containsKey(key) || _loading.contains(key)) continue;
      _loading.add(key);
      unawaited(_loadTile(packId, coord, key));
    }
  }

  int _loadedCount(String packId, List<TileCoord> tiles) {
    var n = 0;
    for (final c in tiles) {
      if (_images.containsKey('$packId|${c.z}|${c.x}|${c.y}')) n++;
    }
    return n;
  }

  void _setView(String? packId, int? zoom, List<TileCoord> tiles) {
    _viewPackId = packId;
    _viewZoom = zoom;
    _viewTiles = tiles;
    // Prune the image cache to the current view + a little slack.
    if (_images.length > kTileLayerMaxCachedImages) {
      final keep = {
        for (final c in tiles) '$packId|${c.z}|${c.x}|${c.y}',
      };
      final drop = _images.keys
          .where((k) => !keep.contains(k))
          .take(_images.length - kTileLayerMaxCachedImages)
          .toList();
      for (final k in drop) {
        _images.remove(k)?.dispose();
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadTile(String packId, TileCoord coord, String key) async {
    try {
      final bytes = await widget.tilePacks.readTileBytes(packId, coord);
      if (bytes == null || bytes.isEmpty) return;
      final image = await _decode(bytes);
      if (!mounted) {
        image.dispose();
        return;
      }
      // Only keep it if this view still wants it.
      if (_viewPackId != packId || !_viewTiles.contains(coord)) {
        image.dispose();
        return;
      }
      _images[key] = image;
      if (mounted) {
        setState(() {});
        _reportStatus(TileLayerStatus(
          packName: _viewPackId == null
              ? null
              : widget.tilePacks.packById(_viewPackId!)?.displayName,
          zoom: _viewZoom,
          tilesLoaded: _loadedCount(packId, _viewTiles),
        ));
      }
    } catch (_) {
      // A failed tile decode is a missing tile: nothing renders,
      // nothing throws. The field grid shows through.
    } finally {
      _loading.remove(key);
    }
  }

  /// Decodes tile bytes to a [ui.Image]. Fails cleanly on corrupt
  /// data: [instantiateImageCodec] rejects the future (and the
  /// timeout bounds a pathological codec), so the caller's `catch`
  /// runs and the `finally` removes the key from `_loading` — a
  /// bad tile becomes a missing tile instead of a key stuck in
  /// `_loading` forever, which the old `decodeImageFromList`
  /// completer did (its callback never fires for corrupt bytes).
  Future<ui.Image> _decode(Uint8List bytes) async {
    final codec = await ui
        .instantiateImageCodec(bytes)
        .timeout(const Duration(seconds: 10));
    final frame = await codec.getNextFrame();
    return frame.image;
  }
}

/// Tile painter: draws present images, nothing for missing tiles.
/// The field canvas's own grid shows through where tiles are absent.
class _TilePackPainter extends CustomPainter {
  _TilePackPainter({required this.placements});

  final List<TilePlacement> placements;

  @override
  void paint(Canvas canvas, Size size) {
    for (final placement in placements) {
      final image = placement.image;
      if (image == null) continue;
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        tileDestRect(
          placement.rect,
          Size(image.width.toDouble(), image.height.toDouble()),
        ),
        Paint(),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TilePackPainter oldDelegate) {
    if (placements.length != oldDelegate.placements.length) return true;
    for (var i = 0; i < placements.length; i++) {
      if (placements[i] != oldDelegate.placements[i]) return true;
    }
    return false;
  }
}

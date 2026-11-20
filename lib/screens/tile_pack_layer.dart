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
/// * A tile still loading renders as nothing (the field canvas's
///   own 10 m grid shows through while it is in flight). A tile
///   that definitively FAILED renders as the honest labeled blank
///   grid — never a black hole against the dark map (v0.29.4).
///   Images fill their geographic placement rect edge to edge:
///   the placement is within ~1% of the square tile image, so
///   the fill is invisible, while aspect-fit centering left
///   ~30 px unpainted side margins that read as black seams
///   between tiles at field zoom (v0.29.4).
/// * The layer reports the render scale (screen px per tile px)
///   with its status, so the map status line can say 1:1 or ×N
///   honestly: at field zoom a z16 tile renders at ~23x, because
///   the finest USGS tile (~1.96 m/px at lat 35) is far coarser
///   than the field view (~0.07 m/px). Crisp 1:1 tiles need the
///   view at the tile-native scale — the maps' 1:1 controls set
///   exactly that (v0.29.4).
/// * No packs / no origin / web with no loader / a view the packs
///   do not cover: the layer paints nothing and the map is exactly
///   the field canvas it always was. On web, [WebTileLoader]
///   fetches USGS tiles live instead (see [_loadForWebView]) —
///   same cap, same grid fallback when offline or out of coverage.
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
import '../services/web_tile_loader.dart';
import '../utils/field_map_transform.dart';

/// Synthetic pack id for web live tiles (see [_loadForWebView]).
/// No pack ever carries this id — it routes tile reads to the
/// [WebTileLoader] instead of [TilePackStore.readTileBytes].
const String kWebTilePackId = 'web';

/// What the tile layer is currently rendering, for the map status
/// line. [packName] is null when no pack covers the view.
/// [web] is true when the tiles came from the web loader.
/// [renderScale] is screen pixels per tile pixel at the current
/// view scale (1.0 = crisp 1:1, > 1 = stretched — a z16 tile at a
/// field-zoom view renders at ~23x); null when no tile zoom is
/// known yet, so the status line shows no scale claim.
class TileLayerStatus {
  const TileLayerStatus({
    this.packName,
    this.zoom,
    this.tilesLoaded = 0,
    this.web = false,
    this.renderScale,
  });

  final String? packName;
  final int? zoom;
  final int tilesLoaded;
  final bool web;
  final double? renderScale;

  bool get hasTiles => packName != null;

  @override
  bool operator ==(Object other) =>
      other is TileLayerStatus &&
      packName == other.packName &&
      zoom == other.zoom &&
      tilesLoaded == other.tilesLoaded &&
      web == other.web &&
      renderScale == other.renderScale;

  @override
  int get hashCode =>
      Object.hash(packName, zoom, tilesLoaded, web, renderScale);
}

/// Status-line label for a render scale: '1:1' when the view is at
/// (or within 5% of) the tile-native scale, otherwise '×N' — the
/// stretch factor the +/− and scroll zoom actually change (the Z
/// readout is the tile zoom, which is already at the USGS z16 cap
/// at field zoom and so does not move with the buttons).
String tileRenderScaleLabel(double renderScale) {
  if ((renderScale - 1.0).abs() < 0.05) return '1:1';
  return '×${renderScale.toStringAsFixed(renderScale < 10 ? 1 : 0)}';
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
    this.webTiles,
    this.onStatus,
  });

  final FieldMapTransform transform;
  final GpsOrigin origin;
  final Size size;
  final TilePackStore tilePacks;

  /// Web live-tile loader (v0.29.3). On web the store is empty by
  /// design and the layer fetches USGS tiles through this instead.
  /// Null on native, where packs are the only source. Ignored
  /// entirely when the store is supported.
  final WebTileLoader? webTiles;

  /// Fired (post-frame, only when changed) with what the layer is
  /// rendering, so the map status line can say so.
  final ValueChanged<TileLayerStatus>? onStatus;

  @override
  State<TilePackMapLayer> createState() => _TilePackMapLayerState();
}

class _TilePackMapLayerState extends State<TilePackMapLayer> {
  final Map<String, ui.Image> _images = {};
  final Set<String> _loading = {};

  /// Tiles the view wants whose fetch/decoding definitively failed
  /// (network failure, non-200, or corrupt bytes — NOT still
  /// loading, NOT dropped by a source switch or view change).
  /// These paint as the honest labeled blank grid instead of
  /// nothing: painting nothing left a black hole against the dark
  /// map background (v0.29.4). Keys are [_imageKey]s, pruned to
  /// the current view in [_setView].
  final Set<String> _failed = {};

  String _signature = '';
  TileLayerStatus _lastStatus = const TileLayerStatus();
  List<TileCoord> _viewTiles = [];
  String? _viewPackId;
  int? _viewZoom;

  /// Center latitude of the current view, for the render-scale
  /// readout ([tileRenderScale] needs the tile zoom's latitude).
  double? _viewLat;

  /// Web source epoch (v0.29.3 reviewer fix): bumped whenever the
  /// web tile source switches, so a fetch that started on the old
  /// source can never land after the switch. See [_loadTile].
  int _webEpoch = 0;
  String? _lastWebSourceId;

  @override
  void initState() {
    super.initState();
    _lastWebSourceId = widget.webTiles?.source.id;
    widget.tilePacks.addListener(_onTilesChanged);
    widget.webTiles?.addListener(_onWebTilesChanged);
  }

  @override
  void didUpdateWidget(covariant TilePackMapLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tilePacks != widget.tilePacks) {
      oldWidget.tilePacks.removeListener(_onTilesChanged);
      widget.tilePacks.addListener(_onTilesChanged);
    }
    if (oldWidget.webTiles != widget.webTiles) {
      oldWidget.webTiles?.removeListener(_onWebTilesChanged);
      widget.webTiles?.addListener(_onWebTilesChanged);
      _lastWebSourceId = widget.webTiles?.source.id;
    }
  }

  void _onTilesChanged() {
    // Tile set changed (a download finished, a pack was deleted):
    // the signature recomputes on the next build and reloads.
    if (mounted) setState(() {});
  }

  /// Web loader notification: a source switch bumps the epoch so
  /// in-flight old-source fetches are dropped in [_loadTile],
  /// then the signature recomputes on the next build and the
  /// layer reloads on the new source. A notification with the
  /// source unchanged (e.g. cache clear) bumps nothing.
  void _onWebTilesChanged() {
    final current = widget.webTiles?.source.id;
    if (current != null && current != _lastWebSourceId) {
      _lastWebSourceId = current;
      _webEpoch++;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.tilePacks.removeListener(_onTilesChanged);
    widget.webTiles?.removeListener(_onWebTilesChanged);
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    super.dispose();
  }

  /// Image-cache key for a tile. The web pack id is shared by
  /// both USGS sources, so the web key carries the source id too
  /// — without it a source switch kept painting the old source's
  /// tiles under the new source's name (reviewer catch, v0.29.3:
  /// Topo painted as "USGS IMAGERY (WEB)"). Native pack keys are
  /// unchanged.
  String _imageKey(String packId, TileCoord coord) {
    if (packId == kWebTilePackId) {
      final source = widget.webTiles?.source.id ?? '';
      return '$packId|$source|${coord.z}|${coord.x}|${coord.y}';
    }
    return '$packId|${coord.z}|${coord.x}|${coord.y}';
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
        '${widget.origin.lon.toStringAsFixed(6)}|$packs|'
        // Web source switch must reload even when the view is
        // identical (same tiles, different map style).
        'web:${widget.webTiles?.source.id ?? ''}';
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
      final key = _imageKey(_viewPackId!, coord);
      final image = _images[key];
      // A tile still loading is skipped (the field grid shows
      // through while it is in flight). A tile that FAILED paints
      // as a null-image placement: the painter draws the honest
      // labeled blank grid for it, never a black hole.
      if (image == null && !_failed.contains(key)) continue;
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

  /// Screen pixels per tile pixel for the current view at [zoom]
  /// and [latitude] — the render scale the status line reports.
  double _renderScaleFor(int zoom, double latitude) =>
      tileRenderScale(
        viewScalePxPerMeter: widget.transform.scale,
        zoom: zoom,
        latitude: latitude,
      );

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
    if (!widget.tilePacks.supported) {
      return _loadForWebView();
    }
    final packs = widget.tilePacks.renderPacks;
    if (packs.isEmpty) {
      _setView(null, null, const []);
      _reportStatus(const TileLayerStatus());
      return;
    }
    final bounds = _viewBounds();
    if (bounds == null) {
      _setView(null, null, const []);
      _reportStatus(const TileLayerStatus());
      return;
    }
    TilePackMeta? chosen;
    for (final pack in packs) {
      if (bounds.centerLat <= pack.north &&
          bounds.centerLat >= pack.south &&
          bounds.centerLon >= pack.west &&
          bounds.centerLon <= pack.east) {
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
      viewMetersPerPixel: bounds.viewMpp,
      latitude: bounds.centerLat,
      minZoom: chosen.minZoom,
      maxZoom: chosen.maxZoom,
    );
    final tiles = tilesForBounds(
      bounds.north,
      bounds.south,
      bounds.west,
      bounds.east,
      zoom,
    );
    if (tiles.length > kTileLayerMaxTilesPerView) {
      _setView(null, null, const []);
      _reportStatus(const TileLayerStatus());
      return;
    }
    _startTileLoads(
      chosen.id,
      zoom,
      tiles,
      chosen.displayName,
      web: false,
      latitude: bounds.centerLat,
    );
  }

  /// Web path (v0.29.3): no packs on web, so the view's tiles come
  /// from the live loader instead — same bounds/zoom math, same
  /// per-view cap, same grid fallback when nothing loads. No
  /// loader means no tiles (the layer paints nothing, as before).
  Future<void> _loadForWebView() async {
    final loader = widget.webTiles;
    if (loader == null) {
      _setView(null, null, const []);
      _reportStatus(const TileLayerStatus());
      return;
    }
    final bounds = _viewBounds();
    if (bounds == null) {
      _setView(null, null, const []);
      _reportStatus(const TileLayerStatus(web: true));
      return;
    }
    final zoom = bestZoomForView(
      viewMetersPerPixel: bounds.viewMpp,
      latitude: bounds.centerLat,
      minZoom: 0,
      maxZoom: kWebTileMaxZoom,
    );
    final tiles = tilesForBounds(
      bounds.north,
      bounds.south,
      bounds.west,
      bounds.east,
      zoom,
    );
    if (tiles.length > kTileLayerMaxTilesPerView) {
      _setView(null, null, const []);
      _reportStatus(const TileLayerStatus(web: true));
      return;
    }
    _startTileLoads(
      kWebTilePackId,
      zoom,
      tiles,
      '${loader.source.displayName.toUpperCase()} (WEB)',
      web: true,
      latitude: bounds.centerLat,
    );
  }

  /// Shared tail of both load paths: register the view's tiles,
  /// report what is rendering, and kick off a load per tile.
  void _startTileLoads(
    String packId,
    int zoom,
    List<TileCoord> tiles,
    String displayName, {
    required bool web,
    required double latitude,
  }) {
    _viewLat = latitude;
    _setView(packId, zoom, tiles);
    _reportStatus(TileLayerStatus(
      packName: displayName,
      zoom: zoom,
      tilesLoaded: _loadedCount(packId, tiles),
      web: web,
      renderScale: _renderScaleFor(zoom, latitude),
    ));
    for (final coord in tiles) {
      final key = _imageKey(packId, coord);
      if (_images.containsKey(key) || _loading.contains(key)) continue;
      _loading.add(key);
      unawaited(_loadTile(packId, coord, key));
    }
  }

  /// View lat/lon bounds from the screen corners, or null when the
  /// transform scale is unusable. Shared by the pack and web paths.
  ({
    double north,
    double south,
    double west,
    double east,
    double centerLat,
    double centerLon,
    double viewMpp,
  })? _viewBounds() {
    final scale = widget.transform.scale;
    if (scale <= 0 || !scale.isFinite) return null;
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
    return (
      north: north,
      south: south,
      west: west,
      east: east,
      centerLat: (north + south) / 2,
      centerLon: (west + east) / 2,
      viewMpp: 1 / scale,
    );
  }

  int _loadedCount(String packId, List<TileCoord> tiles) {
    var n = 0;
    for (final c in tiles) {
      if (_images.containsKey(_imageKey(packId, c))) n++;
    }
    return n;
  }

  void _setView(String? packId, int? zoom, List<TileCoord> tiles) {
    _viewPackId = packId;
    _viewZoom = zoom;
    _viewTiles = tiles;
    // Prune the failed set to the current view: a tile that
    // failed on an old view (or an old source — the key carries
    // the source id) must not paint a grid cell it no longer
    // covers, and the set stays bounded.
    if (packId != null) {
      final keep = {
        for (final c in tiles) _imageKey(packId, c),
      };
      _failed.removeWhere((k) => !keep.contains(k));
    } else {
      _failed.clear();
    }
    // Prune the image cache to the current view + a little slack.
    if (_images.length > kTileLayerMaxCachedImages) {
      final keep = {
        if (packId != null)
          for (final c in tiles) _imageKey(packId, c),
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
    // The web epoch at fetch start: a source switch while this
    // fetch is in flight invalidates it (reviewer catch, v0.29.3).
    final epoch = _webEpoch;
    try {
      // Web live tiles come from the loader; pack tiles from the
      // store. Either way a missing tile is a missing tile.
      final bytes = packId == kWebTilePackId
          ? await widget.webTiles?.fetchTile(coord)
          : await widget.tilePacks.readTileBytes(packId, coord);
      // No bytes is a definitive failure for this view: mark it
      // so the tile paints as the labeled blank grid instead of
      // a black hole. (A fetch dropped by a source switch or a
      // view change below is NOT a failure — it never reaches
      // this line as a failure, it just returns.)
      if (bytes == null || bytes.isEmpty) {
        _failed.add(key);
        if (mounted) setState(() {});
        return;
      }
      final image = await _decode(bytes);
      if (!mounted) {
        image.dispose();
        return;
      }
      // A source switch while this fetch was in flight: these
      // bytes belong to the old source — drop them, never paint
      // them under the new source's name. (The source-keyed
      // cache would keep them out of the painted view anyway;
      // this keeps them out of memory too.)
      if (packId == kWebTilePackId && epoch != _webEpoch) {
        image.dispose();
        return;
      }
      // Only keep it if this view still wants it.
      if (_viewPackId != packId || !_viewTiles.contains(coord)) {
        image.dispose();
        return;
      }
      _images[key] = image;
      // A retry that landed: the tile is no longer failed.
      _failed.remove(key);
      if (mounted) {
        setState(() {});
        _reportStatus(TileLayerStatus(
          packName: _viewPackId == null
              ? null
              : _displayNameFor(_viewPackId!),
          zoom: _viewZoom,
          tilesLoaded: _loadedCount(packId, _viewTiles),
          web: _viewPackId == kWebTilePackId,
          renderScale: _viewZoom == null || _viewLat == null
              ? null
              : _renderScaleFor(_viewZoom!, _viewLat!),
        ));
      }
    } catch (_) {
      // A failed tile decode is a missing tile: it paints as the
      // labeled blank grid, nothing throws. The field grid shows
      // through the cell's label area.
      _failed.add(key);
      if (mounted) setState(() {});
    } finally {
      _loading.remove(key);
    }
  }

  /// Display name for a view's pack id: the pack's name on native,
  /// the web source name on web. Upper-cased to match the pack
  /// names (and the app's all-caps UI copy).
  String? _displayNameFor(String packId) {
    if (packId == kWebTilePackId) {
      final loader = widget.webTiles;
      if (loader == null) return null;
      return '${loader.source.displayName.toUpperCase()} (WEB)';
    }
    return widget.tilePacks.packById(packId)?.displayName;
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

/// Tile painter: draws present images edge to edge in their
/// geographic rect, and draws failed tiles as the honest labeled
/// blank grid — never a black hole. Tiles still loading are not
/// in [placements] at all (the field grid shows through while
/// they are in flight). Delegates to [TileBackgroundPainter], the
/// one painter that owns both halves of that contract.
class _TilePackPainter extends CustomPainter {
  _TilePackPainter({required this.placements});

  final List<TilePlacement> placements;

  @override
  void paint(Canvas canvas, Size size) {
    TileBackgroundPainter(
      placements: placements,
      // Nothing is cached on web: a failed live tile is just
      // 'NO TILE', not a cache miss.
      missingLabel: 'NO TILE',
    ).paint(canvas, size);
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

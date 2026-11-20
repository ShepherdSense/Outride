/// Web live-tile loader (Outride v0.29.3, EXPERIMENTAL).
///
/// Tile packs are MBTiles files on disk and deliberately stay
/// unavailable on web (sqflite has no web backend) — but the sim
/// runs in a browser, online, and the live GPS map was grid-only
/// there. This loader fills that gap: it fetches USGS tiles over
/// the network, on demand, for the view the map is showing, and
/// hands the bytes to [TilePackMapLayer] exactly like a pack read.
///
/// SOURCE RULE (same as packs, non-negotiable): USGS Topo default /
/// USGS Imagery alternate ONLY — [packSourceAllowed] enforces it.
/// The loader never fetches OSM Standard: the selected tile source
/// is used when it is a USGS source, otherwise USGS Topo. USGS
/// tiles are public-domain, no key, and the service sends
/// `Access-Control-Allow-Origin: *` (verified live 2026-11-20),
/// so a browser fetch works.
///
/// VIEW-TRIGGERED, NOT BULK: only the tiles the current view needs
/// are fetched (at most [kTileLayerMaxTilesPerView] per view, same
/// cap as packs), one attempt + one retry each. This is the live-
/// view pattern (like the v0.26.0 [TileCache]), not a pack download
/// — nothing here bulk-downloads a region, and the USGS 100k
/// export cap never comes into play.
///
/// CACHE: in-memory only (LRU, 256 tiles / 16 MB). Nothing is
/// written to disk on web — a reload re-fetches. A failed tile is
/// a missing tile: the field grid shows through, never an invented
/// map, never a throw out of the public API.
///
/// PRIVACY: fetching a tile is a plain HTTP GET for a map image —
/// no identifier, no cookie is sent with it. The tile z/x/y in the
/// request reveals only the map area being viewed, as with any tile
/// fetch; your GPS fix itself is never sent. The visitor's
/// position stays in their browser, never sent, stored or logged
/// (same rule as the live GPS map itself).
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'offline_map_source.dart';
import 'tile_pack.dart';

/// USGS services top out at level 16 (both advertise maxScale
/// 9027.977411; a z17 tile request returns HTTP 404) — same cap
/// as area packs ([kAreaPackMaxZoom]).
const int kWebTileMaxZoom = 16;

/// Max tiles held in the in-memory cache. Tiles run ~10–40 KB, so
/// 256 tiles is ~2.5–10 MB — enough for a field-sized view at
/// several zooms, small enough to hold for a session.
const int kWebTileMaxCachedTiles = 256;

/// Max bytes held in the in-memory cache (second bound; whichever
/// hits first evicts oldest).
const int kWebTileMaxCachedBytes = 16 * 1024 * 1024;

/// Fetch attempts per tile (first attempt + one retry).
const int kWebTileMaxAttempts = 2;

/// Max simultaneous tile GETs. The pack downloader caps at 4
/// concurrent; the loader matches it so a pan/zoom on a slow
/// link does not queue dozens of 30 s requests against a public
/// service (reviewer catch, v0.29.3). Browsers self-throttle to
/// ~6/host anyway, but the cap bounds the queue, not just the
/// wire.
const int kWebTileMaxConcurrentFetches = 4;

/// Per-attempt network timeout.
const Duration kWebTileTimeout = Duration(seconds: 30);

/// Resolves the tile source the web loader uses for a selected
/// source id: the selected source when it is a USGS source,
/// otherwise USGS Topo. The loader never fetches OSM Standard.
TileSource webTileSourceFor(String? id) {
  if (id != null && packSourceAllowed(id)) return selectTileSource(id);
  return kUsgsTopo;
}

/// The tile-source id the Settings dropdown must show for a stored
/// id: on web it is the EFFECTIVE source (the loader's resolution
/// above — a stored OSM selection shows as USGS Topo, because that
/// is what the map actually renders); on native the stored id is
/// shown as-is. Pure function of ([storedId], [isWeb]) so the
/// dropdown logic is unit-testable — `kIsWeb` is false under
/// `flutter test`, so the web branch cannot be reached from a
/// widget test.
String effectiveTileSourceIdFor({
  required String storedId,
  required bool isWeb,
}) =>
    isWeb ? webTileSourceFor(storedId).id : storedId;

/// The sources the Settings dropdown may offer: USGS-only on web
/// (the loader never fetches OSM there, so offering it would show
/// a source the map cannot render), all built-in sources native.
List<TileSource> tileSourceOptionsFor({required bool isWeb}) =>
    isWeb
        ? defaultTileSources
            .where((s) => packSourceAllowed(s.id))
            .toList()
        : defaultTileSources;

class WebTileLoader extends ChangeNotifier {
  WebTileLoader({
    http.Client? client,
    TileSource? source,
  })  : _client = client ?? http.Client(),
        // kUsgsTopo is not const, so it cannot be the default
        // value — the null default resolves to it here.
        _source = source != null && packSourceAllowed(source.id)
            ? source
            : kUsgsTopo;

  final http.Client _client;

  TileSource _source;

  /// Current tile source (USGS Topo by default, USGS Imagery as
  /// the alternate — never OSM).
  TileSource get source => _source;

  /// Switches the tile source. A non-USGS source falls back to
  /// USGS Topo. The memory cache is source-specific, so it is
  /// cleared and listeners are notified — the map reloads on the
  /// new source. No-op when the resolved source is unchanged.
  void setSource(TileSource next) {
    final resolved =
        packSourceAllowed(next.id) ? next : kUsgsTopo;
    if (resolved.id == _source.id) return;
    _source = resolved;
    _cache.clear();
    _bytes = 0;
    notifyListeners();
  }

  // LRU by insertion order: a hit re-inserts at the end, eviction
  // drops from the front.
  final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap();
  final Map<String, Future<Uint8List?>> _pending = {};
  int _bytes = 0;

  // Concurrency cap (see kWebTileMaxConcurrentFetches): fetches
  // past the cap wait in FIFO order for a slot.
  int _inFlightFetches = 0;
  final Queue<Completer<void>> _fetchWaiters = Queue<Completer<void>>();

  Future<void> _acquireFetchSlot() async {
    if (_inFlightFetches < kWebTileMaxConcurrentFetches) {
      _inFlightFetches++;
      return;
    }
    final waiter = Completer<void>();
    _fetchWaiters.add(waiter);
    await waiter.future;
    // A completed waiter now holds the slot the releaser freed.
    _inFlightFetches++;
  }

  void _releaseFetchSlot() {
    _inFlightFetches--;
    if (_fetchWaiters.isNotEmpty) {
      _fetchWaiters.removeFirst().complete();
    }
  }

  /// Distinct tiles loaded from the network this session.
  int _loaded = 0;

  /// Tile fetches that ended with no usable tile (network failure,
  /// non-200, or not an image). A 404 outside USGS coverage counts
  /// here too — it is a tile the service does not have, not a
  /// crash, and the grid shows through.
  int _failed = 0;

  int get cachedTiles => _cache.length;
  int get cachedBytes => _bytes;
  int get tilesLoaded => _loaded;
  int get failedFetches => _failed;

  bool _disposed = false;

  /// Cache-first fetch for one tile's bytes, or null when the tile
  /// is unavailable. Never throws. Concurrent fetches for the same
  /// tile share one network request.
  Future<Uint8List?> fetchTile(TileCoord coord) async {
    final key = '${_source.id}|${coord.z}|${coord.x}|${coord.y}';
    final cached = _cache[key];
    if (cached != null) {
      _cache.remove(key);
      _cache[key] = cached;
      return cached;
    }
    final inFlight = _pending[key];
    if (inFlight != null) return inFlight;
    final future = _fetchUncached(coord, key);
    _pending[key] = future;
    try {
      return await future;
    } finally {
      _pending.remove(key);
    }
  }

  Future<Uint8List?> _fetchUncached(TileCoord coord, String key) async {
    if (_disposed) return null;
    await _acquireFetchSlot();
    try {
      if (_disposed) return null;
      return await _fetchWithRetries(coord, key);
    } finally {
      _releaseFetchSlot();
    }
  }

  Future<Uint8List?> _fetchWithRetries(TileCoord coord, String key) async {
    Uint8List? bytes;
    for (var attempt = 0; attempt < kWebTileMaxAttempts; attempt++) {
      try {
        final response = await _client
            .get(
              Uri.parse(_source.urlFor(coord)),
              // Best-effort identification: browsers drop the
              // User-Agent header from fetch/XHR (forbidden
              // header), so on web this never reaches USGS —
              // which does not require it. It is sent on native.
              headers: {'User-Agent': kTileUserAgent},
            )
            .timeout(kWebTileTimeout);
        if (response.statusCode == 200 &&
            response.bodyBytes.isNotEmpty &&
            _looksLikeTile(response.bodyBytes)) {
          bytes = response.bodyBytes;
          break;
        }
        // 404 is terminal: the service does not have this tile
        // (outside USGS coverage, or past level 16) — retrying it
        // wastes the quota and the wait.
        if (response.statusCode == 404) break;
      } catch (_) {
        // Retry below; a failed tile is a missing tile.
      }
      if (attempt < kWebTileMaxAttempts - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    if (bytes == null) {
      _failed++;
      return null;
    }
    _loaded++;
    _store(key, bytes);
    return bytes;
  }

  void _store(String key, Uint8List bytes) {
    // An oversized tile is served but never stored — the bound
    // always holds (same rule as TileCache).
    if (bytes.length > kWebTileMaxCachedBytes) return;
    _cache[key] = bytes;
    _bytes += bytes.length;
    while (_cache.length > kWebTileMaxCachedTiles ||
        _bytes > kWebTileMaxCachedBytes) {
      final oldest = _cache.keys.first;
      _bytes -= _cache.remove(oldest)!.length;
    }
  }

  /// PNG (89 50 4E 47) or JPEG (FF D8 FF) magic. Mirrors
  /// TilePackStore._looksLikeTile (same rule: USGS Topo serves PNG
  /// or JPEG, Imagery serves JPEG; an error page is never stored).
  static bool _looksLikeTile(Uint8List bytes) {
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true;
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return true;
    }
    return false;
  }

  /// Clears the memory cache (counts for the session are kept).
  /// Notifies, so the map reloads.
  void clear() {
    _cache.clear();
    _bytes = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // Release any fetches waiting on a slot so they return null
    // instead of hanging past teardown.
    while (_fetchWaiters.isNotEmpty) {
      _fetchWaiters.removeFirst().complete();
    }
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }
}

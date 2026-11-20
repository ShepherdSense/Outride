/// Offline map tile packs (Outride v0.28.0, EXPERIMENTAL).
///
/// Two tiers, one tile fetcher:
///
/// * Tier 1 — state pack: one pack per US state (+ DC), whole state at
///   zoom 0–12, one tap. Base map for staging / driving / mutual aid.
/// * Tier 2 — area pack: a rectangle around the search area, zoom
///   0–16 (capped: both USGS services advertise maxScale
///   9027.977411 — level 16 — and a live z17 tile request returns
///   HTTP 404, so a z17 pack could never complete). Per-mission
///   detail.
///
/// Pack format is MBTiles (one `.mbtiles` SQLite file per pack) — see
/// `tile_pack_db.dart` / `tile_pack_store.dart`. This file is pure Dart:
/// models, the state bounding-box table, and size-estimate math. No
/// sqlite, no Flutter, no I/O — unit-testable on the VM.
///
/// LICENSING (decided from live sources, see
/// `~/workspace/research_notes/outride-tile-packs.md`): pack downloads
/// fetch from USGS The National Map endpoints ONLY (public domain,
/// export explicitly allowed). `tile.openstreetmap.org` PROHIBITS bulk
/// / offline downloading, and standard Esri World Imagery is not
/// intended for export — neither is ever a pack source. The store
/// enforces this; the UI never offers them.
library;

import 'dart:math' as math;

import 'offline_map_source.dart';

/// Typical USGS Topo PNG bytes per tile, used for size estimates.
/// Real tiles run ~10–40 KB; estimates are labeled EST. and the tile
/// count is always shown alongside the megabytes.
const int kTilePackTypicalBytesPerTile = 20 * 1024;

/// State-pack zoom cap (v1). Each zoom quadruples the count; z13
/// takes NC to ~470 MB and TX to ~2.2 GB (and past the USGS 100k
/// export cap), so z13 is not offered for state packs in v1.
const int kStatePackMinZoom = 0;
const int kStatePackMaxZoom = 12;

/// Area-pack zooms: 16 default and max. z17 is NOT offered: both
/// USGS Topo and USGS Imagery advertise maxScale 9027.977411
/// (level 16) and a live z17 tile request returns HTTP 404 — a z17
/// pack could never complete (every z17 tile 404s and retries
/// forever, and its good z0–16 tiles never render because
/// rendering requires a complete pack).
const int kAreaPackMinZoom = 0;
const int kAreaPackDefaultMaxZoom = 16;
const int kAreaPackMaxZoom = 16;

/// Pack tier.
enum TilePackKind {
  /// Whole-state base pack (Tier 1).
  state,

  /// Rectangle around a search area (Tier 2).
  area,
}

/// Download / pack lifecycle state.
enum TilePackStatus {
  downloading,
  paused,
  complete,
  error,
}

/// One US state (+ DC) that can take a one-tap base pack.
///
/// Bounding boxes are the U.S. Census NAD83 state bboxes
/// (gist a8dx/2340f9527af64f8ef8439366de981168): xmin=west,
/// ymin=south, xmax=east, ymax=north, degrees. Padded outward by
/// [kStateBboxPadDeg] at use time so the pack edge never clips the
/// state line.
class StatePackDef {
  const StatePackDef({
    required this.abbr,
    required this.name,
    required this.west,
    required this.south,
    required this.east,
    required this.north,
    this.oneTap = true,
  });

  final String abbr;
  final String name;
  final double west;
  final double south;
  final double east;
  final double north;

  /// False when a one-tap pack is not offered (Alaska: its bbox
  /// spans the antimeridian, ~2,766,000 tiles at z0–12, ~54 GB).
  /// Area packs still work there.
  final bool oneTap;
}

/// Outward padding applied to every state bbox at use time (degrees),
/// so the pack covers the state line with margin.
const double kStateBboxPadDeg = 0.15;

/// All 50 states + DC. Source: U.S. Census NAD83 bboxes (see above).
/// Alaska is present in the table but flagged `oneTap: false`.
const List<StatePackDef> kStatePackDefs = [
  StatePackDef(abbr: 'AL', name: 'Alabama', west: -88.473227, south: 30.223334, east: -84.88908, north: 35.008028),
  StatePackDef(abbr: 'AK', name: 'Alaska', west: -179.148909, south: 51.214183, east: 179.77847, north: 71.365162, oneTap: false),
  StatePackDef(abbr: 'AZ', name: 'Arizona', west: -114.81651, south: 31.332177, east: -109.045223, north: 37.00426),
  StatePackDef(abbr: 'AR', name: 'Arkansas', west: -94.617919, south: 33.004106, east: -89.644395, north: 36.4996),
  StatePackDef(abbr: 'CA', name: 'California', west: -124.409591, south: 32.534156, east: -114.131211, north: 42.009518),
  StatePackDef(abbr: 'CO', name: 'Colorado', west: -109.060253, south: 36.992426, east: -102.041524, north: 41.003444),
  StatePackDef(abbr: 'CT', name: 'Connecticut', west: -73.727775, south: 40.980144, east: -71.786994, north: 42.050587),
  StatePackDef(abbr: 'DE', name: 'Delaware', west: -75.788658, south: 38.451013, east: -75.048939, north: 39.839007),
  StatePackDef(abbr: 'DC', name: 'District of Columbia', west: -77.119759, south: 38.791645, east: -76.909395, north: 38.99511),
  StatePackDef(abbr: 'FL', name: 'Florida', west: -87.634938, south: 24.523096, east: -80.031362, north: 31.000888),
  StatePackDef(abbr: 'GA', name: 'Georgia', west: -85.605165, south: 30.357851, east: -80.839729, north: 35.000659),
  StatePackDef(abbr: 'HI', name: 'Hawaii', west: -178.334698, south: 18.910361, east: -154.806773, north: 28.402123),
  StatePackDef(abbr: 'ID', name: 'Idaho', west: -117.243027, south: 41.988057, east: -111.043564, north: 49.001146),
  StatePackDef(abbr: 'IL', name: 'Illinois', west: -91.513079, south: 36.970298, east: -87.494756, north: 42.508481),
  StatePackDef(abbr: 'IN', name: 'Indiana', west: -88.09776, south: 37.771742, east: -84.784579, north: 41.760592),
  StatePackDef(abbr: 'IA', name: 'Iowa', west: -96.639704, south: 40.375501, east: -90.140061, north: 43.501196),
  StatePackDef(abbr: 'KS', name: 'Kansas', west: -102.051744, south: 36.993016, east: -94.588413, north: 40.003162),
  StatePackDef(abbr: 'KY', name: 'Kentucky', west: -89.571509, south: 36.497129, east: -81.964971, north: 39.147458),
  StatePackDef(abbr: 'LA', name: 'Louisiana', west: -94.043147, south: 28.928609, east: -88.817017, north: 33.019457),
  StatePackDef(abbr: 'ME', name: 'Maine', west: -71.083924, south: 42.977764, east: -66.949895, north: 47.459686),
  StatePackDef(abbr: 'MD', name: 'Maryland', west: -79.487651, south: 37.911717, east: -75.048939, north: 39.723043),
  StatePackDef(abbr: 'MA', name: 'Massachusetts', west: -73.508142, south: 41.237964, east: -69.928393, north: 42.886589),
  StatePackDef(abbr: 'MI', name: 'Michigan', west: -90.418136, south: 41.696118, east: -82.413474, north: 48.2388),
  StatePackDef(abbr: 'MN', name: 'Minnesota', west: -97.239209, south: 43.499356, east: -89.491739, north: 49.384358),
  StatePackDef(abbr: 'MS', name: 'Mississippi', west: -91.655009, south: 30.173943, east: -88.097888, north: 34.996052),
  StatePackDef(abbr: 'MO', name: 'Missouri', west: -95.774704, south: 35.995683, east: -89.098843, north: 40.61364),
  StatePackDef(abbr: 'MT', name: 'Montana', west: -116.050003, south: 44.358221, east: -104.039138, north: 49.00139),
  StatePackDef(abbr: 'NE', name: 'Nebraska', west: -104.053514, south: 39.999998, east: -95.30829, north: 43.001708),
  StatePackDef(abbr: 'NV', name: 'Nevada', west: -120.005746, south: 35.001857, east: -114.039648, north: 42.002207),
  StatePackDef(abbr: 'NH', name: 'New Hampshire', west: -72.557247, south: 42.69699, east: -70.610621, north: 45.305476),
  StatePackDef(abbr: 'NJ', name: 'New Jersey', west: -75.559614, south: 38.928519, east: -73.893979, north: 41.357423),
  StatePackDef(abbr: 'NM', name: 'New Mexico', west: -109.050173, south: 31.332301, east: -103.001964, north: 37.000232),
  StatePackDef(abbr: 'NY', name: 'New York', west: -79.762152, south: 40.496103, east: -71.856214, north: 45.01585),
  StatePackDef(abbr: 'NC', name: 'North Carolina', west: -84.321869, south: 33.842316, east: -75.460621, north: 36.588117),
  StatePackDef(abbr: 'ND', name: 'North Dakota', west: -104.0489, south: 45.935054, east: -96.554507, north: 49.000574),
  StatePackDef(abbr: 'OH', name: 'Ohio', west: -84.820159, south: 38.403202, east: -80.518693, north: 41.977523),
  StatePackDef(abbr: 'OK', name: 'Oklahoma', west: -103.002565, south: 33.615833, east: -94.430662, north: 37.002206),
  StatePackDef(abbr: 'OR', name: 'Oregon', west: -124.566244, south: 41.991794, east: -116.463504, north: 46.292035),
  StatePackDef(abbr: 'PA', name: 'Pennsylvania', west: -80.519891, south: 39.7198, east: -74.689516, north: 42.26986),
  StatePackDef(abbr: 'RI', name: 'Rhode Island', west: -71.862772, south: 41.146339, east: -71.12057, north: 42.018798),
  StatePackDef(abbr: 'SC', name: 'South Carolina', west: -83.35391, south: 32.0346, east: -78.54203, north: 35.215402),
  StatePackDef(abbr: 'SD', name: 'South Dakota', west: -104.057698, south: 42.479635, east: -96.436589, north: 45.94545),
  StatePackDef(abbr: 'TN', name: 'Tennessee', west: -90.310298, south: 34.982972, east: -81.6469, north: 36.678118),
  StatePackDef(abbr: 'TX', name: 'Texas', west: -106.645646, south: 25.837377, east: -93.508292, north: 36.500704),
  StatePackDef(abbr: 'UT', name: 'Utah', west: -114.052962, south: 36.997968, east: -109.041058, north: 42.001567),
  StatePackDef(abbr: 'VT', name: 'Vermont', west: -73.43774, south: 42.726853, east: -71.464555, north: 45.016659),
  StatePackDef(abbr: 'VA', name: 'Virginia', west: -83.675395, south: 36.540738, east: -75.242266, north: 39.466012),
  StatePackDef(abbr: 'WA', name: 'Washington', west: -124.763068, south: 45.543541, east: -116.915989, north: 49.002494),
  StatePackDef(abbr: 'WV', name: 'West Virginia', west: -82.644739, south: 37.201483, east: -77.719519, north: 40.638801),
  StatePackDef(abbr: 'WI', name: 'Wisconsin', west: -92.888114, south: 42.491983, east: -86.805415, north: 47.080621),
  StatePackDef(abbr: 'WY', name: 'Wyoming', west: -111.056888, south: 40.994746, east: -104.05216, north: 45.005904),
];

/// Padded bbox for a state pack (outward by [kStateBboxPadDeg]).
({double north, double south, double west, double east}) statePackBounds(
  StatePackDef def,
) {
  return (
    north: (def.north + kStateBboxPadDeg).clamp(-90.0, 90.0),
    south: (def.south - kStateBboxPadDeg).clamp(-90.0, 90.0),
    west: def.west - kStateBboxPadDeg,
    east: def.east + kStateBboxPadDeg,
  );
}

/// Tile count for a bbox over a zoom range (exact slippy-math count).
///
/// Arithmetic, not list-building: for each zoom the count is
/// (x1 − x0 + 1) × (y1 − y0 + 1) per antimeridian range — the same
/// count [tilesForBounds] would return, without allocating tens of
/// thousands of [TileCoord]s. That matters for the state-pack list:
/// all 51 estimates must compute in microseconds on screen open.
/// Returns 0 for an inverted north/south box.
int tileCountForBounds(
  double north,
  double south,
  double west,
  double east,
  int minZoom,
  int maxZoom,
) {
  if (north < south) return 0;
  var total = 0;
  for (var z = minZoom; z <= maxZoom; z++) {
    final zz = z.clamp(0, 22);
    final ranges = east < west
        ? [
            (west, 180.0),
            (-180.0, east),
          ]
        : [
            (west, east),
          ];
    for (final (w, e) in ranges) {
      final x0 = latLonToTile(north, w, zz).x;
      final x1 = latLonToTile(south, e, zz).x;
      final y0 = latLonToTile(north, w, zz).y;
      final y1 = latLonToTile(south, e, zz).y;
      total += (x1 - x0 + 1) * (y1 - y0 + 1);
    }
  }
  return total;
}

/// Size estimate for a tile count, in bytes, at the typical
/// per-tile size. Always shown as an estimate, with the count.
int estimateBytesForTiles(int tileCount) =>
    tileCount * kTilePackTypicalBytesPerTile;

/// Human-readable size, e.g. "112 MB" / "843 KB" / "5 MB".
String formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    final mb = bytes / (1024 * 1024);
    return mb >= 100
        ? '${mb.toStringAsFixed(0)} MB'
        : '${mb.toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

/// One tile pack (one `.mbtiles` file + one index entry).
class TilePackMeta {
  TilePackMeta({
    required this.id,
    required this.kind,
    required this.displayName,
    required this.sourceId,
    required this.north,
    required this.south,
    required this.west,
    required this.east,
    required this.minZoom,
    required this.maxZoom,
    required this.expectedTiles,
    required this.fileName,
    required this.status,
    this.downloadedTiles = 0,
    this.bytesOnDisk = 0,
    this.error,
    DateTime? created,
    this.sha256,
  }) : created = created ?? DateTime.now();

  final String id;
  final TilePackKind kind;
  final String displayName;
  final String sourceId;
  final double north;
  final double south;
  final double west;
  final double east;
  final int minZoom;
  final int maxZoom;
  final int expectedTiles;
  final String fileName;
  TilePackStatus status;
  int downloadedTiles;
  int bytesOnDisk;
  String? error;
  final DateTime created;
  final String? sha256;

  double get progress =>
      expectedTiles <= 0 ? 0 : downloadedTiles / expectedTiles;

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'displayName': displayName,
        'sourceId': sourceId,
        'north': north,
        'south': south,
        'west': west,
        'east': east,
        'minZoom': minZoom,
        'maxZoom': maxZoom,
        'expectedTiles': expectedTiles,
        'fileName': fileName,
        'status': status.name,
        'downloadedTiles': downloadedTiles,
        'bytesOnDisk': bytesOnDisk,
        'error': error,
        'created': created.toIso8601String(),
        'sha256': sha256,
      };

  static TilePackMeta fromJson(Map<String, Object?> json) {
    TilePackKind kindFrom(String? s) =>
        s == 'area' ? TilePackKind.area : TilePackKind.state;
    TilePackStatus statusFrom(String? s) => switch (s) {
          'downloading' => TilePackStatus.downloading,
          'paused' => TilePackStatus.paused,
          'complete' => TilePackStatus.complete,
          _ => TilePackStatus.error,
        };
    return TilePackMeta(
      id: json['id'] as String? ?? '',
      kind: kindFrom(json['kind'] as String?),
      displayName: json['displayName'] as String? ?? '',
      sourceId: json['sourceId'] as String? ?? 'usgs_topo',
      north: (json['north'] as num?)?.toDouble() ?? 0,
      south: (json['south'] as num?)?.toDouble() ?? 0,
      west: (json['west'] as num?)?.toDouble() ?? 0,
      east: (json['east'] as num?)?.toDouble() ?? 0,
      minZoom: (json['minZoom'] as num?)?.toInt() ?? 0,
      maxZoom: (json['maxZoom'] as num?)?.toInt() ?? 12,
      expectedTiles: (json['expectedTiles'] as num?)?.toInt() ?? 0,
      fileName: json['fileName'] as String? ?? '',
      status: statusFrom(json['status'] as String?),
      downloadedTiles: (json['downloadedTiles'] as num?)?.toInt() ?? 0,
      bytesOnDisk: (json['bytesOnDisk'] as num?)?.toInt() ?? 0,
      error: json['error'] as String?,
      created: DateTime.tryParse(json['created'] as String? ?? ''),
      sha256: json['sha256'] as String?,
    );
  }
}

/// Pack file name for a state pack.
String statePackFileName(String abbr, String sourceId) =>
    'state_${abbr.toLowerCase()}_${sourceId}_z$kStatePackMinZoom-$kStatePackMaxZoom.mbtiles';

/// Pack file name for an area pack (name is user text, sanitized).
String areaPackFileName(String name, String sourceId, int maxZoom) {
  final clean = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  final base = clean.isEmpty ? 'area' : clean;
  return 'area_${base}_${sourceId}_z0-$maxZoom.mbtiles';
}

/// Sources allowed for pack downloads. USGS only — OSM Standard
/// prohibits bulk/offline downloading and Esri World Imagery is not
/// intended for export (see the design note). Enforced by the store,
/// not just the UI.
bool packSourceAllowed(String sourceId) =>
    sourceId == 'usgs_topo' || sourceId == 'usgs_imagery';

/// USGS coverage check for an area-pack center (generous US bbox:
/// CONUS + Alaska + Hawaii + Puerto Rico / USVI, plus the Aleutian
/// antimeridian crossing). USGS Topo/Imagery cover the US only — a
/// pack centered outside this box fetches nothing, so the UI
/// refuses the download instead of failing tile-by-tile.
/// Generous on purpose: a legitimate pack near the border must
/// never be blocked (PR's east edge is −65.6°, USVI reaches
/// −64.7°, Attu is +179.7°).
bool usgsCovers(double lat, double lon) {
  if (lat < 17.0 || lat > 72.0) return false;
  if (lon >= -180.0 && lon <= -64.0) return true;
  // Aleutians east of the antimeridian (Attu is +179.7°).
  if (lon >= 179.0 && lon <= 180.0) return true;
  return false;
}

/// Best tile zoom for a view: the largest zoom whose tiles are at
/// least as detailed as the screen (tile meters-per-pixel >= view
/// meters-per-pixel), clamped to the zooms a pack actually holds.
/// Below the pack's min zoom there is nothing to show; above its max
/// zoom the tiles stretch (honest, and the UI says so).
int bestZoomForView({
  required double viewMetersPerPixel,
  required double latitude,
  required int minZoom,
  required int maxZoom,
}) {
  // Meters per pixel of a tile at zoom z (Web-Mercator, 256 px tiles).
  double tileMpp(int z) =>
      156543.03392 * math.cos(latitude * math.pi / 180.0) / (1 << z);
  var best = minZoom;
  for (var z = minZoom; z <= maxZoom; z++) {
    if (tileMpp(z) >= viewMetersPerPixel) {
      best = z;
    } else {
      break;
    }
  }
  return best;
}

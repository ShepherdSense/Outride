/// Tests for offline tile-pack models (v0.28.0): the state table,
/// the arithmetic tile-count math (checked against the design
/// note's numbers), size estimates, zoom selection, source
/// allow-listing, file names, and metadata JSON round-trip.
///
/// Pure Dart — no SQLite, no HTTP, no platform channels.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/offline_map_source.dart';
import 'package:outride/services/tile_pack.dart';

void main() {
  group('state pack table', () {
    test('50 states + DC', () {
      expect(kStatePackDefs.length, 51);
      final abbrs = kStatePackDefs.map((d) => d.abbr).toSet();
      expect(abbrs.length, 51);
      expect(abbrs.contains('NC'), isTrue);
      expect(abbrs.contains('DC'), isTrue);
    });

    test('Alaska is the only state without a one-tap pack', () {
      final noTap =
          kStatePackDefs.where((d) => !d.oneTap).toList();
      expect(noTap.map((d) => d.abbr).toList(), ['AK']);
    });

    test('state pack bounds are padded outward by 0.15 degrees', () {
      final nc = kStatePackDefs.firstWhere((d) => d.abbr == 'NC');
      final b = statePackBounds(nc);
      expect(b.north, closeTo(36.588117 + 0.15, 1e-9));
      expect(b.south, closeTo(33.842316 - 0.15, 1e-9));
      expect(b.west, closeTo(-84.321869 - 0.15, 1e-9));
      expect(b.east, closeTo(-75.460621 + 0.15, 1e-9));
    });
  });

  group('tileCountForBounds (arithmetic)', () {
    test('matches the design-note state-pack counts at zoom 0–12', () {
      int countFor(String abbr) {
        final def = kStatePackDefs.firstWhere((d) => d.abbr == abbr);
        final b = statePackBounds(def);
        return tileCountForBounds(
          b.north, b.south, b.west, b.east,
          kStatePackMinZoom, kStatePackMaxZoom,
        );
      }

      // Numbers from the design note (recomputed 2026-11-19 with
      // the app's own slippy math on the PADDED bboxes — the
      // downloader fetches the padded bbox, so the estimate must
      // match it. An earlier research pass quoted smaller numbers
      // from an unspecified method; they did not reproduce and
      // were corrected here and in the note).
      expect(countFor('RI'), 358);
      expect(countFor('NC'), 6206);
      expect(countFor('CO'), 7329);
      expect(countFor('FL'), 10780);
      expect(countFor('CA'), 23078);
      expect(countFor('TX'), 30379);
      // Alaska's Census bbox spans the antimeridian; read as a
      // plain interval it covers most of the planet — millions of
      // tiles. That is exactly why it has no one-tap pack.
      expect(countFor('AK'), greaterThan(1000000));
    });

    test('a 10x10 km area at zoom 0–16 is a few hundred tiles', () {
      // Center 35.0, -79.0; 10x10 km.
      const halfLat = 5 / 110.54;
      const halfLon = 5 / (111.32 * 0.8191520442889918); // cos(35 deg)
      final n = tileCountForBounds(
        35.0 + halfLat, 35.0 - halfLat,
        -79.0 - halfLon, -79.0 + halfLon,
        0, 16,
      );
      expect(n, greaterThan(300));
      expect(n, lessThan(900));
    });

    test('inverted north/south is zero, never an exception', () {
      expect(tileCountForBounds(30, 35, -80, -79, 0, 12), 0);
    });

    test('arithmetic count equals the list count the downloader uses',
        () {
      // Ground truth: tilesForBounds builds the list the download
      // loop fetches, so the estimate must equal its length.
      for (final (n, s, w, e) in [
        (35.5, 34.5, -79.5, -78.5),
        (36.7, 33.7, -84.5, -75.3),
        (42.0, 41.1, -71.9, -71.1),
        (25.0, 24.5, -87.0, -80.0),
      ]) {
        for (final (z0, z1) in [(0, 3), (0, 8), (0, 12)]) {
          var listed = 0;
          for (var z = z0; z <= z1; z++) {
            listed += tilesForBounds(n, s, w, e, z).length;
          }
          expect(
            tileCountForBounds(n, s, w, e, z0, z1),
            listed,
            reason: 'bbox $n,$s,$w,$e zooms $z0–$z1',
          );
        }
      }
    });
  });

  group('size estimates', () {
    test('NC state pack estimates ~121 MB at 20 KB/tile', () {
      expect(estimateBytesForTiles(6206), 6206 * 20 * 1024);
      // 6206 tiles × 20 KB = 121.2 MB; ≥100 MB renders whole.
      expect(formatBytes(estimateBytesForTiles(6206)), '121 MB');
    });

    test('formatBytes units', () {
      expect(formatBytes(500), '500 B');
      expect(formatBytes(2048), '2 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatBytes(560 * 1024 * 1024), '560 MB');
    });
  });

  group('bestZoomForView', () {
    test('zoomed-out view takes the lowest zoom', () {
      expect(
        bestZoomForView(
          viewMetersPerPixel: 100000,
          latitude: 35.0,
          minZoom: 0,
          maxZoom: 12,
        ),
        0,
      );
    });

    test('field-scale view clamps to the pack max zoom', () {
      // ~0.5 m/px (a 100 m field on a phone screen) is finer than
      // any pack zoom — the answer is the pack's max, stretched.
      expect(
        bestZoomForView(
          viewMetersPerPixel: 0.5,
          latitude: 35.0,
          minZoom: 0,
          maxZoom: 12,
        ),
        12,
      );
      expect(
        bestZoomForView(
          viewMetersPerPixel: 0.5,
          latitude: 35.0,
          minZoom: 0,
          maxZoom: 16,
        ),
        16,
      );
    });

    test('mid-scale view picks the matching zoom', () {
      // z12 tiles at lat 35 are ~31 m/px; a 31 m/px view matches z12.
      expect(
        bestZoomForView(
          viewMetersPerPixel: 31.0,
          latitude: 35.0,
          minZoom: 0,
          maxZoom: 12,
        ),
        12,
      );
      // A 60 m/px view is coarser than z12 (31) but finer than z11
      // (~63) — the first zoom at least as detailed as the view is 11.
      expect(
        bestZoomForView(
          viewMetersPerPixel: 60.0,
          latitude: 35.0,
          minZoom: 0,
          maxZoom: 12,
        ),
        11,
      );
    });
  });

  group('pack source allow-list', () {
    test('USGS only — OSM and Esri are refused for packs', () {
      expect(packSourceAllowed('usgs_topo'), isTrue);
      expect(packSourceAllowed('usgs_imagery'), isTrue);
      expect(packSourceAllowed('osm_standard'), isFalse);
      expect(packSourceAllowed('esri_world_imagery'), isFalse);
      expect(packSourceAllowed('bogus'), isFalse);
    });
  });

  group('file names', () {
    test('state pack file name', () {
      expect(statePackFileName('NC', 'usgs_topo'),
          'state_nc_usgs_topo_z0-12.mbtiles');
    });

    test('area pack file name sanitizes the name', () {
      expect(areaPackFileName('Search Area 7!', 'usgs_topo', 16),
          'area_search_area_7_usgs_topo_z0-16.mbtiles');
      expect(areaPackFileName('', 'usgs_imagery', 16),
          'area_area_usgs_imagery_z0-16.mbtiles');
    });
  });

  group('TilePackMeta JSON', () {
    test('round-trips', () {
      final meta = TilePackMeta(
        id: 'state_nc',
        kind: TilePackKind.state,
        displayName: 'NORTH CAROLINA — STATE BASE',
        sourceId: 'usgs_topo',
        north: 36.7,
        south: 33.7,
        west: -84.5,
        east: -75.3,
        minZoom: 0,
        maxZoom: 12,
        expectedTiles: 6206,
        fileName: 'state_nc_usgs_topo_z0-12.mbtiles',
        status: TilePackStatus.complete,
        downloadedTiles: 6206,
        bytesOnDisk: 127098880,
      );
      final back = TilePackMeta.fromJson(meta.toJson());
      expect(back.id, 'state_nc');
      expect(back.kind, TilePackKind.state);
      expect(back.status, TilePackStatus.complete);
      expect(back.expectedTiles, 6206);
      expect(back.progress, 1.0);
    });

    test('progress is 0 with no expected tiles', () {
      final meta = TilePackMeta(
        id: 'x',
        kind: TilePackKind.area,
        displayName: 'X',
        sourceId: 'usgs_topo',
        north: 1,
        south: 0,
        west: 0,
        east: 1,
        minZoom: 0,
        maxZoom: 16,
        expectedTiles: 0,
        fileName: 'x.mbtiles',
        status: TilePackStatus.downloading,
      );
      expect(meta.progress, 0);
    });
  });

  group('usgsCovers (area-pack coverage guard)', () {
    test('covers the US: CONUS, Alaska, Hawaii, Puerto Rico, USVI', () {
      // Fayetteville NC, Anchorage, Honolulu, San Juan, St. Croix.
      expect(usgsCovers(35.0, -79.0), isTrue);
      expect(usgsCovers(61.2, -149.9), isTrue);
      expect(usgsCovers(21.3, -157.8), isTrue);
      expect(usgsCovers(18.4, -66.0), isTrue);
      expect(usgsCovers(17.7, -64.7), isTrue);
    });

    test('covers the Aleutian antimeridian crossing', () {
      expect(usgsCovers(52.9, 179.7), isTrue);
    });

    test('refuses clearly non-US centers', () {
      // London, Tokyo, Sydney, São Paulo.
      expect(usgsCovers(51.5, -0.1), isFalse);
      expect(usgsCovers(35.7, 139.7), isFalse);
      expect(usgsCovers(-33.9, 151.2), isFalse);
      expect(usgsCovers(-23.5, -46.6), isFalse);
    });
  });
}

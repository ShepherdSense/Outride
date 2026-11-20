/// v0.29.3: on web the tile layer fetches USGS tiles live through
/// [WebTileLoader] (packs are unavailable on web by design). These
/// widget tests prove the layer integration: a layer pumped with an
/// unsupported store + a loader reports web tiles, a failing loader
/// falls back to the grid with no exception, and a source switch
/// reloads the layer on the new source.
///
/// The web branch is gated on the store reporting unsupported —
/// on the VM test host `kIsWeb` is false, so the test stands in an
/// unsupported store subclass for the web store state. The store
/// is constructed inside [WidgetTester.runAsync] (see
/// tile_pack_layer_reload_test.dart: a store built outside runAsync
/// deadlocks on its first index save).
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:outride/screens/tile_pack_layer.dart';
import 'package:outride/services/gps_positioning.dart';
import 'package:outride/services/offline_map_source.dart';
import 'package:outride/services/tile_pack_store.dart';
import 'package:outride/services/web_tile_loader.dart';
import 'package:outride/utils/field_map_transform.dart';

// Minimal 1x1 transparent PNG (same as tile_pack_store_test.dart).
const List<int> _oneByOnePng = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
  0xAE, 0x42, 0x60, 0x82,
];

/// The web store state: packs unsupported, empty by design.
class _UnsupportedStore extends TilePackStore {
  _UnsupportedStore({required Directory packsDir})
      : super(packsDir: packsDir);

  @override
  bool get supported => false;
}

class _FakeTileClient extends http.BaseClient {
  _FakeTileClient({this.status = 200});

  final int status;
  int requests = 0;
  final List<Uri> urls = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    urls.add(request.url);
    return http.StreamedResponse(
      Stream.value(Uint8List.fromList(_oneByOnePng)),
      status,
      request: request,
    );
  }
}

Future<void> _pumpLayer(
  WidgetTester tester,
  TilePackStore store,
  WebTileLoader loader,
  List<TileLayerStatus> statuses,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 300,
          height: 300,
          child: TilePackMapLayer(
            transform: FieldMapTransform.fit(
                const Size(300, 300), [const math.Point(0.0, 0.0)]),
            origin: GpsOrigin(lat: 35.0, lon: -79.0),
            size: const Size(300, 300),
            tilePacks: store,
            webTiles: loader,
            onStatus: statuses.add,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  expect(tester.takeException(), isNull);
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done,
) async {
  for (var i = 0; i < 15 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('the web loader fills the live map layer with tiles',
      (tester) async {
    late Directory tempDir;
    late _UnsupportedStore store;
    await tester.runAsync(() async {
      tempDir =
          await Directory.systemTemp.createTemp('web_tile_layer_test');
      // Constructed here, inside runAsync: see the file header.
      store = _UnsupportedStore(packsDir: tempDir);
    });
    addTearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });
    addTearDown(store.dispose);
    final loader = WebTileLoader(client: _FakeTileClient());
    addTearDown(loader.dispose);

    final statuses = <TileLayerStatus>[];
    await _pumpLayer(tester, store, loader, statuses);
    await _pumpUntil(tester, () => statuses.any((s) => s.hasTiles));

    expect(tester.takeException(), isNull);
    expect(statuses.any((s) => s.hasTiles), isTrue,
        reason: 'the layer must report web tiles once they load');
    expect(statuses.last.packName, contains('USGS TOPO (WEB)'));
    expect(statuses.last.web, isTrue);
    expect(statuses.last.zoom, isNotNull);
    expect(statuses.last.zoom, lessThanOrEqualTo(kWebTileMaxZoom));
    expect(loader.tilesLoaded, greaterThan(0));
  });

  testWidgets('a failing web loader falls back to the grid, no crash',
      (tester) async {
    late Directory tempDir;
    late _UnsupportedStore store;
    await tester.runAsync(() async {
      tempDir =
          await Directory.systemTemp.createTemp('web_tile_layer_test');
      store = _UnsupportedStore(packsDir: tempDir);
    });
    addTearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });
    addTearDown(store.dispose);
    final loader = WebTileLoader(client: _FakeTileClient(status: 500));
    addTearDown(loader.dispose);

    final statuses = <TileLayerStatus>[];
    await _pumpLayer(tester, store, loader, statuses);
    // Wait for the fetches to settle (each failing tile takes two
    // attempts with a 300 ms retry delay in fake time), not just
    // for the first web status — that one lands before any fetch.
    await _pumpUntil(tester, () => loader.failedFetches > 0);

    expect(tester.takeException(), isNull);
    expect(statuses.any((s) => s.web), isTrue,
        reason: 'the layer must report its web state even with no tiles');
    // The layer names the covering source before any tile lands,
    // but nothing is actually painted: zero tiles loaded.
    expect(statuses.every((s) => s.tilesLoaded == 0), isTrue);
    expect(loader.tilesLoaded, 0);
    expect(loader.failedFetches, greaterThan(0));
  });

  testWidgets('switching the web source refetches tiles on the new '
      'source', (tester) async {
    late Directory tempDir;
    late _UnsupportedStore store;
    await tester.runAsync(() async {
      tempDir =
          await Directory.systemTemp.createTemp('web_tile_layer_test');
      store = _UnsupportedStore(packsDir: tempDir);
    });
    addTearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });
    addTearDown(store.dispose);
    final client = _FakeTileClient();
    final loader = WebTileLoader(client: client);
    addTearDown(loader.dispose);

    final statuses = <TileLayerStatus>[];
    await _pumpLayer(tester, store, loader, statuses);
    await _pumpUntil(tester, () => statuses.any((s) => s.hasTiles));
    expect(statuses.last.packName, contains('USGS TOPO (WEB)'));
    final loadedBefore = loader.tilesLoaded;
    expect(loadedBefore, greaterThan(0));
    expect(
      client.urls.every((u) => u.toString().contains('USGSTopo')),
      isTrue,
    );

    loader.setSource(kUsgsImagery);
    // Wait for the fetch AND the status line AND the loaded
    // count: the fetch is issued a frame before the status
    // callback delivers the new label, and the loaded count
    // rises only once the fetches complete.
    await _pumpUntil(
      tester,
      () =>
          client.urls.any(
              (u) => u.toString().contains('USGSImageryOnly')) &&
          statuses.any(
              (s) => (s.packName ?? '').contains('IMAGERY')) &&
          loader.tilesLoaded > loadedBefore,
    );
    expect(tester.takeException(), isNull);
    expect(statuses.last.packName, contains('USGS IMAGERY (WEB)'));
    expect(statuses.last.web, isTrue);
    // The switch must actually refetch on the new source — the
    // v0.29.3 reviewer bug was that the layer kept the old
    // source's tiles (same cache key, label only) and painted
    // Topo as "USGS IMAGERY (WEB)". A label-only assertion
    // would pass with the bug present; these two do not.
    expect(
      client.urls.any((u) => u.toString().contains('USGSImageryOnly')),
      isTrue,
      reason: 'the switch must issue Imagery fetches',
    );
    expect(loader.tilesLoaded, greaterThan(loadedBefore),
        reason: 'new-source tiles must be fetched, not reused');
  });
}

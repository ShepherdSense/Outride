/// v0.29.2: loading/importing a new tile pack updates the Field
/// Map to display it, with no restart. [TilePackMapLayer] subscribes
/// to [TilePackStore] and reloads on change; [TilePackStore]
/// notifies on download-complete. This test proves the path end to
/// end: a layer pumped with an empty store reports no tiles, then a
/// pack download finishing flips it to reporting the new pack —
/// without rebuilding the layer widget.
///
/// Widget-test note: real store I/O (directory + SQLite on the Linux
/// host) must run inside [WidgetTester.runAsync], or the fake-async
/// zone never delivers its completions. That includes CONSTRUCTING
/// the store: [TilePackStore._saveIndex] chains `.then` on a
/// `_saveChain` future born at construction, and a future born in
/// the fake zone queues its callbacks in the fake zone's microtask
/// queue, which stays paused inside `runAsync` — so a store built
/// outside `runAsync` deadlocks on its first index save. The layer's
/// tile reads reuse the store's cached open DB handle
/// (`readTileBytes` keeps up to 2 open), so the test warms that
/// cache with one read inside `runAsync` after the download; the
/// layer's later reads then complete under plain pumps.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:outride/screens/tile_pack_layer.dart';
import 'package:outride/services/gps_positioning.dart';
import 'package:outride/services/offline_map_source.dart';
import 'package:outride/services/tile_pack.dart';
import 'package:outride/services/tile_pack_store.dart';
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

class _FakeTileClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
        Stream.value(Uint8List.fromList(_oneByOnePng)), 200,
        request: request);
  }
}

void main() {
  testWidgets('a pack finishing download reloads the live map layer',
      (tester) async {
    late Directory tempDir;
    late TilePackStore store;
    await tester.runAsync(() async {
      tempDir = await Directory.systemTemp.createTemp('tile_layer_reload_test');
      // Constructed here, inside runAsync: see the file header.
      store = TilePackStore(client: _FakeTileClient(), packsDir: tempDir);
      await store.ensureInitialized();
    });
    addTearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });
    addTearDown(store.dispose);
    expect(store.renderPacks, isEmpty);

    final statuses = <TileLayerStatus>[];
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
              onStatus: statuses.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(store.renderPacks, isEmpty);

    late TilePackMeta meta;
    await tester.runAsync(() async {
      meta = await store.startAreaPack(
        name: 'TEST',
        source: kUsgsTopo,
        north: 35.01,
        south: 34.99,
        west: -79.01,
        east: -78.99,
        maxZoom: 3,
      );
      await store.downloadFuture(meta.id);
      // Warm the store's cached open-DB handle for this pack so the
      // layer's later tile reads complete under plain pumps.
      await store.readTileBytes(meta.id, const TileCoord(3, 2, 3));
    });
    expect(meta.status, TilePackStatus.complete);
    expect(store.renderPacks, isNotEmpty);

    // Let the store notification, the layer's post-frame reload,
    // and the tile decode all land.
    for (var i = 0; i < 10 && statuses.every((s) => !s.hasTiles); i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
    expect(statuses.any((s) => s.hasTiles), isTrue,
        reason: 'the layer must report the new pack after it lands');
    expect(statuses.last.packName, contains('TEST'));
    expect(statuses.last.zoom, 3);
  });
}

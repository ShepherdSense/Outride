/// Tests for TilePackStore (v0.28.0): end-to-end download of a
/// small area pack against a fake HTTP client (real SQLite via
/// sqflite_common_ffi on the Linux test host), source refusal for
/// OSM, pause/resume, delete, and bad-tile failure.
///
/// The store is driven with an injected temp dir + fake client —
// no test here touches the network or the real app documents dir.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:outride/services/offline_map_source.dart';
import 'package:outride/services/tile_pack.dart';
import 'package:outride/services/tile_pack_store.dart';

// Minimal 1x1 transparent PNG (the store only checks the PNG
// magic bytes, but a real PNG keeps the test honest).
const List<int> _oneByOnePng = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];

/// Fake tile server: 200 + a PNG for every tile URL, optionally
/// delayed per tile (for the pause test) or serving garbage bytes
/// (for the failure test).
class _FakeTileClient extends http.BaseClient {
  _FakeTileClient({this.perTileDelay = Duration.zero, this.serveGarbage = false});

  final Duration perTileDelay;
  final bool serveGarbage;

  /// Requests served (counts fetches, so a test can prove a
  /// refused pack never reached the network).
  int requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    if (perTileDelay > Duration.zero) {
      await Future<void>.delayed(perTileDelay);
    }
    final bytes = serveGarbage
        ? Uint8List.fromList('NOT A TILE'.codeUnits)
        : Uint8List.fromList(_oneByOnePng);
    return http.StreamedResponse(Stream.value(bytes), 200,
        request: request);
  }
}

void main() {
  late Directory tempDir;
  late TilePackStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tile_packs_test');
  });

  tearDown(() async {
    try {
      store.dispose();
    } catch (_) {
      // A test that failed before the store was built has nothing
      // to dispose; the late field simply was never assigned.
    }
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  TilePackStore storeWithClient(http.Client client) {
    store = TilePackStore(client: client, packsDir: tempDir);
    return store;
  }

  test('small area pack downloads, verifies, and serves tiles',
      () async {
    storeWithClient(_FakeTileClient());
    final meta = await store.startAreaPack(
      name: 'TEST',
      source: kUsgsTopo,
      north: 35.01,
      south: 34.99,
      west: -79.01,
      east: -78.99,
      maxZoom: 3,
    );
    await store.downloadFuture(meta.id);
    expect(meta.status, TilePackStatus.complete);
    expect(meta.downloadedTiles, meta.expectedTiles);
    expect(meta.downloadedTiles, greaterThan(0));
    expect(meta.bytesOnDisk, greaterThan(0));
    // A tile inside the pack reads back.
    final coord = latLonToTile(35.0, -79.0, 3);
    final bytes = await store.readTileBytes(meta.id, coord);
    expect(bytes, isNotNull);
    expect(bytes!.length, _oneByOnePng.length);
    // A tile outside the pack reads back null, never throws.
    final outside = await store.readTileBytes(
        meta.id, const TileCoord(3, 0, 0));
    expect(outside, isNull);
  });

  test('OSM Standard is refused as a pack source', () async {
    storeWithClient(_FakeTileClient());
    final meta = await store.startAreaPack(
      name: 'OSM TEST',
      source: kOsmStandard,
      north: 35.01,
      south: 34.99,
      west: -79.01,
      east: -78.99,
      maxZoom: 3,
    );
    expect(meta.status, TilePackStatus.error);
    expect(meta.error, contains('NOT ALLOWED'));
    // No file was created for a refused pack.
    final file = File(
        '${tempDir.path}/tile_packs/${meta.fileName}');
    expect(await file.exists(), isFalse);
  });

  test('resuming an OSM-sourced error pack stays error with no fetch',
      () async {
    final client = _FakeTileClient();
    storeWithClient(client);
    final meta = await store.startAreaPack(
      name: 'OSM RESUME TEST',
      source: kOsmStandard,
      north: 35.01,
      south: 34.99,
      west: -79.01,
      east: -78.99,
      maxZoom: 3,
    );
    expect(meta.status, TilePackStatus.error);
    expect(client.requests, 0);
    // The resume path must hit the same source gate as start: the
    // pack stays error and the client is never called.
    await store.resumePack(meta.id);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(meta.status, TilePackStatus.error);
    expect(meta.error, contains('NOT ALLOWED'));
    expect(client.requests, 0);
  });

  test('pause keeps the partial pack; resume completes it', () async {
    storeWithClient(
        _FakeTileClient(perTileDelay: const Duration(milliseconds: 50)));
    final meta = await store.startAreaPack(
      name: 'PAUSE TEST',
      source: kUsgsTopo,
      north: 35.5,
      south: 34.5,
      west: -79.5,
      east: -78.5,
      maxZoom: 12,
    );
    expect(meta.expectedTiles, greaterThan(50));
    // Wait for the first tile to land instead of a fixed delay: on a
    // loaded CI runner (sqflite setup + runner load) zero tiles may
    // have landed after a fixed 400 ms, which made this test a timing
    // flake. Poll until at least one tile is recorded, then pause
    // immediately so the pack is still partial.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (meta.downloadedTiles == 0) {
      if (DateTime.now().isAfter(deadline)) break;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    await store.pausePack(meta.id);
    await store.downloadFuture(meta.id);
    expect(meta.status, TilePackStatus.paused);
    expect(meta.downloadedTiles, greaterThan(0));
    expect(meta.downloadedTiles, lessThan(meta.expectedTiles));
    await store.resumePack(meta.id);
    await store.downloadFuture(meta.id);
    expect(meta.status, TilePackStatus.complete);
    expect(meta.downloadedTiles, meta.expectedTiles);
  });

  test('delete removes the pack and its file', () async {
    storeWithClient(_FakeTileClient());
    final meta = await store.startAreaPack(
      name: 'DELETE TEST',
      source: kUsgsTopo,
      north: 35.01,
      south: 34.99,
      west: -79.01,
      east: -78.99,
      maxZoom: 3,
    );
    await store.downloadFuture(meta.id);
    expect(meta.status, TilePackStatus.complete);
    final file = File('${tempDir.path}/tile_packs/${meta.fileName}');
    expect(await file.exists(), isTrue);
    await store.deletePack(meta.id);
    expect(store.packById(meta.id), isNull);
    expect(await file.exists(), isFalse);
  });

  test('garbage tile bytes fail the pack instead of storing them',
      () async {
    storeWithClient(_FakeTileClient(serveGarbage: true));
    final meta = await store.startAreaPack(
      name: 'GARBAGE TEST',
      source: kUsgsTopo,
      north: 35.001,
      south: 34.999,
      west: -79.001,
      east: -78.999,
      maxZoom: 0,
    );
    expect(meta.expectedTiles, 1);
    await store.downloadFuture(meta.id);
    expect(meta.status, TilePackStatus.error);
    expect(meta.error, contains('FAILED'));
    expect(meta.downloadedTiles, 0);
  });

  test('an orphan .mbtiles with no index entry is adopted on init',
      () async {
    storeWithClient(_FakeTileClient());
    final meta = await store.startAreaPack(
      name: 'ADOPT TEST',
      source: kUsgsTopo,
      north: 35.01,
      south: 34.99,
      west: -79.01,
      east: -78.99,
      maxZoom: 3,
    );
    await store.downloadFuture(meta.id);
    expect(meta.status, TilePackStatus.complete);
    final file = File('${tempDir.path}/tile_packs/${meta.fileName}');
    expect(await file.exists(), isTrue);
    // Lose the index (crash / hand-copied pack): the .mbtiles
    // file is the only thing left.
    await File('${tempDir.path}/tile_packs/packs.json').delete();
    store.dispose();
    // A fresh store on the same dir adopts the orphan.
    final store2 =
        TilePackStore(client: _FakeTileClient(), packsDir: tempDir);
    await store2.ensureInitialized();
    expect(store2.packs.length, 1);
    final adopted = store2.packs.first;
    expect(adopted.fileName, meta.fileName);
    expect(adopted.status, TilePackStatus.complete);
    expect(adopted.downloadedTiles, meta.expectedTiles);
    expect(adopted.expectedTiles, meta.expectedTiles);
    // The adopted pack serves tiles.
    final coord = latLonToTile(35.0, -79.0, 3);
    final bytes = await store2.readTileBytes(adopted.id, coord);
    expect(bytes, isNotNull);
    expect(bytes!.length, _oneByOnePng.length);
    store2.dispose();
  });
}

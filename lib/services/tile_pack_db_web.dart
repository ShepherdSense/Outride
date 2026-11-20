/// Web stub for [TilePackDb]: sqflite has no web backend, so tile
/// packs are unavailable on web. The store checks `kIsWeb` before
/// opening anything and reports "not available on web"; this stub
/// exists so the conditional import compiles and so a stray call
/// fails loudly instead of silently.
library;

import 'dart:typed_data';

import 'offline_map_source.dart';
import 'tile_pack_db.dart';

TilePackDb createTilePackDbImpl(String path) => _WebTilePackDb();

class _WebTilePackDb implements TilePackDb {
  Never _unsupported() =>
      throw UnsupportedError('Tile packs are not available on web.');

  @override
  Future<void> open() async => _unsupported();

  @override
  Future<void> close() async {}

  @override
  Future<void> putTile(TileCoord coord, Uint8List bytes) async =>
      _unsupported();

  @override
  Future<void> putTiles(Map<TileCoord, Uint8List> tiles) async =>
      _unsupported();

  @override
  Future<Uint8List?> readTile(TileCoord coord) async => null;

  @override
  Future<int> tileCount() async => 0;

  @override
  Future<bool> integrityOk() async => false;

  @override
  Future<void> writeMetadata(Map<String, String> values) async =>
      _unsupported();

  @override
  Future<Map<String, String>> readMetadata() async => {};

  @override
  Future<Set<String>> existingTileKeys() async => {};
}

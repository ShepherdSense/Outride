/// MBTiles database access for tile packs (Outride v0.28.0).
///
/// Conditional import: real SQLite on IO platforms, a stub on web
/// (sqflite has no web backend — the store reports packs as
/// unavailable on web and the map degrades to the field canvas).
library;

import 'dart:typed_data';

import 'offline_map_source.dart';
import 'tile_pack_db_stub.dart'
    if (dart.library.io) 'tile_pack_db_io.dart'
    if (dart.library.js_interop) 'tile_pack_db_web.dart';

/// One open `.mbtiles` file.
///
/// The MBTiles spec: `metadata` table (name/value) and `tiles`
/// (zoom_level, tile_column, tile_row, tile_data). `tile_row` is TMS
/// (origin bottom-left): `tile_row = 2^z - 1 - y_xyz`. All methods
/// take XYZ coords and flip internally, so callers never think
/// about TMS.
abstract class TilePackDb {
  /// Opens (or creates) the file and ensures the spec tables exist.
  Future<void> open();

  Future<void> close();

  /// Inserts one tile (upsert by coordinate). No-op after [close].
  Future<void> putTile(TileCoord coord, Uint8List bytes);

  /// Inserts many tiles in one transaction (the downloader batches).
  /// Default implementation loops [putTile]; the SQLite
  /// implementation overrides it with a real batch.
  Future<void> putTiles(Map<TileCoord, Uint8List> tiles) async {
    for (final entry in tiles.entries) {
      await putTile(entry.key, entry.value);
    }
  }

  /// Reads one tile's bytes, or null when absent.
  Future<Uint8List?> readTile(TileCoord coord);

  /// Number of tiles stored.
  Future<int> tileCount();

  /// `PRAGMA integrity_check` — true only when the file is intact.
  Future<bool> integrityOk();

  /// Writes the MBTiles `metadata` table (name/value pairs).
  Future<void> writeMetadata(Map<String, String> values);

  /// Reads the MBTiles `metadata` table (name/value pairs).
  /// Empty when the table is missing or unreadable — used by
  /// orphan adoption, which infers a pack's bounds/zooms/name
  /// from the metadata of a `.mbtiles` file placed in the packs
  /// dir by hand.
  Future<Map<String, String>> readMetadata();

  /// All stored tile keys as `z/x/y` (XYZ), for resume: the
  /// downloader fetches only what is not already here.
  Future<Set<String>> existingTileKeys();
}

/// Opens the database at [path]. On web this returns a stub whose
/// methods report unavailability (the store checks `kIsWeb` first
/// and never calls it on web in practice).
TilePackDb createTilePackDb(String path) => createTilePackDbImpl(path);

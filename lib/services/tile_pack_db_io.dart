/// sqflite implementation of [TilePackDb] (Android, iOS, Windows,
/// Linux, macOS). Desktop uses `sqflite_common_ffi`; mobile uses the
/// platform sqflite factory.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'offline_map_source.dart';
import 'tile_pack_db.dart';

TilePackDb createTilePackDbImpl(String path) => _SqfliteTilePackDb(path);

class _SqfliteTilePackDb implements TilePackDb {
  _SqfliteTilePackDb(this._path);

  final String _path;
  Database? _db;
  bool _closed = false;

  static bool _ffiInitialized = false;

  static void _ensureFactory() {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      if (!_ffiInitialized) {
        sqfliteFfiInit();
        _ffiInitialized = true;
      }
      databaseFactory = databaseFactoryFfi;
    }
  }

  @override
  Future<void> open() async {
    if (_db != null) return;
    _ensureFactory();
    _db = await openDatabase(
      _path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE metadata (name TEXT PRIMARY KEY, value TEXT)',
        );
        await db.execute(
          'CREATE TABLE tiles ('
          'zoom_level INTEGER, '
          'tile_column INTEGER, '
          'tile_row INTEGER, '
          'tile_data BLOB, '
          'UNIQUE(zoom_level, tile_column, tile_row))',
        );
      },
    );
    _closed = false;
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _db?.close();
    _db = null;
  }

  Database _requireDb() {
    final db = _db;
    if (db == null || _closed) {
      throw StateError('TilePackDb is not open.');
    }
    return db;
  }

  /// XYZ -> TMS row flip (MBTiles stores TMS rows).
  static int _tmsRow(TileCoord coord) => (1 << coord.z) - 1 - coord.y;

  @override
  Future<void> putTile(TileCoord coord, Uint8List bytes) async {
    if (_closed) return;
    await _requireDb().insert(
      'tiles',
      {
        'zoom_level': coord.z,
        'tile_column': coord.x,
        'tile_row': _tmsRow(coord),
        'tile_data': bytes,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Inserts many tiles in one transaction (the downloader batches).
  @override
  Future<void> putTiles(Map<TileCoord, Uint8List> tiles) async {
    if (_closed || tiles.isEmpty) return;
    final db = _requireDb();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final entry in tiles.entries) {
        batch.insert(
          'tiles',
          {
            'zoom_level': entry.key.z,
            'tile_column': entry.key.x,
            'tile_row': _tmsRow(entry.key),
            'tile_data': entry.value,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<Uint8List?> readTile(TileCoord coord) async {
    final rows = await _requireDb().query(
      'tiles',
      columns: ['tile_data'],
      where: 'zoom_level = ? AND tile_column = ? AND tile_row = ?',
      whereArgs: [coord.z, coord.x, _tmsRow(coord)],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final data = rows.first['tile_data'];
    return data is Uint8List ? data : null;
  }

  @override
  Future<int> tileCount() async {
    final rows = await _requireDb()
        .rawQuery('SELECT COUNT(*) AS c FROM tiles');
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<bool> integrityOk() async {
    try {
      final rows = await _requireDb()
          .rawQuery('PRAGMA integrity_check');
      if (rows.isEmpty) return false;
      final value = rows.first.values.first;
      return value == 'ok';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Map<String, String>> readMetadata() async {
    final rows = await _requireDb().query(
      'metadata',
      columns: ['name', 'value'],
    );
    return {
      for (final row in rows)
        if (row['name'] is String && row['value'] is String)
          row['name'] as String: row['value'] as String,
    };
  }

  @override
  Future<void> writeMetadata(Map<String, String> values) async {
    final db = _requireDb();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final entry in values.entries) {
        batch.insert(
          'metadata',
          {'name': entry.key, 'value': entry.value},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<Set<String>> existingTileKeys() async {
    final rows = await _requireDb().query(
      'tiles',
      columns: ['zoom_level', 'tile_column', 'tile_row'],
    );
    return {
      for (final row in rows)
        '${row['zoom_level']}/${row['tile_column']}/${(1 << ((row['zoom_level'] as num).toInt())) - 1 - ((row['tile_row'] as num).toInt())}',
    };
  }
}

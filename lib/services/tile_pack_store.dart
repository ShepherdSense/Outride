/// Tile pack store (Outride v0.28.0, EXPERIMENTAL).
///
/// One `.mbtiles` file per pack under the app documents directory
/// (`tile_packs/`), plus a `packs.json` index. Two tiers, one tile
/// fetcher (see the design note
/// `~/workspace/research_notes/outride-tile-packs.md`):
///
/// * Tier 1 — state pack: whole state, zoom 0–12, one tap.
/// * Tier 2 — area pack: rectangle around a search area, zoom 0–16,
///   built per mission.
///
/// LICENSING: pack downloads fetch from USGS endpoints ONLY
/// ([packSourceAllowed] enforces it — OSM Standard and Esri are
/// refused even if the UI ever offered them, because their terms
/// prohibit bulk / offline downloading). The live-view tile cache is
/// a different pattern (view-triggered) and is untouched.
///
/// Download manager: 4 concurrent fetches, retry x3 with backoff,
/// pause keeps the partial DB, resume fetches only missing tiles,
/// cancel deletes the partial pack, verify runs
/// `PRAGMA integrity_check` + a row-count check before a pack is
/// marked complete. Failures mark the pack `error` with a reason —
/// nothing here throws out of the public API.
///
/// Web: packs are unavailable (sqflite has no web backend). The store
/// reports [supported] == false on web; downloads refuse with a
/// human-readable error and the map renders the field canvas only.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'offline_map_source.dart';
import 'tile_pack.dart';
import 'tile_pack_db.dart';

/// Max concurrent tile fetches. USGS publishes no concurrency limit
/// for the tile service; 4 is polite and keeps memory low.
const int kTilePackMaxConcurrent = 4;

/// Retries per tile before the tile is counted failed.
const int kTilePackMaxRetries = 3;

/// Batch size for MBTiles inserts (one transaction per batch).
const int kTilePackInsertBatch = 100;

/// Bytes between progress notifications (throttle: the UI rebuilds
/// on every notification).
const int kTilePackNotifyEveryTiles = 25;

class TilePackStore extends ChangeNotifier {
  TilePackStore({
    http.Client? client,
    Directory? packsDir,
    Future<Directory> Function()? packsDirResolver,
  })  : _client = client ?? http.Client(),
        _injectedDir = packsDir,
        _packsDirResolver = packsDirResolver;

  final http.Client _client;
  final Directory? _injectedDir;
  final Future<Directory> Function()? _packsDirResolver;

  bool _disposed = false;

  /// False on web (no SQLite backend there).
  bool get supported => !kIsWeb;

  Directory? _dir;
  bool _initialized = false;
  final List<TilePackMeta> _packs = [];

  /// Packs, complete ones first, then by display name.
  List<TilePackMeta> get packs {
    final sorted = List<TilePackMeta>.of(_packs);
    sorted.sort((a, b) {
      final aDone = a.status == TilePackStatus.complete ? 0 : 1;
      final bDone = b.status == TilePackStatus.complete ? 0 : 1;
      if (aDone != bDone) return aDone.compareTo(bDone);
      return a.displayName.compareTo(b.displayName);
    });
    return sorted;
  }

  /// Complete packs in render priority order: highest max zoom
  /// first (area detail over state base).
  List<TilePackMeta> get renderPacks {
    final done = _packs
        .where((p) => p.status == TilePackStatus.complete)
        .toList();
    done.sort((a, b) => b.maxZoom.compareTo(a.maxZoom));
    return done;
  }

  int get totalBytes =>
      _packs.fold(0, (sum, p) => sum + p.bytesOnDisk);

  TilePackMeta? packById(String id) {
    for (final p in _packs) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<void> ensureInitialized() async {
    if (_initialized) return;
    if (kIsWeb) {
      // No packs dir on web; the store stays empty by design.
      _initialized = true;
      return;
    }
    final base = _injectedDir ??
        await (_packsDirResolver?.call() ??
            getApplicationDocumentsDirectory());
    _dir = Directory('${base.path}/tile_packs');
    await _dir!.create(recursive: true);
    await _loadIndex();
    // Reconcile: drop index entries whose file is gone; refresh
    // sizes for files that are present.
    var changed = false;
    final kept = <TilePackMeta>[];
    for (final pack in _packs) {
      final file = File('${_dir!.path}/${pack.fileName}');
      if (!await file.exists()) {
        changed = true;
        continue;
      }
      final size = await file.length();
      if (size != pack.bytesOnDisk) {
        pack.bytesOnDisk = size;
        changed = true;
      }
      // A pack left `downloading` by a killed app resumes as paused,
      // never as stuck-downloading.
      if (pack.status == TilePackStatus.downloading) {
        pack.status = TilePackStatus.paused;
        changed = true;
      }
      kept.add(pack);
    }
    _packs
      ..clear()
      ..addAll(kept);
    // Orphan adoption: a `.mbtiles` file in the packs dir with no
    // index entry (a pre-built pack copied in by hand, or an index
    // lost to a crash) is adopted into the index instead of being
    // invisible to the map.
    if (await _adoptOrphans()) changed = true;
    if (changed) await _saveIndex();
    _initialized = true;
  }

  /// Adopts `.mbtiles` files in the packs dir that have no index
  /// entry. A file is adopted only when its SQLite integrity check
  /// passes and it holds at least one tile; anything else is left
  /// on disk untouched — never deleted, never listed. Meta comes
  /// from the MBTiles `metadata` table first (name, bounds,
  /// minzoom, maxzoom), with the file name as fallback. Returns
  /// true when at least one pack was adopted.
  Future<bool> _adoptOrphans() async {
    final dir = _dir;
    if (dir == null) return false;
    final indexed = {for (final p in _packs) p.fileName};
    var adoptedAny = false;
    try {
      final files = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.mbtiles'))
          .cast<File>()
          .toList();
      for (final file in files) {
        final fileName = file.uri.pathSegments.last;
        if (indexed.contains(fileName)) continue;
        final meta = await _metaForOrphan(file, fileName);
        if (meta == null) continue;
        _packs.add(meta);
        adoptedAny = true;
      }
    } catch (_) {
      // Adoption is best-effort: a failed scan never blocks init.
    }
    return adoptedAny;
  }

  Future<TilePackMeta?> _metaForOrphan(File file, String fileName) async {
    TilePackDb? db;
    try {
      db = createTilePackDb(file.path);
      await db.open();
      if (!await db.integrityOk()) return null;
      final count = await db.tileCount();
      if (count <= 0) return null;
      final metadata = await db.readMetadata();
      // Bounds from metadata (`west,south,east,north`); unknown
      // bounds fall back to the whole world — the layer only
      // paints tiles it can read, so an over-broad box costs a
      // lookup, never a wrong map.
      var north = 90.0, south = -90.0, west = -180.0, east = 180.0;
      final boundsRaw = metadata['bounds'];
      if (boundsRaw != null) {
        final parts =
            boundsRaw.split(',').map(double.tryParse).toList();
        if (parts.length == 4 && parts.every((p) => p != null)) {
          west = parts[0]!;
          south = parts[1]!;
          east = parts[2]!;
          north = parts[3]!;
        }
      }
      final minZoom = int.tryParse(metadata['minzoom'] ?? '') ?? 0;
      final maxZoom = int.tryParse(metadata['maxzoom'] ?? '') ?? 12;
      final name = metadata['name'];
      final kind =
          fileName.startsWith('state_') ? TilePackKind.state : TilePackKind.area;
      // Source from our file-name convention when it matches;
      // otherwise unknown — never invented. `unknown` is refused
      // for downloads by the source gate, which is fine: an
      // adopted pack is already on disk and is never re-fetched.
      final base = fileName.replaceAll('.mbtiles', '');
      return TilePackMeta(
        id: 'imported_${base.replaceAll(RegExp(r'[^a-z0-9]+'), '_')}',
        kind: kind,
        displayName: (name == null || name.isEmpty)
            ? base.toUpperCase()
            : name.toUpperCase(),
        sourceId: _sourceIdFromFileName(fileName),
        north: north,
        south: south,
        west: west,
        east: east,
        minZoom: minZoom,
        maxZoom: maxZoom,
        expectedTiles: count,
        fileName: fileName,
        status: TilePackStatus.complete,
        downloadedTiles: count,
        bytesOnDisk: await file.length(),
      );
    } catch (_) {
      return null;
    } finally {
      await db?.close().catchError((_) {});
    }
  }

  static String _sourceIdFromFileName(String fileName) {
    // Our convention: state_<ab>_<source>_z<min>-<max>.mbtiles /
    // area_<name>_<source>_z<min>-<max>.mbtiles.
    final match = RegExp(
            r'^(?:state|area)_.+_(usgs_topo|usgs_imagery)_z\d+-\d+\.mbtiles$')
        .firstMatch(fileName);
    return match?.group(1) ?? 'unknown';
  }

  File get _indexFile => File('${_dir!.path}/packs.json');

  Future<void> _loadIndex() async {
    try {
      if (!await _indexFile.exists()) return;
      final decoded = jsonDecode(await _indexFile.readAsString());
      if (decoded is! List) return;
      _packs.clear();
      for (final entry in decoded) {
        if (entry is Map<String, Object?>) {
          _packs.add(TilePackMeta.fromJson(entry));
        }
      }
    } catch (_) {
      _packs.clear();
    }
  }

  Future<void> _saveChain = Future<void>.value();

  Future<void> _saveIndex() {
    final next = _saveChain.then((_) async {
      try {
        final json = [
          for (final p in _packs) p.toJson(),
        ];
        final tmp = File('${_indexFile.path}.tmp');
        await tmp.writeAsString(jsonEncode(json), flush: true);
        await tmp.rename(_indexFile.path);
      } catch (_) {
        // Best-effort only.
      }
    });
    _saveChain = next;
    return next;
  }

  String _packPath(TilePackMeta pack) => '${_dir!.path}/${pack.fileName}';

  // ------------------------------------------------------------------
  // Starting downloads.
  // ------------------------------------------------------------------

  /// Starts a Tier 1 state pack download. Returns the meta; the
  /// download runs in the background and the meta's status/progress
  /// update via [notifyListeners]. Refuses non-USGS sources and web.
  Future<TilePackMeta> startStatePack(
    StatePackDef def,
    TileSource source,
  ) async {
    await ensureInitialized();
    final id = 'state_${def.abbr.toLowerCase()}';
    final existing = packById(id);
    if (existing != null) return existing;
    final bounds = statePackBounds(def);
    final expected = tileCountForBounds(
      bounds.north,
      bounds.south,
      bounds.west,
      bounds.east,
      kStatePackMinZoom,
      kStatePackMaxZoom,
    );
    final meta = TilePackMeta(
      id: id,
      kind: TilePackKind.state,
      displayName: '${def.name} — STATE BASE',
      sourceId: source.id,
      north: bounds.north,
      south: bounds.south,
      west: bounds.west,
      east: bounds.east,
      minZoom: kStatePackMinZoom,
      maxZoom: kStatePackMaxZoom,
      expectedTiles: expected,
      fileName: statePackFileName(def.abbr, source.id),
      status: TilePackStatus.downloading,
    );
    return _startDownload(meta, source);
  }

  /// Starts a Tier 2 area pack download.
  Future<TilePackMeta> startAreaPack({
    required String name,
    required TileSource source,
    required double north,
    required double south,
    required double west,
    required double east,
    int maxZoom = kAreaPackDefaultMaxZoom,
  }) async {
    await ensureInitialized();
    // Clamp to the offered cap: z17 is not offered anywhere (USGS
    // tops out at level 16) and must never be requested, even by a
    // stale caller passing an old maxZoom.
    maxZoom = maxZoom.clamp(kAreaPackMinZoom, kAreaPackMaxZoom);
    final id =
        'area_${DateTime.now().millisecondsSinceEpoch}';
    final expected = tileCountForBounds(
      north,
      south,
      west,
      east,
      kAreaPackMinZoom,
      maxZoom,
    );
    final meta = TilePackMeta(
      id: id,
      kind: TilePackKind.area,
      displayName: name.isEmpty ? 'AREA PACK' : name.toUpperCase(),
      sourceId: source.id,
      north: north,
      south: south,
      west: west,
      east: east,
      minZoom: kAreaPackMinZoom,
      maxZoom: maxZoom,
      expectedTiles: expected,
      fileName: areaPackFileName(name, source.id, maxZoom),
      status: TilePackStatus.downloading,
    );
    return _startDownload(meta, source);
  }

  Future<TilePackMeta> _startDownload(
    TilePackMeta meta,
    TileSource source,
  ) async {
    if (!supported) {
      meta.status = TilePackStatus.error;
      meta.error = 'TILE PACKS ARE NOT AVAILABLE ON WEB.';
      _packs.add(meta);
      await _saveIndex();
      notifyListeners();
      return meta;
    }
    if (!packSourceAllowed(source.id)) {
      meta.status = TilePackStatus.error;
      meta.error =
          'SOURCE ${source.id.toUpperCase()} IS NOT ALLOWED FOR PACKS '
          '(BULK DOWNLOAD PROHIBITED BY ITS TERMS). USE USGS TOPO OR '
          'USGS IMAGERY.';
      _packs.add(meta);
      await _saveIndex();
      notifyListeners();
      return meta;
    }
    if (_activeDownloads.contains(meta.id)) {
      return meta;
    }
    _packs.add(meta);
    await _saveIndex();
    notifyListeners();
    unawaited(_runDownload(meta, source));
    return meta;
  }

  // ------------------------------------------------------------------
  // Download engine.
  // ------------------------------------------------------------------

  final Set<String> _activeDownloads = {};
  final Map<String, _DownloadControl> _controls = {};
  final Map<String, Future<void>> _downloadFutures = {};

  /// Awaits the in-flight download for [packId] (pause/error/
  /// complete). Null when nothing is running.
  Future<void>? downloadFuture(String packId) => _downloadFutures[packId];

  Future<void> _runDownload(TilePackMeta meta, TileSource source) async {
    // Single choke point for the pack-source gate: every path that
    // fetches tiles (start AND resume) goes through here, so a
    // refused source can never reach the network — even if the
    // caller never checked, or the source id was an unknown one
    // that [selectTileSource] fell back to OSM Standard. The
    // `_startDownload` check below is the early refusal so the UI
    // never shows a refused pack as downloading; this one is the
    // enforcement.
    if (!packSourceAllowed(source.id)) {
      meta.status = TilePackStatus.error;
      meta.error =
          'SOURCE ${source.id.toUpperCase()} IS NOT ALLOWED FOR PACKS '
          '(BULK DOWNLOAD PROHIBITED BY ITS TERMS). USE USGS TOPO OR '
          'USGS IMAGERY.';
      await _saveIndex();
      notifyListeners();
      return;
    }
    final control = _controls[meta.id] ??= _DownloadControl();
    control.reset();
    _activeDownloads.add(meta.id);
    final future = _downloadLoop(meta, source, control);
    _downloadFutures[meta.id] = future;
    await future;
    _downloadFutures.remove(meta.id);
    _activeDownloads.remove(meta.id);
    await _saveIndex();
    notifyListeners();
  }

  Future<void> _downloadLoop(
    TilePackMeta meta,
    TileSource source,
    _DownloadControl control,
  ) async {
    TilePackDb? db;
    try {
      db = createTilePackDb(_packPath(meta));
      await db.open();
      final packDb = db;
      await db.writeMetadata({
        'name': meta.displayName,
        'type': 'baselayer',
        'version': '1.0',
        'description':
            'Outride offline tile pack (${meta.kind.name}), ${meta.sourceId}',
        'format': 'png',
        'bounds':
            '${meta.west},${meta.south},${meta.east},${meta.north}',
        'minzoom': meta.minZoom.toString(),
        'maxzoom': meta.maxZoom.toString(),
        'attribution': source.attribution,
      });
      // Resume: skip tiles already in the file.
      final existing = await db.existingTileKeys();
      final all = <TileCoord>[];
      for (var z = meta.minZoom; z <= meta.maxZoom; z++) {
        all.addAll(tilesForBounds(
          meta.north,
          meta.south,
          meta.west,
          meta.east,
          z,
        ));
      }
      final remaining = all
          .where((c) => !existing.contains('${c.z}/${c.x}/${c.y}'))
          .toList();
      meta.downloadedTiles = existing.length;
      meta.status = TilePackStatus.downloading;
      notifyListeners();

      // Shared work queue + a single writer task (batched inserts).
      var nextIndex = 0;
      final pending = <MapEntry<TileCoord, Uint8List>>[];
      var workersDone = 0;
      var flushed = 0;
      final failed = <TileCoord>[];
      var lastNotify = DateTime.now();

      void noteProgress() {
        final now = DateTime.now();
        if (now.difference(lastNotify).inMilliseconds < 250 &&
            meta.downloadedTiles < meta.expectedTiles) {
          return;
        }
        lastNotify = now;
        notifyListeners();
      }

      Future<void> writer() async {
        while (true) {
          if (pending.isNotEmpty) {
            final batch = pending.toList();
            pending.clear();
            try {
              await packDb.putTiles(Map.fromEntries(batch));
              flushed += batch.length;
            } catch (_) {
              // A failed batch counts its tiles failed (resume
              // re-fetches them; the DB never holds a half batch).
              for (final e in batch) {
                failed.add(e.key);
              }
            }
            // Exact: tiles already in the DB + tiles flushed this run.
            meta.downloadedTiles = existing.length + flushed;
            noteProgress();
          }
          if (workersDone >= kTilePackMaxConcurrent) break;
          if (control.pauseRequested || control.cancelRequested) {
            // Drain what is buffered, then stop.
            if (pending.isEmpty) break;
            continue;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      Future<void> worker() async {
        while (true) {
          if (control.pauseRequested || control.cancelRequested) break;
          TileCoord? coord;
          if (nextIndex < remaining.length) {
            coord = remaining[nextIndex];
            nextIndex++;
          }
          if (coord == null) break;
          var ok = false;
          for (var attempt = 0; attempt < kTilePackMaxRetries; attempt++) {
            if (control.pauseRequested || control.cancelRequested) break;
            try {
              final response = await _client
                  .get(
                    Uri.parse(source.urlFor(coord)),
                    headers: {'User-Agent': kTileUserAgent},
                  )
                  .timeout(const Duration(seconds: 30));
              if (response.statusCode == 200 &&
                  response.bodyBytes.isNotEmpty &&
                  _looksLikeTile(response.bodyBytes)) {
                pending.add(
                    MapEntry(coord, response.bodyBytes));
                ok = true;
                break;
              }
            } catch (_) {
              // Retry below.
            }
            if (attempt < kTilePackMaxRetries - 1) {
              await Future<void>.delayed(
                Duration(milliseconds: 300 * (attempt + 1)),
              );
            }
          }
          if (!ok &&
              !control.pauseRequested &&
              !control.cancelRequested) {
            failed.add(coord);
          }
        }
        workersDone++;
      }

      final writerFuture = writer();
      await Future.wait([
        for (var i = 0; i < kTilePackMaxConcurrent; i++) worker(),
      ]);
      await writerFuture;

      // Final flush of anything the writer has not drained.
      if (pending.isNotEmpty) {
        try {
          await packDb.putTiles(Map.fromEntries(pending));
          flushed += pending.length;
          pending.clear();
        } catch (_) {
          for (final e in pending) {
            failed.add(e.key);
          }
          pending.clear();
        }
      }

      if (control.cancelRequested) {
        await db.close();
        try {
          await File(_packPath(meta)).delete();
        } catch (_) {
          // Partial file already gone; the index entry is removed
          // below regardless.
        }
        _packs.remove(meta);
        _controls.remove(meta.id);
        return;
      }

      final stored = await db.tileCount();
      meta.downloadedTiles = stored;
      final file = File(_packPath(meta));
      meta.bytesOnDisk =
          await file.exists() ? await file.length() : 0;

      if (control.pauseRequested) {
        meta.status = TilePackStatus.paused;
        meta.error = null;
        return;
      }
      if (failed.isNotEmpty) {
        meta.status = TilePackStatus.error;
        meta.error =
            '${failed.length} OF ${meta.expectedTiles} TILES FAILED — '
            'RESUME TO RETRY THEM.';
        return;
      }
      final ok = await db.integrityOk();
      if (!ok || stored != meta.expectedTiles) {
        meta.status = TilePackStatus.error;
        meta.error =
            'VERIFY FAILED — STORED $stored OF ${meta.expectedTiles} '
            'TILES. RESUME TO RETRY.';
        return;
      }
      meta.status = TilePackStatus.complete;
      meta.error = null;
    } catch (e) {
      meta.status = TilePackStatus.error;
      meta.error = 'DOWNLOAD FAILED: ${e.toString().toUpperCase()}';
    } finally {
      await db?.close().catchError((_) {});
    }
  }

  /// PNG (89 50 4E 47) or JPEG (FF D8 FF) magic. USGS Topo serves
  /// PNG, USGS Imagery serves JPEG. Anything else is a bad tile
  /// (e.g. an error page) and is retried, never stored.
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

  // ------------------------------------------------------------------
  // Pause / resume / cancel / delete.
  // ------------------------------------------------------------------

  Future<void> pausePack(String id) async {
    final control = _controls[id];
    if (control != null) control.pauseRequested = true;
    final meta = packById(id);
    if (meta != null && meta.status == TilePackStatus.downloading) {
      // The loop marks it paused when it stops; this is the prompt
      // UI update.
      meta.status = TilePackStatus.paused;
      await _saveIndex();
      notifyListeners();
    }
  }

  Future<TilePackMeta?> resumePack(String id) async {
    final meta = packById(id);
    if (meta == null) return null;
    if (meta.status != TilePackStatus.paused &&
        meta.status != TilePackStatus.error) {
      return meta;
    }
    if (_activeDownloads.contains(id)) return meta;
    final source = selectTileSource(meta.sourceId);
    meta.status = TilePackStatus.downloading;
    meta.error = null;
    await _saveIndex();
    notifyListeners();
    unawaited(_runDownload(meta, source));
    return meta;
  }

  Future<void> cancelPack(String id) async {
    final control = _controls[id];
    if (control != null) {
      control.cancelRequested = true;
      await downloadFuture(id);
      return;
    }
    await deletePack(id);
  }

  Future<void> deletePack(String id) async {
    final meta = packById(id);
    if (meta == null) return;
    if (_activeDownloads.contains(id)) {
      await cancelPack(id);
    }
    _closeReadDb(id);
    try {
      final file = File(_packPath(meta));
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best-effort.
    }
    _packs.remove(meta);
    _controls.remove(id);
    await _saveIndex();
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Reading tiles for the map layer.
  // ------------------------------------------------------------------

  final Map<String, TilePackDb> _openReadDbs = {};

  void _closeReadDb(String packId) {
    final db = _openReadDbs.remove(packId);
    unawaited(db?.close().catchError((_) {}));
  }

  /// Reads one tile's bytes from a pack, or null when absent /
  /// unreadable / web. Never throws.
  Future<Uint8List?> readTileBytes(String packId, TileCoord coord) async {
    if (kIsWeb) return null;
    try {
      await ensureInitialized();
      final meta = packById(packId);
      if (meta == null || meta.status != TilePackStatus.complete) {
        return null;
      }
      var db = _openReadDbs[packId];
      if (db == null) {
        // Keep at most 2 pack DBs open; close the least-recently
        // used one first.
        if (_openReadDbs.length >= 2) {
          final oldest = _openReadDbs.keys.first;
          _closeReadDb(oldest);
        }
        db = createTilePackDb(_packPath(meta));
        await db.open();
        _openReadDbs[packId] = db;
      }
      return await db.readTile(coord);
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    // A download's post-loop notify can land after dispose (the
    // loop future completes first, then _runDownload's continuation
    // runs save + notify). The _disposed guard below makes that a
    // no-op instead of a use-after-dispose throw.
    _disposed = true;
    for (final db in _openReadDbs.values) {
      unawaited(db.close().catchError((_) {}));
    }
    _openReadDbs.clear();
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }
}

/// Per-download pause/cancel flags (checked between tiles).
class _DownloadControl {
  bool pauseRequested = false;
  bool cancelRequested = false;

  void reset() {
    pauseRequested = false;
    cancelRequested = false;
  }
}

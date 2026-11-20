/// v0.29.3: the web live-tile loader fetches USGS tiles over the
/// network for the sim's live GPS map (packs are unavailable on
/// web by design). These are unit tests for [WebTileLoader] itself:
/// cache-first fetching, retry rules, the USGS-only source gate,
/// in-flight dedup, and the LRU bounds. The layer integration
/// (loader → TilePackMapLayer → status) is covered by
/// web_tile_layer_test.dart.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:outride/services/offline_map_source.dart';
import 'package:outride/services/web_tile_loader.dart';

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

const List<int> _notAnImage = [0x3C, 0x68, 0x74, 0x6D, 0x6C, 0x3E];

class _CountingClient extends http.BaseClient {
  _CountingClient({
    required this.status,
    required this.body,
    this.delay = Duration.zero,
  });

  final int status;
  final List<int> body;
  final Duration delay;

  int requests = 0;
  final List<Uri> urls = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    urls.add(request.url);
    if (delay != Duration.zero) await Future<void>.delayed(delay);
    return http.StreamedResponse(
      Stream.value(Uint8List.fromList(body)),
      status,
      request: request,
    );
  }
}

class _ThrowingClient extends http.BaseClient {
  int requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests++;
    throw http.ClientException('no network');
  }
}

/// Tracks how many requests overlap, to prove the concurrency cap.
class _ConcurrentClient extends http.BaseClient {
  int inFlight = 0;
  int maxInFlight = 0;
  int requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    } finally {
      inFlight--;
    }
    return http.StreamedResponse(
      Stream.value(Uint8List.fromList(_oneByOnePng)),
      200,
      request: request,
    );
  }
}

void main() {
  group('WebTileLoader fetch', () {
    test('fetches a tile and serves the second fetch from cache', () async {
      final client = _CountingClient(status: 200, body: _oneByOnePng);
      final loader = WebTileLoader(client: client);
      addTearDown(loader.dispose);

      final first = await loader.fetchTile(const TileCoord(12, 1150, 1621));
      expect(first, Uint8List.fromList(_oneByOnePng));
      final second = await loader.fetchTile(const TileCoord(12, 1150, 1621));
      expect(second, Uint8List.fromList(_oneByOnePng));
      expect(client.requests, 1,
          reason: 'the second fetch must not hit the network');
      expect(loader.cachedTiles, 1);
      expect(loader.tilesLoaded, 1);
      expect(loader.failedFetches, 0);
    });

    test('a 404 is a missing tile and is not retried', () async {
      final client = _CountingClient(status: 404, body: _notAnImage);
      final loader = WebTileLoader(client: client);
      addTearDown(loader.dispose);

      expect(
        await loader.fetchTile(const TileCoord(12, 1150, 1621)),
        isNull,
      );
      expect(client.requests, 1,
          reason: 'a tile the service does not have is terminal');
      expect(loader.failedFetches, 1);
      expect(loader.tilesLoaded, 0);
    });

    test('a 500 is retried once, then a missing tile', () async {
      final client = _CountingClient(status: 500, body: _notAnImage);
      final loader = WebTileLoader(client: client);
      addTearDown(loader.dispose);

      expect(
        await loader.fetchTile(const TileCoord(12, 1150, 1621)),
        isNull,
      );
      expect(client.requests, 2);
      expect(loader.failedFetches, 1);
    });

    test('a 200 with non-image bytes is a missing tile', () async {
      final client = _CountingClient(status: 200, body: _notAnImage);
      final loader = WebTileLoader(client: client);
      addTearDown(loader.dispose);

      expect(
        await loader.fetchTile(const TileCoord(12, 1150, 1621)),
        isNull,
      );
      expect(loader.tilesLoaded, 0);
      expect(loader.cachedTiles, 0,
          reason: 'an error page is never stored');
    });

    test('a throwing client never throws', () async {
      final loader = WebTileLoader(client: _ThrowingClient());
      addTearDown(loader.dispose);

      expect(
        await loader.fetchTile(const TileCoord(12, 1150, 1621)),
        isNull,
      );
      expect(loader.failedFetches, 1);
    });

    test('concurrent fetches for the same tile share one request',
        () async {
      final client = _CountingClient(
        status: 200,
        body: _oneByOnePng,
        delay: const Duration(milliseconds: 50),
      );
      final loader = WebTileLoader(client: client);
      addTearDown(loader.dispose);

      final results = await Future.wait([
        loader.fetchTile(const TileCoord(12, 1150, 1621)),
        loader.fetchTile(const TileCoord(12, 1150, 1621)),
      ]);
      expect(results[0], isNotNull);
      expect(results[1], isNotNull);
      expect(client.requests, 1);
    });

    test('at most 4 tile fetches run at once (reviewer fix)', () async {
      final client = _ConcurrentClient();
      final loader = WebTileLoader(client: client);
      addTearDown(loader.dispose);

      final results = await Future.wait([
        for (var i = 0; i < 10; i++)
          loader.fetchTile(TileCoord(10, i, 400)),
      ]);
      expect(results.every((b) => b != null), isTrue);
      expect(client.requests, 10);
      expect(client.maxInFlight,
          lessThanOrEqualTo(kWebTileMaxConcurrentFetches),
          reason: 'a pan/zoom must not fire dozens of simultaneous GETs');
      expect(loader.tilesLoaded, 10);
    });

    test('the cache is bounded: the oldest tile evicts first', () async {
      final client = _CountingClient(status: 200, body: _oneByOnePng);
      final loader = WebTileLoader(client: client);
      addTearDown(loader.dispose);

      // One more than the cap, all distinct tiles.
      for (var i = 0; i <= kWebTileMaxCachedTiles; i++) {
        await loader.fetchTile(TileCoord(10, i, 400));
      }
      expect(loader.cachedTiles, kWebTileMaxCachedTiles);
      expect(loader.cachedBytes, lessThanOrEqualTo(kWebTileMaxCachedBytes));
      // The first tile evicted: fetching it again hits the network.
      final before = client.requests;
      await loader.fetchTile(const TileCoord(10, 0, 400));
      expect(client.requests, before + 1);
    });
  });

  group('WebTileLoader source', () {
    test('a non-USGS source falls back to USGS Topo', () async {
      final client = _CountingClient(status: 200, body: _oneByOnePng);
      final loader = WebTileLoader(client: client, source: kOsmStandard);
      addTearDown(loader.dispose);

      expect(loader.source.id, 'usgs_topo');
      await loader.fetchTile(const TileCoord(12, 1150, 1621));
      expect(client.urls.single.toString(), contains('USGSTopo'));
    });

    test('setSource to Imagery switches the fetch URL', () async {
      final client = _CountingClient(status: 200, body: _oneByOnePng);
      final loader = WebTileLoader(client: client);
      addTearDown(loader.dispose);

      await loader.fetchTile(const TileCoord(12, 1150, 1621));
      expect(client.urls.single.toString(), contains('USGSTopo'));
      loader.setSource(kUsgsImagery);
      expect(loader.source.id, 'usgs_imagery');
      await loader.fetchTile(const TileCoord(12, 1150, 1621));
      expect(client.requests, 2,
          reason: 'the cache is source-specific and was cleared');
      expect(client.urls.last.toString(), contains('USGSImageryOnly'));
    });

    test('setSource to OSM falls back to Topo', () {
      final loader = WebTileLoader();
      addTearDown(loader.dispose);

      loader.setSource(kUsgsImagery);
      expect(loader.source.id, 'usgs_imagery');
      loader.setSource(kOsmStandard);
      expect(loader.source.id, 'usgs_topo',
          reason: 'the loader never fetches OSM Standard');
    });

    test('setSource to the same source is a no-op', () async {
      final client = _CountingClient(status: 200, body: _oneByOnePng);
      final loader = WebTileLoader(client: client);
      addTearDown(loader.dispose);

      await loader.fetchTile(const TileCoord(12, 1150, 1621));
      var notifications = 0;
      loader.addListener(() => notifications++);
      loader.setSource(kUsgsTopo);
      expect(notifications, 0);
      await loader.fetchTile(const TileCoord(12, 1150, 1621));
      expect(client.requests, 1,
          reason: 'the cache must survive a no-op source set');
    });

    test('webTileSourceFor resolves USGS ids and falls back', () {
      expect(webTileSourceFor('usgs_imagery').id, 'usgs_imagery');
      expect(webTileSourceFor('usgs_topo').id, 'usgs_topo');
      expect(webTileSourceFor('osm_standard').id, 'usgs_topo');
      expect(webTileSourceFor('bogus').id, 'usgs_topo');
      expect(webTileSourceFor(null).id, 'usgs_topo');
    });
  });
}

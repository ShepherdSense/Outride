/// v0.29.4: web tile rendering regressions — the live browser check
/// on 0.29.3 found three defects in the compact map + full Field Map:
///
/// 1. SEVERE PIXELATION. A z16 tile pixel is ~1.96 m on the ground
///    at lat 35, while the field view sits at ~12 px/m — so the
///    256 px tile was stretched ~23x (each tile pixel ~23 screen
///    px). That is inherent to the view scale, not a placement bug:
///    the fix is a TRUE 1:1 (one tile pixel = one screen pixel) at
///    the tile-native view scale, on both maps, plus an honest
///    render-scale readout (1:1 / ×N) in the status line. These
///    tests pin the scale math the 1:1 controls and the readout
///    share.
/// 2. BLACK SEAM. The painters aspect-fit each tile inside its
///    geographic placement rect; the placement is ~0.7% wider than
///    tall (equirectangular vs Web-Mercator), so fit-centering left
///    ~30 px of unpainted margin on each side of every tile at
///    field zoom — a black vertical stripe against the dark map.
///    The fix fills the placement rect edge to edge (the <1%
///    stretch is invisible) and paints a failed tile as the
///    labeled blank grid, never black. These tests pin the fill
///    geometry and the no-black pixel contract.
/// 3. DROPDOWN / EFFECTIVE-SOURCE DISAGREEMENT. On web the
///    Settings dropdown showed "OpenStreetMap Standard" while the
///    loader rendered USGS Topo. These tests pin the effective-
///    source resolution the dropdown now uses.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:outride/screens/picture_screen.dart';
import 'package:outride/screens/tile_pack_layer.dart';
import 'package:outride/screens/tracking.dart';
import 'package:outride/services/offline_map_source.dart';
import 'package:outride/services/tile_pack.dart';
import 'package:outride/services/web_tile_loader.dart';
import 'package:outride/state/app_state.dart';
import 'package:outride/theme.dart';
import 'package:outride/utils/field_map_transform.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('tile render scale (v0.29.4 defect 1)', () {
    test('a z16 tile pixel is ~1.96 m at lat 35 (Fayetteville)', () {
      expect(tileMetersPerPixel(16, 35.0), closeTo(1.96, 0.01));
      expect(tileMetersPerPixel(16, 35.05), closeTo(1.96, 0.01));
    });

    test('the tile-native 1:1 scale at z16 lat 35 is ~0.51 px/m', () {
      expect(tileNativeScalePxPerMeter(16, 35.0), closeTo(0.51, 0.01));
    });

    test('a field-zoom view stretches a z16 tile ~23x', () {
      // The 0.29.3 live defect: 12 px/m field view, each tile
      // pixel ~23 screen px, place-name letters ~150 px tall.
      expect(
        tileRenderScale(
          viewScalePxPerMeter: 12.0,
          zoom: 16,
          latitude: 35.0,
        ),
        closeTo(23.5, 0.2),
      );
    });

    test('the tile-native scale renders at exactly 1:1', () {
      final native = tileNativeScalePxPerMeter(16, 35.0);
      expect(
        tileRenderScale(
          viewScalePxPerMeter: native,
          zoom: 16,
          latitude: 35.0,
        ),
        closeTo(1.0, 1e-9),
      );
    });

    test('bestZoomForView still picks z16 for a field-scale view', () {
      // The tile zoom cannot go finer than the USGS z16 cap: the
      // buttons move the VIEW scale, never the Z readout.
      expect(
        bestZoomForView(
          viewMetersPerPixel: 1 / 12.0,
          latitude: 35.0,
          minZoom: 0,
          maxZoom: 16,
        ),
        16,
      );
    });

    test('mapZoomForTileOneToOne lands the view on the native scale', () {
      const fitScale = 12.0;
      final zoom = mapZoomForTileOneToOne(
        fitScalePxPerMeter: fitScale,
        tileZoom: 16,
        latitude: 35.0,
      );
      // ~0.043: far below the old 0.5 zoom floor, which is why the
      // old 1:1 reset (fit zoom) could never be crisp.
      expect(zoom, closeTo(0.043, 0.002));
      expect(fitScale * zoom,
          closeTo(tileNativeScalePxPerMeter(16, 35.0), 1e-9));
    });

    test('mapZoomForTileOneToOne falls back to the fit on bad input', () {
      expect(
        mapZoomForTileOneToOne(
          fitScalePxPerMeter: 0,
          tileZoom: 16,
          latitude: 35.0,
        ),
        1.0,
      );
    });

    test('tileRenderScaleLabel reads 1:1 at native, ×N stretched', () {
      expect(tileRenderScaleLabel(1.0), '1:1');
      expect(tileRenderScaleLabel(1.03), '1:1');
      expect(tileRenderScaleLabel(0.98), '1:1');
      expect(tileRenderScaleLabel(2.5), '×2.5');
      expect(tileRenderScaleLabel(23.5), '×24');
    });

    test('TileLayerStatus carries the render scale in equality', () {
      const a = TileLayerStatus(
        packName: 'USGS TOPO (WEB)',
        zoom: 16,
        tilesLoaded: 4,
        web: true,
        renderScale: 1.0,
      );
      const b = TileLayerStatus(
        packName: 'USGS TOPO (WEB)',
        zoom: 16,
        tilesLoaded: 4,
        web: true,
        renderScale: 1.0,
      );
      const stretched = TileLayerStatus(
        packName: 'USGS TOPO (WEB)',
        zoom: 16,
        tilesLoaded: 4,
        web: true,
        renderScale: 23.5,
      );
      expect(a, b);
      expect(a, isNot(stretched));
      expect(a.hashCode, b.hashCode);
    });
  });

  group('tile fill rect + missing-tile grid (v0.29.4 defect 2)', () {
    test('tileFillRect fills the placement edge to edge, no letterbox', () {
      // The 0.29.3 seam: a 500.6 x 497.1 m placement (0.7% wider
      // than tall) fit-centered left ~30 px unpainted per side at
      // field zoom. Fill returns the placement itself.
      const placement = Rect.fromLTWH(0, 0, 500.6, 497.1);
      expect(
        tileFillRect(placement, const Size(256, 256)),
        placement,
      );
      expect(
        tileFillRect(
          const Rect.fromLTWH(10, 20, 100, 97),
          const Size(256, 256),
        ),
        const Rect.fromLTWH(10, 20, 100, 97),
      );
    });

    testWidgets('a tile image fills its whole placement rect',
        (tester) async {
      // Real engine async (Picture.toImage / toByteData) must run
      // outside the test's fake-async zone, or it never completes.
      await tester.runAsync(() async {
        final image = await _solidImage(const Color(0xFFFF0000), 4, 4);
        final painter = TileBackgroundPainter(
          placements: [
            TilePlacement(
              rect: const Rect.fromLTWH(10, 10, 100, 97),
              coord: const TileCoord(16, 18404, 25947),
              image: image,
            ),
          ],
        );
        final pixels = await _paintPixels(painter, const Size(200, 200));
        image.dispose();
        // Every corner of the placement — including the ~0.7%
        // letterbox strip the old fit-centering left unpainted —
        // is the tile's own red, never background.
        for (final (x, y) in [
          (10, 10),
          (109, 10),
          (10, 106),
          (109, 106)
        ]) {
          expect(_pixel(pixels, 200, x, y), [255, 0, 0, 255],
              reason: 'corner ($x, $y) must be tile red');
        }
        expect(_pixel(pixels, 200, 60, 58), [255, 0, 0, 255]);
      });
    });

    testWidgets('a missing tile paints a labeled grid, never black',
        (tester) async {
      await tester.runAsync(() async {
        final painter = TileBackgroundPainter(
          placements: [
            const TilePlacement(
              rect: Rect.fromLTWH(10, 10, 100, 100),
              coord: TileCoord(16, 18404, 25947),
            ),
          ],
        );
        final pixels = await _paintPixels(painter, const Size(200, 200));
        var paintedPixels = 0;
        // The border is a 1 px stroke centered on the rect edge,
        // so its pixels are ~50% coverage: read-back bytes are
        // premultiplied, so match the grid color's SHAPE (r == g,
        // b > r — 0x3A3A4A) rather than its exact opaque RGB.
        var topEdgeGrid = 0;
        var leftEdgeGrid = 0;
        for (var y = 0; y < 200; y++) {
          for (var x = 0; x < 200; x++) {
            final o = (y * 200 + x) * 4;
            final r = pixels[o];
            final g = pixels[o + 1];
            final b = pixels[o + 2];
            final a = pixels[o + 3];
            // The 0.29.3 defect: a missing column rendered as a
            // black stripe. No pixel of a missing tile may be
            // opaque black.
            expect(
              !(r == 0 && g == 0 && b == 0 && a == 255),
              isTrue,
              reason: 'pixel ($x, $y) is opaque black',
            );
            if (a > 0) paintedPixels++;
            final isGridShaped = a > 0 && r == g && b > r;
            if (y == 10 && x >= 10 && x < 110 && isGridShaped) {
              topEdgeGrid++;
            }
            if (x == 10 && y >= 10 && y < 110 && isGridShaped) {
              leftEdgeGrid++;
            }
          }
        }
        // The grid border is drawn (top + left edges present) and
        // the cell is visibly painted (border + NO CACHED TILE
        // label).
        expect(topEdgeGrid, greaterThan(0));
        expect(leftEdgeGrid, greaterThan(0));
        expect(paintedPixels, greaterThan(300));
      });
    });
  });

  group('dropdown shows the effective source (v0.29.4 defect 3)', () {
    test('on web a stored OSM selection resolves to USGS Topo', () {
      expect(
        effectiveTileSourceIdFor(storedId: 'osm_standard', isWeb: true),
        'usgs_topo',
      );
      expect(
        effectiveTileSourceIdFor(storedId: 'usgs_imagery', isWeb: true),
        'usgs_imagery',
      );
      expect(
        effectiveTileSourceIdFor(storedId: 'usgs_topo', isWeb: true),
        'usgs_topo',
      );
      expect(
        effectiveTileSourceIdFor(storedId: 'bogus', isWeb: true),
        'usgs_topo',
      );
    });

    test('on native the stored id is shown as-is', () {
      expect(
        effectiveTileSourceIdFor(storedId: 'osm_standard', isWeb: false),
        'osm_standard',
      );
      expect(
        effectiveTileSourceIdFor(storedId: 'usgs_imagery', isWeb: false),
        'usgs_imagery',
      );
    });

    test('on web the dropdown offers USGS sources only', () {
      expect(
        tileSourceOptionsFor(isWeb: true).map((s) => s.id),
        ['usgs_imagery', 'usgs_topo'],
      );
      expect(
        tileSourceOptionsFor(isWeb: false).map((s) => s.id),
        ['osm_standard', 'usgs_imagery', 'usgs_topo'],
      );
    });
  });

  group('1:1 by default + persistence (v0.29.5)', () {
    setUp(() {
      // These tests exercise the maps against the simulated demo
      // anchor, so they store a simulated choice: the fresh-install
      // default is now LIVE (see simulated_mode), and the async
      // settings load would otherwise flip the maps to LIVE mid-test
      // (no origin, no 1:1 default).
      SharedPreferences.setMockInitialValues({
        'rf_sentry_zmeta_v1': jsonEncode({'simulatedMode': true}),
      });
    });

    test('AppState defaults to 1:1 on', () {
      final state = AppState();
      addTearDown(state.dispose);
      expect(state.tileOneToOne, isTrue);
    });

    test('setTileOneToOne notifies only on change', () {
      final state = AppState();
      addTearDown(state.dispose);
      var notified = 0;
      state.addListener(() => notified++);
      state.setTileOneToOne(true); // already on: no notify
      expect(notified, 0);
      state.setTileOneToOne(false);
      expect(state.tileOneToOne, isFalse);
      expect(notified, 1);
      state.setTileOneToOne(false); // same value: no notify
      expect(notified, 1);
      state.setTileOneToOne(true);
      expect(notified, 2);
    });

    test('tileOneToOneControlLabel shows the true state', () {
      expect(tileOneToOneControlLabel(oneToOneActive: true), '1:1 ON');
      expect(
          tileOneToOneControlLabel(
              oneToOneActive: true, renderScale: 23.5),
          '1:1 ON');
      expect(tileOneToOneControlLabel(oneToOneActive: false), 'FIT');
      expect(
          tileOneToOneControlLabel(
              oneToOneActive: false, renderScale: 1.0),
          '1:1');
      expect(
          tileOneToOneControlLabel(
              oneToOneActive: false, renderScale: 2.5),
          '×2.5');
      expect(
          tileOneToOneControlLabel(
              oneToOneActive: false, renderScale: 23.5),
          '×24');
    });

    testWidgets('compact map defaults to 1:1 ON with an honest pill',
        (tester) async {
      tester.view.physicalSize = const Size(360, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
            theme: buildDarkTheme(),
            home: Scaffold(body: PictureScreen(state: state))),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      // Default is 1:1, and the pill says so — never the bare
      // '1:1' the v0.29.4 pill showed while stretched.
      expect(find.text('1:1 ON'), findsOneWidget);
      expect(find.text('1:1'), findsNothing);
      // Tap the pill: 1:1 turns off and the pill shows the
      // stretch, never '1:1'. The tap must toggle, NOT open the
      // full map (the pill wins the tap arena over the ancestor
      // GestureDetector) — no TrackingScreen route appears.
      await tester.tap(find.text('1:1 ON'));
      await tester.pump();
      expect(find.byType(TrackingScreen), findsNothing);
      expect(find.text('1:1 ON'), findsNothing);
      expect(find.text('1:1'), findsNothing);
      expect(find.textContaining(RegExp(r'^×\d+')), findsOneWidget);
      // Tap again: back to 1:1 ON.
      await tester.tap(find.textContaining(RegExp(r'^×\d+')));
      await tester.pump();
      expect(find.byType(TrackingScreen), findsNothing);
      expect(find.text('1:1 ON'), findsOneWidget);
    });

    testWidgets('compact map renders at the native scale by default',
        (tester) async {
      tester.view.physicalSize = const Size(360, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
            theme: buildDarkTheme(),
            home: Scaffold(body: PictureScreen(state: state))),
      );
      await tester.pump();
      await tester.pump();
      // Same wiring guard as the full-map test: the pill saying
      // '1:1 ON' is derived from the same helper that builds the
      // transform, so pin the pixels — the layer must actually be
      // at the tile-native scale, not the fit scale.
      final layer =
          tester.widget<TilePackMapLayer>(find.byType(TilePackMapLayer));
      expect(
        layer.transform.scale,
        closeTo(_nativeScaleFor(state, layer.size), 0.001),
      );
      expect(layer.transform.scale,
          lessThan(_fitScaleFor(state, layer.size)));
    });

    testWidgets('pill reports scale; the status line owns tile presence',
        (tester) async {
      // Review follow-up (v0.29.5): with an origin but no tiles
      // loaded (no packs in the test env), the pill reads the view
      // scale — '1:1 ON' at native — while the status line says
      // GRID ONLY. The control never claims tiles exist; presence
      // is the status line's job (its source name is gated on
      // tilesLoaded > 0).
      tester.view.physicalSize = const Size(360, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
            theme: buildDarkTheme(),
            home: Scaffold(body: PictureScreen(state: state))),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('1:1 ON'), findsOneWidget);
      expect(find.textContaining('TILES: NONE — GRID ONLY'),
          findsOneWidget);
    });

    testWidgets('1:1 survives the Picture screen being rebuilt',
        (tester) async {
      // Models a bottom-nav tab switch: the dashboard keeps the
      // same AppState but disposes and recreates the tab's State.
      // The v0.29.4 defect: the choice lived in that State, so the
      // map came back stretched with the pill lying '1:1'.
      tester.view.physicalSize = const Size(360, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      Future<void> pumpPicture() async {
        await tester.pumpWidget(
          MaterialApp(
              theme: buildDarkTheme(),
              home: Scaffold(body: PictureScreen(state: state))),
        );
        await tester.pump();
      }

      await pumpPicture();
      expect(find.text('1:1 ON'), findsOneWidget);
      await tester.tap(find.text('1:1 ON'));
      await tester.pump();
      expect(find.byType(TrackingScreen), findsNothing);
      expect(find.textContaining(RegExp(r'^×\d+')), findsOneWidget);
      await pumpPicture();
      expect(find.text('1:1 ON'), findsNothing);
      expect(find.text('1:1'), findsNothing);
      expect(find.textContaining(RegExp(r'^×\d+')), findsOneWidget);
      // And back on: the preference sticks the other way too.
      await tester.tap(find.textContaining(RegExp(r'^×\d+')));
      await tester.pump();
      expect(find.byType(TrackingScreen), findsNothing);
      await pumpPicture();
      expect(find.text('1:1 ON'), findsOneWidget);
    });

    testWidgets('full Field Map defaults to 1:1 ON; + leaves 1:1',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TrackingScreen(state: state))),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('1:1 ON'), findsOneWidget);
      expect(find.text('1:1'), findsNothing);
      // Toggle off: the button shows the stretch, never bare '1:1'.
      await tester.tap(find.text('1:1 ON'));
      await tester.pump();
      expect(find.text('1:1 ON'), findsNothing);
      expect(find.text('1:1'), findsNothing);
      expect(find.textContaining(RegExp(r'^×\d+')), findsOneWidget);
      // Toggle back on.
      await tester.tap(find.textContaining(RegExp(r'^×\d+')));
      await tester.pump();
      expect(find.text('1:1 ON'), findsOneWidget);
      // + zoom leaves 1:1: the button drops to the stretch, and
      // the SHARED preference flips — the compact map reads off.
      await tester.tap(find.text('+'));
      await tester.pump();
      expect(find.text('1:1 ON'), findsNothing);
      expect(find.text('1:1'), findsNothing);
      expect(find.textContaining(RegExp(r'^×\d+')), findsOneWidget);
      expect(state.tileOneToOne, isFalse);
    });

    testWidgets('full map renders at the native scale by default',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TrackingScreen(state: state))),
      );
      await tester.pump();
      await tester.pump();
      // The label says '1:1 ON' — but the label is derived from the
      // preference, so pin the pixels: the layer's transform must
      // actually be at the tile-native scale, not the fit scale. A
      // wiring bug that returned the fit view here would still print
      // '1:1 ON' and pass the label tests above.
      final layer =
          tester.widget<TilePackMapLayer>(find.byType(TilePackMapLayer));
      expect(
        layer.transform.scale,
        closeTo(_nativeScaleFor(state, layer.size), 0.001),
      );
      expect(layer.transform.scale, lessThan(_fitScaleFor(state, layer.size)));
    });

    testWidgets('toggling 1:1 off restores the manual zoom',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TrackingScreen(state: state))),
      );
      await tester.pump();
      final native = _mapScale(tester);
      await tester.tap(find.text('+'));
      await tester.pump();
      final zoomed = _mapScale(tester);
      expect(zoomed, closeTo(native * 1.25, native * 0.01));
      // The 1:1 button now shows the stretch; tap it to go 1:1.
      await tester.tap(find.textContaining(RegExp(r'^×\d+')));
      await tester.pump();
      expect(find.text('1:1 ON'), findsOneWidget);
      expect(_mapScale(tester), closeTo(native, native * 0.01));
      // Toggle off: back to the manual zoom, not the fit.
      await tester.tap(find.text('1:1 ON'));
      await tester.pump();
      expect(_mapScale(tester), closeTo(zoomed, zoomed * 0.01));
    });

    testWidgets('scroll wheel leaves 1:1', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TrackingScreen(state: state))),
      );
      await tester.pump();
      expect(find.text('1:1 ON'), findsOneWidget);
      final before = _mapScale(tester);
      // The map sits below the fold at phone height: scroll it into
      // view first, or the wheel event lands outside the viewport
      // and never reaches the map's Listener (tester.tap scrolls
      // into view automatically; a raw pointer event does not).
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pump();
      final mapCenter = tester.getCenter(find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is TrackingMapPainter));
      tester.binding.handlePointerEvent(PointerScrollEvent(
        position: mapCenter,
        scrollDelta: const Offset(0, -120),
      ));
      await tester.pump();
      expect(find.text('1:1 ON'), findsNothing);
      expect(state.tileOneToOne, isFalse);
      expect(_mapScale(tester), closeTo(before * 1.12, before * 0.01));
    });

    testWidgets('manual zoom survives 1:1 toggle with no origin',
        (tester) async {
      // Reviewer regression test (v0.29.5 review): live mode with no
      // GPS origin has no 1:1 multiplier, so a manual zoom must
      // never be seeded from 1.0. Pre-fix, the sequence below jumped
      // the view from ~3x back to ~1.1x.
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TrackingScreen(state: state))),
      );
      await tester.pump();
      // Go live the way the app does — no GPS origin in the test,
      // so the map has no tiles and 1:1 has nothing to scale.
      state.applySettings(AppSettings(simulatedMode: false));
      await tester.pump();
      expect(state.displayOrigin, isNull);
      // Turn the preference OFF first (the button reads FIT with no
      // origin): the operator zooms manually with 1:1 off.
      await tester.tap(find.text('FIT'));
      await tester.pump();
      expect(state.tileOneToOne, isFalse);
      // Manual zoom to ~3x with the + button (1.25^5 ≈ 3.05).
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.text('+'));
        await tester.pump();
      }
      final before = _mapScale(tester);
      // Toggle 1:1 on: the button still reads FIT (no origin), the
      // map stays on the fit view — and the manual zoom survives.
      await tester.tap(find.text('FIT'));
      await tester.pump();
      expect(state.tileOneToOne, isTrue);
      expect(_mapScale(tester), closeTo(before, 0.001));
      // One more +: bumps from ~3x, not from 1.0.
      await tester.tap(find.text('+'));
      await tester.pump();
      expect(_mapScale(tester), closeTo(before * 1.25, before * 0.01));
    });

    testWidgets('follow centers on the operator at the native scale',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TrackingScreen(state: state))),
      );
      await tester.pump();
      state.setLiveGpsFollow(true);
      await tester.pump();
      expect(state.liveGpsFollow, isTrue);
      final layer =
          tester.widget<TilePackMapLayer>(find.byType(TilePackMapLayer));
      final op = state.mapOperatorMeters!;
      // Follow moves the CENTER, not the zoom: the operator sits at
      // the middle of the map, still at the native scale.
      final screen = layer.transform.toScreen(op.x, op.y);
      expect(screen.dx, closeTo(layer.size.width / 2, 1.0));
      expect(screen.dy, closeTo(layer.size.height / 2, 1.0));
      expect(
        layer.transform.scale,
        closeTo(_nativeScaleFor(state, layer.size), 0.001),
      );
    });
  });
}

/// The field points the maps fit: every node + the defended point
/// + the live track, if any — the same extent the screens fit.
List<math.Point<double>> _fieldPointsFor(AppState state) {
  final pts = <math.Point<double>>[
    for (final n in state.effectiveNodes.values)
      math.Point(n.x, n.y),
    math.Point(state.defended.x, state.defended.y),
  ];
  final track = state.track;
  if (track != null) pts.add(math.Point(track.x, track.y));
  return pts;
}

/// The fit view scale (screen px per meter) for [state]'s field at
/// [size], at zoom 1.0.
double _fitScaleFor(AppState state, Size size) =>
    FieldMapTransform.fit(size, _fieldPointsFor(state), zoom: 1.0).scale;

/// The tile-native scale the maps should render at by default for
/// [state]'s current view: resolves the tile zoom the way the
/// screens do and converts it to px/m.
double _nativeScaleFor(AppState state, Size size) {
  final origin = state.displayOrigin!;
  final tileZoom = bestZoomForView(
    viewMetersPerPixel: 1 / _fitScaleFor(state, size),
    latitude: origin.lat,
    minZoom: 0,
    maxZoom: kWebTileMaxZoom,
  );
  return tileNativeScalePxPerMeter(tileZoom, origin.lat);
}

/// The field map's current view scale, read off the painter — the
/// TilePackMapLayer is absent when there is no origin, so the
/// painter is the scale's witness in every mode.
double _mapScale(WidgetTester tester) {
  final finder = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is TrackingMapPainter);
  final painter =
      tester.widget<CustomPaint>(finder).painter as TrackingMapPainter;
  return painter.transform.scale;
}

/// A solid-color test image (no asset decode needed).
Future<ui.Image> _solidImage(Color color, int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = color,
  );
  return recorder.endRecording().toImage(w, h);
}

/// Paints [painter] onto a transparent canvas and returns raw RGBA
/// bytes, row-major, [size.width] pixels per row.
Future<Uint8List> _paintPixels(
    TileBackgroundPainter painter, Size size) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  final image = await recorder
      .endRecording()
      .toImage(size.width.toInt(), size.height.toInt());
  final bytes =
      await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final out = bytes!.buffer.asUint8List();
  image.dispose();
  return out;
}

/// [r, g, b, a] of the pixel at ([x], [y]) in RGBA bytes of width
/// [w] pixels per row.
List<int> _pixel(Uint8List rgba, int w, int x, int y) {
  final o = (y * w + x) * 4;
  return [rgba[o], rgba[o + 1], rgba[o + 2], rgba[o + 3]];
}

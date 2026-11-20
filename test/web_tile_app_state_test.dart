/// v0.29.3 reviewer fix: the AppState boot/sync wiring — the web
/// tile loader must follow the persisted tile source from boot
/// (USGS only, otherwise USGS Topo) and after every settings save.
/// The loader-level gate is unit-tested in web_tile_loader_test;
/// this proves the wiring that calls it (syncWebTileSource after
/// the persisted settings load, and after applySettings).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:outride/state/app_state.dart';

void main() {
  group('AppState web tile source wiring', () {
    testWidgets('boot with persisted OSM resolves the web loader to Topo',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'rf_sentry_zmeta_v1': jsonEncode({
          'tileSourceId': 'osm_standard',
          // A second persisted value, proving the boot load ran:
          // the loader default is Topo too, so the source alone
          // could not prove the load happened.
          'zmetaHost': '10.99.1.99',
        }),
      });
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();

      expect(state.settings.zmetaHost, '10.99.1.99',
          reason: 'the persisted settings must have loaded at boot');
      expect(state.webTiles.source.id, 'usgs_topo',
          reason: 'OSM must never reach the web loader');
    });

    testWidgets('boot with persisted Imagery keeps Imagery',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'rf_sentry_zmeta_v1': jsonEncode({
          'tileSourceId': 'usgs_imagery',
          'zmetaHost': '10.99.1.99',
        }),
      });
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();

      expect(state.settings.zmetaHost, '10.99.1.99',
          reason: 'the persisted settings must have loaded at boot');
      expect(state.webTiles.source.id, 'usgs_imagery');
    });

    testWidgets('a settings save switches the web loader source',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();
      expect(state.webTiles.source.id, 'usgs_topo');

      state.applySettings(AppSettings(tileSourceId: 'usgs_imagery'));
      expect(state.webTiles.source.id, 'usgs_imagery');

      state.applySettings(AppSettings(tileSourceId: 'osm_standard'));
      expect(state.webTiles.source.id, 'usgs_topo',
          reason: 'a save back to OSM resolves to Topo again');
    });
  });
}

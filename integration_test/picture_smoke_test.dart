/// Patrol smoke test (v0.30.0, stream G) — ONE test only.
///
/// Launches the real app and taps through the Picture view, asserting
/// the app launches and the Picture tab renders, on the app's
/// simulated data path: no live radios, hardware, or network needed.
///
/// UNVERIFIED: Patrol tests need `patrol_cli` + a device/emulator to
/// run, and there is no device/emulator in this sandbox, so this test
/// has never been executed on-device. It is checked here only by
/// `flutter analyze` (it must compile cleanly).
///
/// Run on a device/emulator with:
///   patrol test integration_test/picture_smoke_test.dart
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/main.dart';
import 'package:patrol/patrol.dart';

void main() {
  patrolTest(
    'smoke: app launches and the Picture tab renders',
    ($) async {
      // The app opens on the Picture tab (tab 0) by default.
      await $.pumpWidgetAndSettle(const OutrideApp());

      // Tap through the Picture view: the bottom-nav Picture
      // destination. (The app already opens there; the tap exercises
      // the tab path itself.)
      await $('Picture').tap();

      // Picture watch view, idle state: the status banner + the live
      // GPS map card. PAUSED is the fresh-launch verdict (polling
      // starts only on START), and all three strings are
      // mode-independent — they render in SIM and LIVE alike, with
      // no radios attached.
      //
      // Deliberately NOT asserted: START / the fleet chip / the
      // radios row — they sit below the fold in the Picture ListView
      // on a phone viewport, so `.visible` would be false until
      // scrolled to.
      expect($('PERIMETER STATUS').visible, isTrue);
      expect($('PAUSED').visible, isTrue);
      expect($('LIVE GPS MAP').visible, isTrue);
    },
  );
}

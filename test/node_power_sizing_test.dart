import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/node_power_sizing.dart';

void main() {
  group('Ospina-Rojas paper anchors', () {
    final paper = NodePowerBudget.ospinaRojasPaper();

    test('low-irradiance PV after 90% charging efficiency', () {
      // 15.46 Wh/day measured -> 13.92 Wh/day usable.
      expect(paper.pvUsableWhPerDay, closeTo(13.92, 0.01));
    });

    test('safety factor 1.40 on the measured low-irradiance day', () {
      // 13.92 / 9.92 = 1.403.
      expect(paper.safetyFactor, closeTo(1.40, 0.01));
      expect(paper.meetsSafetyFactor, isTrue);
    });

    test('no-sun autonomy 1.73 days at 80% usable capacity', () {
      // 5.8 Ah x 3.7 V x 0.8 = 17.17 Wh usable; 17.17 / 9.92 = 1.73.
      expect(paper.batteryUsableWh, closeTo(17.17, 0.01));
      expect(paper.noSunAutonomyDays, closeTo(1.73, 0.01));
    });

    test('sleep floor 54 mA @ 5 V = 6.48 Wh/day', () {
      expect(paper.sleepFloorWhPerDay, closeTo(6.48, 0.01));
    });

    test('manager quiescent 8 mA = 192 mAh/day', () {
      expect(paper.managerQuiescentMahPerDay, closeTo(192.0, 0.01));
    });

    test('per-uplink radio energy 0.02074 mAh', () {
      // 400 uplinks/day x 0.02074 = 8.30 mAh/day by the per-uplink
      // figure. NOTE: the paper states a radio total of 8.98
      // mAh/day, which does NOT equal 400 x 0.02074 — the paper's
      // total is carried as stated, not derived; the per-uplink
      // figure is the anchored number.
      expect(paper.radioMahPerDay, closeTo(8.30, 0.01));
      expect(paper.perUplinkMah, closeTo(0.02074, 0.00001));
    });

    test('5 V-rail warning fires on the paper configuration', () {
      // Sleep floor 6.48 Wh/day is 65% of the 9.92 Wh/day demand.
      expect(paper.fiveVRailWarning, isTrue);
    });

    test('verdict is MARGINAL: SF passes, autonomy under 2 days', () {
      expect(paper.verdict, startsWith('MARGINAL'));
    });
  });

  group('verdicts', () {
    test('FAIL when the safety factor misses 1.40', () {
      const low = NodePowerBudget(
        panelWatts: 10,
        batteryMah: 5800,
        demandWhPerDay: 20.0,
        pvWhPerDayLowIrradiance: 15.46,
      );
      expect(low.safetyFactor, closeTo(0.70, 0.01));
      expect(low.meetsSafetyFactor, isFalse);
      expect(low.verdict, startsWith('FAIL'));
    });

    test('PASS with a bigger battery and adequate sun', () {
      const good = NodePowerBudget(
        panelWatts: 20,
        batteryMah: 12000,
        demandWhPerDay: 9.92,
        pvWhPerDayLowIrradiance: 20.0,
      );
      expect(good.safetyFactor, closeTo(1.81, 0.01));
      expect(good.noSunAutonomyDays, greaterThan(2.0));
      expect(good.verdict, startsWith('PASS'));
    });

    test('cutting the 5 V rail clears the warning', () {
      // Same demand on the 3.3 V rail at a bare-module sleep
      // current: the floor drops below half the demand.
      const bare = NodePowerBudget(
        panelWatts: 10,
        batteryMah: 5800,
        demandWhPerDay: 9.92,
        pvWhPerDayLowIrradiance: 15.46,
        sleepCurrentMa: 10,
        sleepRailV: 3.3,
      );
      expect(bare.sleepFloorWhPerDay, closeTo(0.79, 0.01));
      expect(bare.fiveVRailWarning, isFalse);
    });

    test('report names the safety factor and the verdict', () {
      final r = NodePowerBudget.ospinaRojasPaper().report();
      expect(r, contains('safety factor: 1.40'));
      expect(r, contains('MARGINAL'));
      expect(r, contains('WARNING: 5 V rail'));
    });
  });
}

/// Portable unattended-node power-sizing calculator (Ospina-Rojas
/// et al. recipe).
///
/// EXPERIMENTAL — bench/library code, no app UI. The calculator is a
/// sizing tool for node deployments, not a live service.
///
/// Source (full read, lane 4): Ospina-Rojas, Botero-Valencia,
/// Muñoz-Cataño, Morales-Guerra, Hernández-García, Vargas-Bonilla &
/// Del-Valle-Soto, "Autonomous Solar-Powered Smart Sensing Node,"
/// *Applied System Innovation* 2026, 9(8), 163. Measured, single
/// site, restricted periods (the authors' own limit):
///
/// - Design demand 9.92 Wh/day (incl. 10% margin; 400 uplinks/day
///   max, 13-byte payload).
/// - Measured PV output 15.46 Wh/day on a low-irradiance day
///   (13.92 Wh/day after 90% charging efficiency) -> effective
///   safety factor 1.40; clear-sky model 58.09 Wh/day (SF 5.27).
/// - No-sun autonomy 1.73 days at 80% usable capacity (2.16 days
///   nominal) on a 5,800 mAh Li-ion pack.
/// - Lowest-power state 54 mA @ 5 V (light sleep 122 mA, active
///   182–186 mA) = 6.48 Wh/day floor — a populated dev-kit node never
///   sleeps cheaply.
/// - Power-manager quiescent 192 mAh/day (8 mA) — budget it
///   explicitly.
/// - Per-uplink radio energy 0.02074 mAh (0.5 s TX @ 117.16 mA + 2 s
///   idle + 0.2 s RX window; SF not stated).
///
/// RECIPE (the transferable part — see docs/node_power_sizing_spec.md):
/// size on a MEASURED low-irradiance day (never the clear-sky model),
/// apply charging efficiency BEFORE the safety factor, budget the
/// manager quiescent explicitly, and check no-sun autonomy at the
/// usable capacity. Pass bar for a deployment: safety factor >= 1.40
/// on the measured low-irradiance day.
///
/// Swinging Door Compression for health telemetry is DOCUMENTED as a
/// pattern in the spec note only — it is NOT implemented here.
library;

/// Inputs to the node power budget. All currents in mA, energies in
/// Wh or mAh as named, panel in watts.
class NodePowerBudget {
  const NodePowerBudget({
    required this.panelWatts,
    required this.batteryMah,
    this.batteryNominalV = 3.7,
    this.usableFraction = 0.8,
    required this.demandWhPerDay,
    required this.pvWhPerDayLowIrradiance,
    this.chargingEfficiency = 0.9,
    this.sleepCurrentMa = 54,
    this.sleepRailV = 5.0,
    this.managerQuiescentMa = 8,
    this.perUplinkMah = 0.02074,
    this.uplinksPerDay = 400,
  });

  /// The Ospina-Rojas et al. measured configuration, as the paper
  /// reports it. Use it to anchor tests — never as a deployment
  /// default for a different node.
  factory NodePowerBudget.ospinaRojasPaper() => const NodePowerBudget(
        panelWatts: 10,
        batteryMah: 5800,
        batteryNominalV: 3.7,
        usableFraction: 0.8,
        demandWhPerDay: 9.92,
        pvWhPerDayLowIrradiance: 15.46,
        chargingEfficiency: 0.9,
        sleepCurrentMa: 54,
        sleepRailV: 5.0,
        managerQuiescentMa: 8,
        perUplinkMah: 0.02074,
        uplinksPerDay: 400,
      );

  /// Solar panel rating (W). Informational for the report; the
  /// sizing math runs on the MEASURED low-irradiance-day PV yield,
  /// never on panel watts x assumed sun hours.
  final double panelWatts;

  /// Battery capacity (mAh).
  final double batteryMah;

  /// Battery nominal voltage (V). Li-ion 3.7 V default.
  final double batteryNominalV;

  /// Usable fraction of the pack (0..1). 0.8 = the paper's figure.
  final double usableFraction;

  /// Design demand (Wh/day), including margin.
  final double demandWhPerDay;

  /// MEASURED PV yield (Wh/day) on a low-irradiance day — the
  /// sizing day. Never the clear-sky model.
  final double pvWhPerDayLowIrradiance;

  /// Charging efficiency (0..1). Applied BEFORE the safety factor.
  final double chargingEfficiency;

  /// Lowest-power-state current (mA) — the sleep floor.
  final double sleepCurrentMa;

  /// Voltage of the rail the sleep current is drawn from (V).
  /// 5 V on a populated dev kit; 3.3 V on a bare module.
  final double sleepRailV;

  /// Power-manager quiescent current (mA), budgeted explicitly.
  final double managerQuiescentMa;

  /// Radio energy per uplink (mAh).
  final double perUplinkMah;

  /// Uplinks per day (max).
  final int uplinksPerDay;

  /// PV yield after charging losses (Wh/day).
  double get pvUsableWhPerDay =>
      pvWhPerDayLowIrradiance * chargingEfficiency;

  /// Safety factor on the measured low-irradiance day, after
  /// charging losses. Pass bar: >= 1.40.
  double get safetyFactor => pvUsableWhPerDay / demandWhPerDay;

  /// Usable stored energy (Wh).
  double get batteryUsableWh =>
      batteryMah / 1000 * batteryNominalV * usableFraction;

  /// No-sun autonomy (days) at usable capacity.
  double get noSunAutonomyDays => batteryUsableWh / demandWhPerDay;

  /// Sleep-floor energy (Wh/day) at the sleep rail.
  double get sleepFloorWhPerDay =>
      sleepCurrentMa / 1000 * sleepRailV * 24;

  /// Manager quiescent charge (mAh/day).
  double get managerQuiescentMahPerDay => managerQuiescentMa * 24;

  /// Radio charge (mAh/day) at the configured uplink rate.
  double get radioMahPerDay => perUplinkMah * uplinksPerDay;

  /// Meets the deployment pass bar (SF >= 1.40)?
  bool get meetsSafetyFactor => safetyFactor >= 1.40;

  /// True when the sleep floor alone eats half or more of the daily
  /// demand — the dev-kit trap: a populated dev-kit node must cut
  /// the 5 V rail in sleep, or accept sub-2-day autonomy. (Paper:
  /// 54 mA @ 5 V = 6.48 Wh/day = 65% of the 9.92 Wh/day demand.)
  bool get fiveVRailWarning =>
      sleepFloorWhPerDay >= 0.5 * demandWhPerDay;

  /// One-line verdict.
  String get verdict {
    if (!meetsSafetyFactor) {
      return 'FAIL: safety factor ${safetyFactor.toStringAsFixed(2)} '
          '< 1.40 on the measured low-irradiance day';
    }
    if (noSunAutonomyDays < 2.0) {
      return 'MARGINAL: SF ${safetyFactor.toStringAsFixed(2)} passes, '
          'but no-sun autonomy is only '
          '${noSunAutonomyDays.toStringAsFixed(2)} days';
    }
    return 'PASS: SF ${safetyFactor.toStringAsFixed(2)}, '
        '${noSunAutonomyDays.toStringAsFixed(2)} days no-sun autonomy';
  }

  /// Multi-line sizing report.
  String report() {
    final b = StringBuffer()
      ..writeln('Node power sizing (Ospina-Rojas recipe):')
      ..writeln('  panel: ${panelWatts.toStringAsFixed(0)} W, '
          'battery: ${batteryMah.toStringAsFixed(0)} mAh @ '
          '${batteryNominalV.toStringAsFixed(1)} V, '
          'usable ${(usableFraction * 100).toStringAsFixed(0)}%')
      ..writeln('  demand: ${demandWhPerDay.toStringAsFixed(2)} Wh/day')
      ..writeln('  PV low-irradiance day: '
          '${pvWhPerDayLowIrradiance.toStringAsFixed(2)} Wh/day '
          '-> ${pvUsableWhPerDay.toStringAsFixed(2)} Wh/day after '
          '${(chargingEfficiency * 100).toStringAsFixed(0)}% charging')
      ..writeln(
          '  safety factor: ${safetyFactor.toStringAsFixed(2)} '
          '(pass >= 1.40): ${meetsSafetyFactor ? 'PASS' : 'FAIL'}')
      ..writeln('  no-sun autonomy: '
          '${noSunAutonomyDays.toStringAsFixed(2)} days')
      ..writeln('  sleep floor: ${sleepCurrentMa.toStringAsFixed(0)} mA @ '
          '${sleepRailV.toStringAsFixed(1)} V = '
          '${sleepFloorWhPerDay.toStringAsFixed(2)} Wh/day')
      ..writeln('  manager quiescent: '
          '${managerQuiescentMahPerDay.toStringAsFixed(0)} mAh/day')
      ..writeln('  radio: ${radioMahPerDay.toStringAsFixed(2)} mAh/day '
          '($uplinksPerDay uplinks/day)');
    if (fiveVRailWarning) {
      b.writeln('  WARNING: 5 V rail dominates the budget — cut the '
          '5 V rail in sleep or accept sub-2-day autonomy');
    }
    b.writeln('  verdict: $verdict');
    return b.toString();
  }
}

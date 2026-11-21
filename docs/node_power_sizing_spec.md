# Node Power-Sizing Recipe (Ospina-Rojas et al.)

**Status: EXPERIMENTAL — library + tests + this note only. No app UI.**

Code: `lib/services/node_power_sizing.dart`.
Tests: `test/node_power_sizing_test.dart` (anchored on the paper's measured
numbers).

Source (full read, lane 4): Ospina-Rojas, Botero-Valencia, Muñoz-Cataño,
Morales-Guerra, Hernández-García, Vargas-Bonilla & Del-Valle-Soto,
"Autonomous Solar-Powered Smart Sensing Node," *Applied System Innovation*
2026, 9(8), 163. Single site, restricted periods — the authors' own
limit, carried here: the recipe transfers; the numbers do not.

## The recipe (the transferable part)

1. **Size on a MEASURED low-irradiance day, never the clear-sky model.**
   The paper's clear-sky model said 58.09 Wh/day (safety factor 5.27);
   the measured low-irradiance day said 15.46 Wh/day (safety factor
   1.40). A node sized on the model is sized on a fantasy.
2. **Apply charging efficiency BEFORE the safety factor.** 15.46 Wh/day
   at 90% charging efficiency is 13.92 Wh/day usable. The safety factor
   is usable ÷ demand.
3. **Budget the power-manager quiescent explicitly.** 8 mA quiescent is
   192 mAh/day — a line item, not rounding error.
4. **Check no-sun autonomy at the USABLE capacity** (80% in the paper),
   not the nameplate.
5. **Pass bar for a deployment: safety factor ≥ 1.40** on the measured
   low-irradiance day.

## The paper's measured anchors (do not "fix" them)

- Design demand 9.92 Wh/day (incl. 10% margin; 400 uplinks/day max,
  13-byte payload).
- PV 15.46 Wh/day on the low-irradiance day → 13.92 Wh/day after 90%
  charging → SF 1.40.
- No-sun autonomy 1.73 days at 80% usable (2.16 days nominal) on a
  5,800 mAh Li-ion pack.
- Lowest-power state 54 mA @ 5 V (light sleep 122 mA, active 182–186 mA)
  = 6.48 Wh/day floor.
- Manager quiescent 192 mAh/day (8 mA).
- Per-uplink radio energy 0.02074 mAh (0.5 s TX @ 117.16 mA + 2 s idle +
  0.2 s RX window; SF not stated).

**Discrepancy, recorded not resolved:** the paper states a radio total
of 8.98 mAh/day for 400 uplinks/day, but 400 × 0.02074 = 8.30 mAh/day.
The calculator anchors on the per-uplink figure and flags the
inconsistency in the test; it does not "correct" the paper.

## The 5 V-rail warning

A populated dev-kit node never sleeps cheaply: 54 mA @ 5 V is 6.48 Wh/day
— 65% of the paper's whole 9.92 Wh/day demand — before the node does
anything. The calculator warns when the sleep floor alone eats half or
more of the daily demand. The fix is architectural: **cut the 5 V rail in
sleep, or accept sub-2-day autonomy.** (For comparison: a bare module at
~10 mA on the 3.3 V rail is ~0.79 Wh/day.)

## Swinging Door Compression (pattern only — NOT implemented)

The paper's health telemetry uses Swinging Door Compression (SDC):
transmit only when the signal moves outside a fixed deviation band
(±1 °C for temperature, ±5% RH), plus a periodic heartbeat (every 15 min
or 1 h). That pattern — event-driven reporting with a heartbeat — is the
right shape for Fetch/node health telemetry, and is documented here so
the pattern is on record. It is **not implemented** in this build.

## What this is not

- Not a field deployment plan: the paper is one site, restricted
  periods, and its numbers are anchors, not Outride node specs.
- Not app UI: the calculator is a library for benching/sizing; if a
  node-sizing screen ever lands in the app, it starts from this service.

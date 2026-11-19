# SDR Bridge Driver Spec

**Status:** v1.2 implemented (bridge + in-app driver). **Scope:** receive-only
band-energy sensing for any common SDR. One radio reports energy per band —
not direction, range, or identity.

## Why this exists

The most common wideband receivers in the wild are SDRs people already own:
RTL-SDR dongles, HackRF Ones, ADALM-Plutos, USRPs, Airspys. But an SDR is
not a mesh radio: it produces no link telemetry, so it can't feed the
tripwire directly. This driver bridges that gap by turning each watched
band into a *virtual link* whose "signal" is band energy.

## Architecture

```
┌──────────────┐  libiio/UHD/      ┌──────────────────┐  UDP 127.0.0.1:49161  ┌─────────────┐
│  Your SDR    │  rtlsdr/Soapy ──▶ │  sdr_bridge.py   │ ── JSON datagrams ──▶ │  Outride   │
│  (any below) │   RX ONLY         │  sweep / stare   │   band energy dBFS    │  SdrDriver  │
└──────────────┘  (no TX path)     └──────────────────┘                       └──────┬──────┘
                                                                                  │ LinkSample
                                                                      virtual link│ per band
                                                                                  ▼
                                                      tripwire → alerts → event log → dashboard
                                                                           (fusion excluded:
                                                                            no geometry)
```

Two processes by necessity: Dart can't drive SDR libraries, so the Python
bridge owns the radio and Outride owns the detection.

## Supported SDRs

| Radio | Backend | Library | Range | Notes |
|---|---|---|---|---|
| RTL-SDR (RTL2832U) | `rtlsdr` | pyrtlsdr | ~24 MHz–1.75 GHz | The $30 classic. RX-only hardware — no TX exists. Covers 433/915, not 2.4/5.8 |
| ADALM-Pluto | `pluto` | pyadi-iio | 70 MHz–3.8 GHz | AD9363; 5.8 GHz band auto-skipped |
| Ettus USRP B200/B210 | `uhd` | uhd | 70 MHz–6 GHz | AD9364/AD9361; B210 dual coherent RX is the future DF path |
| HackRF One | `soapy` + `--soapy-driver hackrf` | SoapySDR | 1 MHz–6 GHz | Covers every drone band |
| Airspy R2/Mini | `soapy` + `--soapy-driver airspy` | SoapySDR | 24 MHz–1.8 GHz | Excellent RX performance |
| LimeSDR / SDRplay / bladeRF | `soapy` + `--soapy-driver lime/...` | SoapySDR | varies | Whatever SoapySDR modules are installed |
| (none) | `simulate` | — | — | Scripted synthetic spectrum; verifies the pipeline with no hardware |

`--backend auto` (default) tries pluto → uhd → rtlsdr → any enumerated
SoapySDR device; first working one wins.

## The polarity trick

Outride's tripwire detects *dips*: `dip = baseline − snr`. A spectrum
sensor's signal is the opposite — an emitter *appearing* is an energy
*rise*. Rather than teaching the tripwire about rises, the driver negates:

- Bridge measures band energy in dBFS (negative, e.g. −81 quiet, −52 hot).
- Driver sets `LinkSample.snr = −energyDbfs` (+81 quiet, +52 hot).
- Tripwire computes `dip = 81 − 52 = +29 dB` — a "dip" that is really an
  energy rise, in honest dB.

Everything downstream then works unchanged: rolling-median baselines,
per-band adaptive (MAD) thresholds, baseline hold during events,
confirm-polls, CrossingEvents, size estimates (dB rise ≈ dip depth),
audible/haptic alerts, and the event log. Absolute dBFS is meaningless
across gain settings — only deltas matter, which is why the bridge pins
manual gain and never touches it again.

## Virtual links

- `fromNode`: `sdr:<radio>` (e.g. `sdr:rtlsdr0`, `sdr:soapy-hackrf0`)
- `toNode`: `sdr:band-<label>` (e.g. `sdr:band-2437`)
- `snr`: negated band-median PSD (wideband, stable — the tripwire input)
- `noiseFrom`: negated noise-floor estimate
- `pcns`: negated per-sub-band (8) PEAK PSD — catches narrowband
  emitters (LoRa/RC tones) the median deliberately ignores; spur-sensitive,
  for investigation, not alarming

## What's deliberately excluded

Band-energy virtual links carry no geometry, so `_updateFusedTrack`
filters them out of the position solver, the shadow grid, and the track
stitcher. A hot band must never drag the fused track. Alerts, dashboard
link cards, and the event log all still fire — that path is the whole
point of the driver.

On the tracking map these nodes appear at auto-assigned positions (same
as any undiscovered node); drag them where you like or ignore them.

## Bridge details (`field_kit/sdr_bridge/`)

- **Backends** (above); `--simulate` needs nothing installed but numpy.
- **RX-only by construction.** Pluto is driven through `rx_*` attributes
  only; UHD opens an RX streamer only; SoapySDR sets up an RX stream
  only; the RTL-SDR dongle has no transmitter at all. There is no TX
  code path.
- **Sweep** (default): 433.92 / 915 / 1290 / 2437 / 5780 MHz; bands above
  the radio's ceiling are skipped with a warning. **Stare**
  (`--stare 2437`): parks on one band, gap-free, at the cost of the
  others. Custom lists via `--bands 433.92/1,915/2`.
- **DSP:** 4 MSPS (2.4 MSPS RTL-SDR), 16384-sample captures, Hann-windowed
  FFT, dBFS with full-scale sine = 0 dBFS. First capture after each
  retune is discarded.
- **Protocol:** UDP JSON to 127.0.0.1:49161 — `band` packets per dwell
  plus a `beacon` every 3 s so the driver (and `probe()`) knows the
  bridge is alive. `--print` dumps packets as JSON lines instead of
  sending (sandbox/CI friendly); `--sweeps N` exits after N sweeps.
- **Launcher:** `RUN_SDR_BRIDGE.bat` — venv, deps, run. Double-click.
  SoapySDR users install PothosSDR (Windows) once; RTL-SDR users run
  Zadig once for the WinUSB driver.

## Wideband survey mode (`--wideband`)

Steps the radio across a range (default 24–1766 MHz in 2 MHz steps,
clipped to the radio's ceiling) and ships one `sweep_step` packet per
step on the same UDP 49161 transport. Same PSD, same adaptive floor,
same DC masking as the band chain, so the numbers mean the same thing
in both modes.

```
{"v":1,"kind":"sweep_step","radio":"rtlsdr0","sweep_id":3,
 "step_index":412,"step_count":872,"center_mhz":915.0,
 "span_mhz":1.92,"energy_dbfs":-62.4,"noise_dbfs":-81.0,
 "bins_dbfs":[-80.1,... 32 values, LOW to HIGH ...],
 "peaks":[{"freq_mhz":915.14,"dbfs":-48.3}],"t":1729123456.789}
```

- `bins_dbfs` is max-pooled (never mean-pooled) so a narrow tone is
  never washed out of its bin. `peaks` are local maxima above
  noise + margin (default 10 dB), strongest first, one entry per
  hump (a flat-top hump yields one peak, its last bin; the DC-masked
  bins are never peak candidates). `sweep_id` increments each full
  pass so the app can group steps into passes — and because the
  bridge restarts its `sweep_id` at 0, a step-0 from the same id
  after a 5 s gap with no steps at all also starts a new pass
  (a bridge restart, not a duplicate); a step with index > 0 never
  clears, so a late datagram can only overwrite its own center.
- **Display-only, by construction.** The app stores sweep steps in
  the SdrDriver's sweep store and renders them on the Spectrum tab;
  sweep_step packets never become LinkSamples, so a survey can never
  drive the tripwire, the tracker, or the merger. The existing band
  packets keep their tripwire behavior untouched, and no band packets
  are sent while a survey runs.
- A survey is slow by physics: ~870 steps at ~0.1 s/step is ~1–2 min
  per full V3 pass. Focus ranges (`--wideband-focus 88-108,902-928,1090`)
  revisit faster. A fast hopper can slip between visits.
- Health contract: a wideband-only bridge sends no band packets, so
  `poll()` returns no LinkSamples. `SdrDriver.emptyPollIsError` is
  therefore state-aware: an empty poll is an error only when there
  are neither fresh bands nor a fresh sweep step (within the 15 s
  band window) — a live survey reads healthy, a dead bridge still
  reads as an error.
- `--simulate --wideband` synthesizes scripted peaks (FM band broad
  lift, 2 m / 915 MHz / ADS-B 1090 tones, quiet elsewhere) so the
  pipeline verifies with no hardware. `--replay <file>` replays
  recorded bridge output (e.g. from `--print`) with no radio.
- `--wideband` cannot combine with `--stare` / `--bands` / `--plan` /
  `--pmr`: the bridge exits with a clear message. One dongle, one
  process — a second bridge script would fight the first for the USB
  device, which is why the survey lives in this bridge instead of a
  separate script.

## Honest limits (v1)

1. One radio = energy, not direction. "2.4 GHz got hot" is the whole
   report. Direction needs dual-coherent-RX interferometry (B210 class)
   — planned, not v1.
2. Sweep gaps are real: a frequency hopper can slip between dwells.
   Stare mode closes the gap for one band.
3. dBFS is relative to the gain setting. Change the gain and the
   baselines must re-learn; never compare absolutes across radios.
   (RTL-SDR gain snaps to the nearest valid tuner step and says so.)
4. Sub-band peaks are spur-sensitive by design (peak of 2048 bins).
   The tripwire's confirm-polls and adaptive thresholds are the guard
   rails; treat lone peak hits as leads, not detections.
5. Know your ceiling: an RTL-SDR will never see 2.4 GHz. The bridge
   skips out-of-range bands and tells you — that's physics, not a bug.
6. USB throughput bounds the SDR: RTL-SDR tops at ~2.4 MSPS, Pluto a few
   MSPS — fine for these sweeps, not wideband real-time.

## Setup (user path)

1. On the PC: double-click `RUN_SDR_BRIDGE.bat --simulate` (test), or
   with `--backend rtlsdr` / `--backend soapy --soapy-driver hackrf` /
   `--backend pluto` / `--backend uhd` (hardware).
2. In Outride: Settings → add radio → **SDR** —
   address prefills to `127.0.0.1:49161`.
3. Watch the dashboard: each band appears as a virtual link; scripted
   emitters in `--simulate` fire within ~40 s so the pipeline can be
   verified end to end.

## Future work (not v1)

- B210 dual-RX phase interferometry → true bearings into the LOB ingest
  (converges with the DF node Phase 2 plan).
- Multi-radio energy-gradient bearing (mesh hot-side bearing, per the
  DF node spec) once 3+ spectrum nodes are common.
- TX remains out of scope permanently — Outride stays defensive-only.

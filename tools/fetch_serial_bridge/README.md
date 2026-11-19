# Fetch serial bridge — bench link between the ball and Outride

Reads the Fetch ball's JSON lines from its USB serial port and forwards
the parsed fused events (and GPS heartbeats) as UDP JSON to Outride's
ingestion port (49160), where the Fetch driver picks them up.

**This is the bench bridge: no LoRa yet.** Later the LoRa link carries
the same JSON and this script goes away — no app change needed.

## What it forwards (and only this)

- `{"event":"FUSED", ...}` — fused event, all five tripwires
  (accel / mic / mmWave / BLE / Wi-Fi)
- `{"gps":"status", ...}` — 10 s GPS heartbeat

Everything else the ball prints (stage banners, alive lines, ESP-ROM
boot text, malformed lines) is skipped and counted, never forwarded,
and never crashes the bridge. The packet sent is the parsed event
re-serialized as compact JSON — never a raw line, never anything the
ball didn't say.

## Install

Python 3.8+. For live serial mode only:

```
pip install pyserial
```

`--file` replay mode needs no extra packages (stdlib only).

## Use

```bash
# Windows bench — the ball is on COM8 (check Device Manager):
python tools/fetch_serial_bridge/fetch_serial_bridge.py --port COM8

# Linux bench:
python3 tools/fetch_serial_bridge/fetch_serial_bridge.py --port /dev/ttyUSB0

# Replay a captured serial log (no hardware, no pyserial):
python3 tools/fetch_serial_bridge/fetch_serial_bridge.py --file sample.txt

# See what would be sent without sending anything:
python3 tools/fetch_serial_bridge/fetch_serial_bridge.py --file sample.txt --dry-run
```

Then in Outride: Settings → Radios → add **FETCH (throwable sensor
ball)**, and open the **Fetch** tab. Events appear as the ball trips.

## Safety

- Sends UDP datagrams to **127.0.0.1:49160 by default** (localhost
  only). Pass `--host` only for a Outride instance on the same
  trusted network — never the open internet.
- The bridge only SENDS. It never opens a listening socket and never
  talks back to the ball.
- The ball itself is listen-only (BLE/Wi-Fi tripwires watch device
  addresses, never who owns them); nothing here transmits, jams, or
  deauths.

#!/usr/bin/env python3
"""Fetch serial bridge — bench link between the ball and Outride.

Reads the Fetch ball's JSON lines from its USB serial port and forwards
the parsed fused events (and GPS heartbeats) as UDP JSON to Outride's
ingestion port (49160), where the Fetch driver picks them up. This is
the BENCH bridge: no LoRa yet. Later the LoRa link carries the same
JSON and this script goes away — no app change needed.

What it forwards (and ONLY this):
  {"event":"FUSED", ...}   fused event, all five tripwires
  {"gps":"status", ...}    10 s GPS heartbeat

Everything else the ball prints (stage banners, alive lines, ESP-ROM
boot text, malformed lines) is skipped and counted, never forwarded
and never crashes the bridge. The packet sent is the parsed event
re-serialized as compact JSON — never a raw line, never anything the
ball didn't say.

Listen-only on the Outride side: the bridge only SENDS datagrams to
localhost by default. It never opens a listening socket and never
talks back to the ball.

Usage:
  python3 fetch_serial_bridge.py --port COM8            # Windows bench
  python3 fetch_serial_bridge.py --port /dev/ttyUSB0   # Linux bench
  python3 fetch_serial_bridge.py --file sample.txt --dry-run
  python3 fetch_serial_bridge.py --file sample.txt --host 127.0.0.1

Options:
  --port      serial port (e.g. COM8). Requires pyserial.
  --baud      serial baud, default 115200 (matches the sketch).
  --host      UDP destination, default 127.0.0.1 (localhost only).
  --udp-port  UDP destination port, default 49160 (Outride nodes).
  --file      replay mode: read lines from a file instead of serial.
              No pyserial needed; for bench checks.
  --dry-run   print what would be sent, send nothing.
  --verbose   print every forwarded event (default: summary only).

Requires: Python 3.8+; pyserial only for --port mode
(`pip install pyserial`).
"""

import argparse
import json
import socket
import sys
import time

DEFAULT_BAUD = 115200
DEFAULT_HOST = "127.0.0.1"
DEFAULT_UDP_PORT = 49160


def is_fetch_message(obj):
    """True when a parsed JSON value is a Fetch fused event or a GPS
    heartbeat. Anything else belongs to another consumer (or is a
    stage banner) and is never forwarded."""
    if not isinstance(obj, dict):
        return False
    event = obj.get("event")
    if event is not None:
        return isinstance(event, str) and event.upper() == "FUSED"
    gps = obj.get("gps")
    if gps is not None:
        return isinstance(gps, str) and gps.lower() == "status"
    return False


def _reject_constant(name):
    """json.loads parse_constant: Python accepts non-standard NaN /
    Infinity tokens by default and re-emits them — Dart's jsonDecode
    rejects them, so the datagram would die silently on arrival
    (not even counted malformed). Reject such lines here instead,
    so they land in `skipped`."""
    raise ValueError(f"non-standard JSON constant: {name}")


def handle_line(line, send, stats, verbose):
    """Parse one serial line; forward it when it is a Fetch message.

    Returns True when a packet was (or would be, under --dry-run) sent.
    Never raises: a malformed line is counted and skipped.
    """
    line = line.strip()
    if not line:
        return False
    try:
        obj = json.loads(line, parse_constant=_reject_constant)
    except (ValueError, TypeError):
        stats["skipped"] += 1
        return False
    if not is_fetch_message(obj):
        stats["skipped"] += 1
        return False
    # Re-serialize the PARSED object: the packet is canonical JSON of
    # what the ball said — never a raw line, never added fields.
    packet = json.dumps(obj, separators=(",", ":")).encode("utf-8")
    send(packet)
    stats["forwarded"] += 1
    if verbose:
        trips = [k for k in ("accel_trip", "mic_trip", "mmwave_trip",
                             "ble_trip", "wifi_trip") if obj.get(k) is True]
        print(f"-> {obj.get('event', 'GPS')} trips={trips or ['none']}",
              flush=True)
    return True


def open_serial(port, baud):
    """Open the serial port. Raises a plain RuntimeError with an
    install hint when pyserial is missing."""
    try:
        import serial
    except ImportError:
        raise RuntimeError(
            "pyserial is not installed — run: pip install pyserial\n"
            "Then re-run with --port. (--file mode needs no pyserial.)"
        )
    return serial.Serial(port, baud, timeout=1)


def run_file(path, send, stats, verbose):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            handle_line(line, send, stats, verbose)
    return stats


def run_serial(port, baud, send, stats, verbose):
    ser = open_serial(port, baud)
    print(f"Listening on {port} @ {baud} — Ctrl-C to stop.", flush=True)
    try:
        while True:
            try:
                raw = ser.readline()
            except Exception as exc:  # serial error: report, keep going
                print(f"serial read error: {exc}", file=sys.stderr,
                      flush=True)
                time.sleep(0.5)
                continue
            if not raw:
                continue
            try:
                line = raw.decode("utf-8", errors="replace")
            except Exception:
                stats["skipped"] += 1
                continue
            handle_line(line, send, stats, verbose)
    except KeyboardInterrupt:
        pass
    finally:
        try:
            ser.close()
        except Exception:
            pass
    return stats


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Forward the Fetch ball's serial JSON to Outride "
                    "over UDP 49160 (bench bridge, no LoRa yet).")
    ap.add_argument("--port", help="serial port, e.g. COM8 or /dev/ttyUSB0")
    ap.add_argument("--baud", type=int, default=DEFAULT_BAUD)
    ap.add_argument("--host", default=DEFAULT_HOST,
                    help="UDP destination (default: 127.0.0.1)")
    ap.add_argument("--udp-port", type=int, default=DEFAULT_UDP_PORT)
    ap.add_argument("--file", help="replay mode: read lines from a file")
    ap.add_argument("--dry-run", action="store_true",
                    help="print what would be sent, send nothing")
    ap.add_argument("--verbose", action="store_true",
                    help="print every forwarded event")
    args = ap.parse_args(argv)

    if args.port is None and args.file is None:
        ap.error("give --port (live ball) or --file (replay a log)")
    if args.port is not None and args.file is not None:
        ap.error("give exactly one of --port or --file")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    dest = (args.host, args.udp_port)
    send_errors = {"n": 0}

    def send(packet):
        if args.dry_run:
            print(f"DRY-RUN {packet.decode('utf-8', 'replace')}", flush=True)
            return
        try:
            sock.sendto(packet, dest)
        except OSError as exc:
            # A send failure (e.g. momentary network loss) must not
            # kill the bridge: count it, warn once + every 100th, keep
            # reading. If the destination is permanently unreachable
            # the operator sees the count climb in the summary.
            send_errors["n"] += 1
            if send_errors["n"] == 1 or send_errors["n"] % 100 == 0:
                print(f"send error ({send_errors['n']} so far): {exc}",
                      file=sys.stderr, flush=True)

    stats = {"forwarded": 0, "skipped": 0}
    print(f"Fetch serial bridge -> UDP {args.host}:{args.udp_port} "
          f"(dry-run={args.dry_run})", flush=True)
    try:
        if args.file is not None:
            run_file(args.file, send, stats, args.verbose)
        else:
            run_serial(args.port, args.baud, send, stats, args.verbose)
    except FileNotFoundError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    finally:
        sock.close()
    print(f"Done. forwarded={stats['forwarded']} "
          f"skipped={stats['skipped']} "
          f"send_errors={send_errors['n']}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

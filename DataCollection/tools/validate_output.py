#!/usr/bin/env python3
"""validate_output.py -- cryosoop radiometer acquisition-folder contract checker.

Runs in the CryoSoOp conda env (stdlib only; YAML via yaml_compat, which falls back to a
bundled minimal parser when no PyYAML is installed).

Usage:
    validate_output.py <acquisition_folder> [--rate HZ] [--duration S]

Point <acquisition_folder> at a single per-run folder. cryosoop writes each run into
<root>/<YYYYMMDD>/<HHMMSS>/, so pass that run subfolder (e.g. .../Data/20260706/143005), not the
parent root that contains many runs.

Radiometer contract:
  * capture files come as matched <PREFIX><YYYYMMDDHHmmss>_ch0.dat / _ch1.dat pairs
  * ch0 and ch1 sizes are equal and a whole number of interleaved int16 samples (multiple of 4)
  * PREFIX is one of the known states: UHF__NL_ / UHF__L_ / UHF_
  * when rate+duration are known (config or --rate/--duration), size == round(duration*rate)*4 bytes
  * events.csv, when present, carries the expected header (a MISSING events.csv is only a
    warning -- legacy rx_samples_to_file-era captures predate it and must still validate)
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import yaml_compat  # noqa: E402  (local fallback YAML loader)

# <PREFIX><14-digit stamp>_ch{0,1}.dat  (chunk 0 = the exact name Chan3ProcAll expects).
RADIOMETER_RE = re.compile(r"^(?P<prefix>.+?)(?P<ts>\d{14})_ch(?P<ch>[01])\.dat$")

# Known state prefixes written by the sequence executor.
KNOWN_PREFIXES = {"UHF__NL_", "UHF__L_", "UHF_"}

EVENTS_HEADER = "wall_iso,host_unix_us,device_time_s,event,band_hz,ant_pair,chan,value,detail"


def _load_config(folder: Path):
    """Load config_effective.yaml (preferred) or config.yaml from the folder, or None."""
    for name in ("config_effective.yaml", "config.yaml"):
        cfg_path = folder / name
        if cfg_path.is_file():
            try:
                return yaml_compat.load(str(cfg_path))
            except Exception as exc:  # noqa: BLE001
                print(f"  [warn] could not parse {cfg_path.name}: {exc}")
                return None
    return None


def _radiometer_rate(config):
    """RADIOMETER.rate [Hz] from a parsed config, or None."""
    if not config:
        return None
    try:
        return float(config["RADIOMETER"]["rate"])
    except (KeyError, TypeError, ValueError):
        return None


def _check_events_csv(folder: Path) -> bool:
    ev = folder / "events.csv"
    if not ev.is_file():
        # Legacy season captures (rx_samples_to_file era) predate events.csv -- warn, don't fail.
        print("  WARN events.csv missing (legacy captures predate it; header check skipped)")
        return True
    try:
        with open(ev, "r", encoding="utf-8", errors="replace") as f:
            first = f.readline().rstrip("\r\n")
    except OSError as exc:
        print(f"  FAIL events.csv unreadable ({exc})")
        return False
    if first != EVENTS_HEADER:
        print(f"  FAIL events.csv header mismatch: {first!r}")
        return False
    print("  OK events.csv present with expected header")
    return True


def validate_radiometer(folder: Path, rate=None, duration=None) -> bool:
    print(f"== RADIOMETER contract: {folder} ==")
    ok = True

    config = _load_config(folder)
    if rate is None:
        rate = _radiometer_rate(config)

    dats = sorted(folder.glob("*_ch[01].dat"))
    if not dats:
        print("  FAIL no *_ch0.dat / *_ch1.dat files found")
        return False

    groups: dict = {}
    for f in dats:
        m = RADIOMETER_RE.match(f.name)
        if not m:
            print(f"  FAIL bad radiometer filename: {f.name}")
            ok = False
            continue
        key = (m.group("prefix"), m.group("ts"))
        groups.setdefault(key, {})[m.group("ch")] = f

    print(f"  info {len(groups)} timestamped capture(s); rate={rate}")
    for (prefix, ts), chans in sorted(groups.items()):
        tag = f"{prefix}{ts}"
        if prefix not in KNOWN_PREFIXES:
            print(f"  WARN {tag}: unexpected prefix '{prefix}' "
                  f"(known: {', '.join(sorted(KNOWN_PREFIXES))})")
        if "0" not in chans or "1" not in chans:
            print(f"  FAIL {tag}: missing channel "
                  f"({'ch0' if '0' not in chans else 'ch1'} absent)")
            ok = False
            continue
        s0 = chans["0"].stat().st_size
        s1 = chans["1"].stat().st_size
        if s0 != s1:
            print(f"  FAIL {tag}: ch0={s0} != ch1={s1} bytes")
            ok = False
            continue
        if s0 % 4 != 0:
            print(f"  FAIL {tag}: size {s0} not a multiple of 4 (interleaved int16 I/Q)")
            ok = False
            continue
        nsamp = s0 // 4
        if rate:
            implied = nsamp / rate
            if duration is not None:
                expect = int(round(duration * rate)) * 4
                if s0 != expect:
                    print(f"  FAIL {tag}: size {s0} != duration*rate*4 ({expect})")
                    ok = False
                    continue
                print(f"  OK {tag}: {nsamp} samp/ch, size == duration*rate*4")
            else:
                print(f"  OK {tag}: {nsamp} samp/ch (~{implied:.3f} s at {rate/1e6:.3f} Msps)")
        else:
            print(f"  OK {tag}: {nsamp} samp/ch (rate unknown; size not checked)")

    ok = _check_events_csv(folder) and ok
    print(f"  ---> RADIOMETER {'PASS' if ok else 'FAIL'}")
    return ok


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="cryosoop radiometer output-contract checker")
    ap.add_argument("folder",
                    help="Per-run acquisition folder (<root>/<YYYYMMDD>/<HHMMSS>) to validate")
    ap.add_argument("--rate", type=float, default=None,
                    help="Radiometer sample rate (Hz) for the size check")
    ap.add_argument("--duration", type=float, default=None,
                    help="Radiometer per-file duration (s) for the size check")
    args = ap.parse_args(argv)

    folder = Path(args.folder)
    if not folder.is_dir():
        print(f"ERROR: not a directory: {folder}", file=sys.stderr)
        return 2

    return 0 if validate_radiometer(folder, args.rate, args.duration) else 1


if __name__ == "__main__":
    sys.exit(main())

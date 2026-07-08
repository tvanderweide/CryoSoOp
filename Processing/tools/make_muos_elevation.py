"""
Generate MUOS satellite elevation tables for the Brundage SoOp L2 correction.

For each requested NORAD id, downloads the historical TLE set from
Space-Track (cached locally — re-runs work offline), propagates with
skyfield using the TLE nearest in epoch to each output time, and writes
a CSV of (timestamp UTC, elevation_deg, azimuth_deg, range_km) at fixed
cadence. compute_L2.m / compare_sat_candidates.m interpolate from these.

Default NORAD ids are all five MUOS birds; the antenna pointing analysis
(159 deg magnetic az / 38 deg el) predicts
MUOS-5 (41622), with MUOS-2 (39206) the runner-up — the season-long
candidate comparison settles it.

Prerequisites:
    pip install skyfield spacetrack numpy
    Space-Track credentials in env vars (only needed on first download):
        SPACETRACK_USER / SPACETRACK_PWD
    (Equivalent manual query, paste into the browser after logging in:
     https://www.space-track.org/basicspacedata/query/class/gp_history/
     NORAD_CAT_ID/41622/EPOCH/2025-11-20--2026-05-10/orderby/EPOCH/format/3le
     and save as tle_41622.txt in --out-dir.)

Usage (defaults cover the 2025-26 Brundage season):
    python make_muos_elevation.py
    python make_muos_elevation.py --norad 41622 --cadence-min 1
"""

import argparse
import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
from skyfield.api import load, wgs84

MUOS = {
    38093: "MUOS-1",
    41622: "MUOS-5",
}

# CLI defaults come from ../site_config.json (shared with BrundageSoOp.m so the
# site coordinates and season dates cannot drift apart); the hardcoded fallbacks
# keep the script runnable standalone if the JSON is missing.
_SITE_JSON = Path(__file__).resolve().parent.parent / "site_config.json"
_FALLBACKS = {
    "lat": 44.99908744, "lon": -116.133436, "alt_m": 2247.113,
    "start": "2025-11-10", "end": "2026-06-12",
    "candidate_norads": list(MUOS),
}


def _site_defaults() -> dict:
    """Merge site_config.json over the hardcoded fallbacks."""
    d = dict(_FALLBACKS)
    try:
        cfg = json.loads(_SITE_JSON.read_text())
        d["lat"] = cfg["site"]["lat"]
        d["lon"] = cfg["site"]["lon"]
        d["alt_m"] = cfg["site"]["alt_m"]
        d["start"] = cfg["season"]["start"]
        d["end"] = cfg["season"]["end"]
        d["candidate_norads"] = cfg["season"].get(
            "candidate_norads", d["candidate_norads"])
    except (OSError, KeyError, ValueError) as exc:
        print(f"  note: {_SITE_JSON.name} not used ({exc}); "
              "falling back to built-in Brundage defaults")
    return d


def fetch_tles(norad_id, start, end, cache_path):
    """Download the TLE history from Space-Track unless already cached."""
    if os.path.isfile(cache_path) and os.path.getsize(cache_path) > 0:
        print(f"  using cached TLEs: {cache_path}")
        return
    from spacetrack import SpaceTrackClient  # only needed on cache miss

    user = os.environ.get("SPACETRACK_USER")
    pwd = os.environ.get("SPACETRACK_PWD")
    if not user or not pwd:
        raise ValueError(
            "Space-Track credentials not found (SPACETRACK_USER / "
            "SPACETRACK_PWD) and no cached TLE file at " + cache_path
        )
    st = SpaceTrackClient(identity=user, password=pwd)
    data = st.gp_history(
        norad_cat_id=norad_id,
        epoch=f"{start:%Y-%m-%d}--{end:%Y-%m-%d}",
        orderby="epoch",
        format="3le",
    )
    with open(cache_path, "w") as f:
        f.write(data)
    print(f"  downloaded TLE history -> {cache_path}")


def make_table(norad_id, start, end, cadence_min, site, ts, out_dir):
    cache_path = os.path.join(out_dir, f"tle_{norad_id}.txt")
    fetch_tles(norad_id, start, end, cache_path)

    sats = load.tle_file(cache_path)
    if not sats:
        raise RuntimeError(f"No TLEs parsed from {cache_path}")
    sats.sort(key=lambda s: s.epoch.utc_datetime())
    epochs = np.array([s.epoch.utc_datetime().timestamp() for s in sats])
    print(f"  {len(sats)} TLE epochs, {sats[0].epoch.utc_datetime():%Y-%m-%d}"
          f" .. {sats[-1].epoch.utc_datetime():%Y-%m-%d}")

    # Output time grid (UTC).
    n_steps = int((end - start).total_seconds() // (cadence_min * 60)) + 1
    grid = [start + timedelta(minutes=cadence_min * i) for i in range(n_steps)]
    grid_s = np.array([g.timestamp() for g in grid])

    # Nearest-epoch TLE for each grid time (boundary midpoints between epochs).
    mid = (epochs[:-1] + epochs[1:]) / 2.0
    sat_idx = np.searchsorted(mid, grid_s)

    # Propagate block-wise: all grid times sharing a TLE in one vectorized call.
    el = np.empty(n_steps)
    az = np.empty(n_steps)
    rng = np.empty(n_steps)
    for k in np.unique(sat_idx):
        sel = np.where(sat_idx == k)[0]
        t = ts.from_datetimes([grid[i] for i in sel])
        alt, azim, dist = (sats[k] - site).at(t).altaz()
        el[sel] = alt.degrees
        az[sel] = azim.degrees
        rng[sel] = dist.km

    out_path = os.path.join(out_dir, f"muos_elevation_{norad_id}.csv")
    with open(out_path, "w") as f:
        f.write("timestamp,elevation_deg,azimuth_deg,range_km\n")
        for g, e, a, r in zip(grid, el, az, rng):
            f.write(f"{g:%Y-%m-%d %H:%M:%S},{e:.6f},{a:.6f},{r:.3f}\n")
    print(f"  {MUOS.get(norad_id, '?')} ({norad_id}): el "
          f"{el.min():.2f}..{el.max():.2f} deg, az {np.median(az):.1f} deg "
          f"-> {out_path}")


def main():
    sd = _site_defaults()
    p = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    p.add_argument("--norad", type=int, nargs="+", default=sd["candidate_norads"],
                   help="NORAD catalog ids "
                        "(default: season.candidate_norads from site_config.json)")
    p.add_argument("--start", default=sd["start"])
    p.add_argument("--end", default=sd["end"])
    p.add_argument("--lat", type=float, default=sd["lat"],
                   help="site latitude, deg N (default: site_config.json)")
    p.add_argument("--lon", type=float, default=sd["lon"],
                   help="site longitude, deg E (default: site_config.json)")
    p.add_argument("--alt", type=float, default=sd["alt_m"],
                   help="site altitude, m WGS84 ellipsoidal (antenna; <0.001 deg effect)")
    p.add_argument("--cadence-min", type=float, default=1.0)
    p.add_argument("--out-dir", default=os.getcwd(),
                   help="output/TLE-cache dir (default: current directory; use the "
                        "pipeline's stable-inputs dir, cfg.elev_dir)")
    args = p.parse_args()

    start = datetime.strptime(args.start, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    end = datetime.strptime(args.end, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    site = wgs84.latlon(args.lat, args.lon, elevation_m=args.alt)
    ts = load.timescale()

    for nid in args.norad:
        print(f"[{MUOS.get(nid, 'NORAD')} {nid}]")
        make_table(nid, start, end, args.cadence_min, site, ts, args.out_dir)


if __name__ == "__main__":
    main()

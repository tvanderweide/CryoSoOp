# Brundage SoOp P-band Processing

MATLAB post-processing pipeline and interactive viewer for Brundage P-band
signals-of-opportunity (SoOp) radiometer data: turns raw two-channel I/Q
captures into calibrated, geometry-corrected phase measurements sensitive to
snow depth, plus a season-wide RFI diagnostic and an interactive viewer for
inspection.

## Quick start

Run the entry script in MATLAB:

```matlab
BrundageSoOp
```

It detects its runtime context automatically and behaves accordingly:

| Context | Behavior |
|---|---|
| HPC batch job (SLURM `sbatch`, `matlab -batch`) | Processing only (parfor), no viewer, no display |
| MATLAB GUI on the HPC (remote desktop) | Processing, then the interactive viewer opens |
| MATLAB GUI on a local PC | Interactive viewer; processing toggles exist but default off |

Every stage checks its own existing output and appends only new work, so
re-running `BrundageSoOp` costs nothing beyond whatever is actually new — it
is always safe to re-run.

### Data and output paths

Point `cfg.data_dir` at your raw-capture root and `cfg.out_dir` at the
product directory near the top of `BrundageSoOp.m`; both layouts described
under [Dual-format support](#dual-format-support-legacy-flat-vs-cryosoop-per-run)
are discovered automatically from `cfg.data_dir`.

### Processing toggles

Near the top of `BrundageSoOp.m`, seven toggles gate the pipeline stages
(`run_L1`, `run_calib`, `run_snr`, `run_satid`, `run_L2`, `run_rfi`,
`run_sigma0`). The defaults process on the HPC and leave everything off for
local/interactive use; override them directly in the script for a one-off
local run — for example, setting `run_calib = true` locally against an
external data drive runs a full calibration pass (reads tens of GB; takes
1-2 hours).

### Inspecting an RFI-excised set

The viewer and the downstream stages both operate on whatever `cfg.out_dir`
points at. To inspect an excised product set instead of the base one, point
`cfg.out_dir` at that method's directory (e.g. `...\L1_notch`) and re-run.

## Deploying at a new site

Everything site-, machine-, and season-specific — including the SDR /
correlation constants — lives in **one file:
[`site_config.json`](site_config.json)** (read by `BrundageSoOp.m` and
`tools/make_muos_elevation.py`, so site coordinates and season dates cannot
drift between the two). A pre-seeded starter for the CSSL deployment is
provided as [`site_config_CSSL.json`](site_config_CSSL.json) — fill in the
`null` fields, then rename it to `site_config.json` (keeping the previous
site's copy under another name). Checklist:

1. **Edit `site_config.json`** —
   - `paths.local` / `paths.hpc`: data root, stable-inputs dir, and dated
     output root for each machine you run on (`BrundageSoOp.m` picks the
     block automatically).
   - `site`: name, antenna `lat`/`lon`/`alt_m` (WGS84 ellipsoidal, at the
     antenna phase center), `tower_h_m`, `capture_tz`, and the antenna
     gain/pol fields (`ant_gain_direct_dbi`, `ant_gain_reflected_dbi`,
     `ant_pol_direct`, `ant_pol_reflected` — boresight dBic; see
     `docs/config-reference.md`). Optional pointing provenance:
     `ant_az_mag_deg`, `ant_el_direct_deg`, `ant_tilt_reflected_deg`
     (as-installed boresight; not read by any stage yet).
   - `sdr`: sample rate, center frequency, integration/segment settings,
     `peak_lag`, `lag_half_win`, and `T_load_K` — copy the Brundage block
     unchanged unless the receiver hardware or capture settings differ
     (rationale per field: `docs/config-reference.md`).
   - `season`: `start`/`end` dates, candidate NORAD ids, and the confirmed
     `norad` (see step 4).
   - `weather` (optional): a local TOA5 `.dat` logger file, its temperature
     column names for the viewer overlay, and `wx_tz` — the logger's clock
     zone (Campbell loggers run fixed standard time year-round; Brundage is
     UTC−7, i.e. `"Etc/GMT+7"` — note the POSIX sign convention: `Etc/GMT+7`
     IS UTC−7). When set, weather timestamps are converted into the capture
     timebase so the viewer overlay aligns; when absent, they pass through
     unconverted (the legacy-season behavior).
2. **Capture timezone** — `site.capture_tz` names the timebase of the
   capture filename stamps. cryosoop builds from 2026-07 on stamp **UTC in
   code** (independent of the Pi's OS timezone), so for new deployments set
   `"UTC"` — `compute_L1` refuses to process UTC-marked runs (summary.json
   `wall_clock: "UTC"`) under a local zone. For **legacy pre-UTC data** set
   the IANA zone of the acquisition computer's clock at capture time (e.g.
   `"America/Boise"`; the field is how `compute_L2` /
   `compare_sat_candidates` convert to UTC for the elevation tables, with
   daylight-saving transitions handled automatically). Never mix UTC-era and
   legacy runs under one data root — the field applies to the whole tree.
   Caution: if it is wrong or missing on legacy data, timestamps are treated
   as already-UTC, which silently misaligns every satellite-geometry product
   by the UTC offset.
3. **Elevation tables** — regenerate with `tools/make_muos_elevation.py`
   (its `--lat/--lon/--alt/--start/--end/--norad` defaults come from
   `site_config.json`, so after step 1 no arguments are needed; CLI flags
   still override). Place the CSVs in the stable-inputs dir
   (`paths.*.input_dir`).
4. **Confirm the tracked satellite** — do not assume the same MUOS bird.
   Run the sat-id stage (`run_satid`, i.e. `compare_sat_candidates`) over
   the season's L1 output first, then set `season.norad` to the confirmed
   id before enabling `run_L2`.
5. **SLURM only** — the `#SBATCH` partition/log/mail lines and the `cd`
   path in `run_BrundageSoOp.sh` are HPC-account-specific and must be
   edited in that script (batch directives cannot read a config file).

## Dual-format support (legacy flat vs. cryosoop per-run)

`compute_L1`, `compute_calib`, and `compute_rfi_spectrum` discover raw
captures with a recursive `dir(fullfile(cfg.data_dir, '**', '<pattern>'))`
glob. `'**'` matches zero or more path levels, so the same code path finds
captures in both layouts without a format flag:

- **Legacy flat layout** (an earlier `rx_samples_to_file`-based acquisition,
  one process per capture): all `.dat` files sit directly in `cfg.data_dir`.
- **cryosoop per-run layout** (`DataCollection/`, current acquisition
  program): each run writes `<DATA_ROOT>/<YYYYMMDD>/<HHMMSS>/` with its own
  `.dat` captures, `events.csv`, `RunLog.log`, `config_effective.yaml`, and
  `summary.json`. `cfg.data_dir` should point at `<DATA_ROOT>`; the nested
  run folders are found automatically. Every downstream path is built from
  the actual hit's `.folder` (never assumed relative to `cfg.data_dir`).
  Mixed trees (flat legacy files at the root plus per-run subfolders) are
  handled per capture: subfolder captures group by their exact containing
  folder, root captures by time gaps.

**Session identity (schema v6, 2026-07-17)**: one cryosoop run folder ==
one UHD session, and that identity is persisted. `compute_L1` and
`compute_calib` write a `session_id` column into their CSVs — the
`<YYYYMMDD>/<HHMMSS>` run-folder key, `legacy-flat` (capture at the data
root), or `unknown` (raw file missing / ambiguous mapping; fails closed —
excluded from chain calibration) — and patch existing CSVs in place from a
metadata-only disk scan (no reprocessing; a stage errors rather than
appending to an unmigrated file). `compute_L2`'s chain-phase calibration
joins session-keyed captures to their own session's calib run by exact
identity (elapsed time is diagnostic only), keeps the historical
nearest-run-in-time join for `legacy-flat` rows, and records the
association per row (`chain_session` column). Before appending
incrementally it checks a config/algorithm stamp
(`BrundageSoOp_L2_chaincal_stamp.json`) AND recomputes every existing
row's chain association — any difference (config change, shifted session
mean, newly usable calibration, repaired provenance) forces a full (cheap)
L2 rebuild plus a sigma0 `_stale_*` rename.

A handful of other contract details changed with the cryosoop acquisition
program and are handled transparently by the stages, but are worth knowing
before debugging a mismatch:

- **File-name prefixes**: cryosoop emits only `UHF__NL_`, `UHF__L_`, and
  `UHF_` (signal). The legacy "small" end-of-run sets (`UHF__NLs_`,
  `UHF__Ls_`) do not exist in cryosoop output — the sequence is 4 NL + 4 L +
  15 Signal captures, all within one UHD session (vs. the legacy 2+2+15+2+2
  split across a start/end pair). `compute_calib`'s pairing handles both
  shapes.
- **Exact capture size**: a clean cryosoop capture is exactly
  `round(duration_s * fs) * 4` bytes (160,000,000 B at 2.0 s / 20 MS/s);
  legacy captures were ~156 MB (slightly truncated). `cfg.min_bytes` (the
  144 MB size gate) is unchanged and passes both.
- **Overflow tracking**: cryosoop logs overflow/late-sequence events in each
  run's `events.csv` (see the DataCollection output contract in
  `DataCollection/README.md`) instead of a UHD stdout log.
  `tools/find_overflows.m` is dual-mode (see its header) — point it at a
  `<DATA_ROOT>` directory or a single `events.csv` for events mode, or at a
  legacy acquisition stdout log for log mode; it auto-detects which.
- **Radio parameters are unchanged**: 370 MHz center, 20 MS/s, gain 54,
  `sc16` (interleaved I/Q int16), ch0 = A:A (direct), ch1 = A:B (reflected),
  capture clock `America/Boise` local time for the legacy 2025-26 season
  (cryosoop builds from 2026-07 on stamp UTC — see the timezone checklist
  item above). Nothing in the signal-processing constants (`cfg.fs`,
  `cfg.Ti`, `cfg.peak_lag`, etc.) needs to change between formats.

## Layout

```
Processing/
  BrundageSoOp.m          entry script (run this)
  soop_setup_paths.m      path setup (idempotent; called first by the entry)
  soop_run_pipeline.m     parpool sizing + stage dispatch + per-method downstream loop
  stages/                 one file per processing stage (see below)
  rfi/                    RFI excision: rfi_excise.m, rfi_propose_bands.m
  lib/                    BrundageSoOp_fun.m — shared helper library used by the viewer
  tools/                  find_overflows.m, make_muos_elevation.py — season-input generators
  viewer/                 interactive uifigure viewer, split into 12 modules
  tests/                  MATLAB unit tests (rfi_excise, rfi_propose_bands)
  docs/                   config-reference.md — every cfg field, units, defaults
  run_BrundageSoOp.sh     sbatch wrapper for the HPC batch context
```

## Pipeline stages

Dispatched in order by `soop_run_pipeline`:

1. **compute_L1** cross-correlates two-channel signal captures, producing
   peak lag/amplitude/phase (time- and frequency-domain) per capture.
2. **compute_calib** pairs no-load/load calibration captures and derives
   receiver-chain calibration terms (gains, noise powers, correlation
   coefficients).
3. **compute_rfi_spectrum** — season-wide diagnostic: aggregates PSD,
   spectral occupancy, spectral kurtosis, and inter-channel coherence across
   sample captures, and proposes RFI excision bands. Runs once per dataset —
   Signal, NL (noise+load), and L (load-only) — writing
   `rfi_spectrum{,_NL,_L}.csv`/`.png` and `rfi_bands_proposed{,_NL,_L}.csv`.
   NL/L band-finding is PSD-excess only (no spectral-kurtosis gate). The curated
   band files applied downstream are `rfi_bands.csv` (signal, compute_L1) and
   `rfi_bands_NL.csv` / `rfi_bands_L.csv` (per calibration state, compute_calib);
   a missing calibration band file leaves that state unexcised.
4. **compute_snr** — SNR distribution across the season; a candidate
   detection threshold.
5. **compare_sat_candidates** scores candidate MUOS satellites against the
   observed sky-signal phase to confirm which one the antenna is tracking.
6. **compute_L2** — applies the geometric range correction and receiver-chain
   phase calibration to produce the final corrected phase series.
7. **compute_sigma0** derives apparent normalized bistatic radar cross
   section (sigma0) and coherent power reflectivity (Gamma) via a
   direct-referenced radar equation, from L1 (incl. its channel-power
   columns), L2's corrected phase and elevation angle, compute_calib's gain
   ratio, the elevation table's range, and SNOdar snow depth for the
   snow-corrected footprint variant. Writes `BrundageSoOp_sigma0.csv` per
   RFI-method product dir; requires re-running `compute_L1` on any season
   processed before the channel-power columns existed.

Full detail on inputs, outputs, CSV columns, and per-stage configuration
fields is in each `stages/*.m` file header and in
[`docs/config-reference.md`](docs/config-reference.md).

## RFI excision

Off by default. When enabled (`cfg.rfi_methods`), each method writes a
self-contained product set (`'none'` -> `cfg.out_dir`, `'notch_interp'` ->
a sibling `<out_dir>_notch`); `compute_L1`/`compute_calib` process all
selected methods in one read/FFT pass. Every `cfg` field involved carries a
one-line comment at its assignment in the entry script; the full
explanation (units, provenance, cross-stage consumers, and the hidden
default that applies when a field is left unset) is in
[`docs/config-reference.md`](docs/config-reference.md).

## Viewer

`BrundageSoOp_viewer.m` is an interactive uifigure for inspecting any
product set — cross-correlation, calibration, RFI spectrum, L2 phase,
weather overlay, radar-cal products and forward-model maps (Fresnel
footprint and within-day specular-point track on a geo-registered
satellite basemap — these need only an elevation table, no products), and
on-demand raw-capture views. It is UI-only; all
computation runs through `lib/BrundageSoOp_fun.m`. The viewer itself is
split into 12 files under `viewer/` (shared state object, callbacks,
catalog, data loading, layout, five per-plot-family renderers, and UI
utility helpers).

## Testing

MATLAB unit tests for the RFI excision path live in `tests/`
(`rfi_excise_test.m`, `rfi_propose_bands_test.m`). Run `soop_setup_paths`
first so the `rfi/`, `stages/`, and `lib/` folders are on the path, then from
the `Processing/` folder:

```matlab
soop_setup_paths;
runtests('tests')                          % functiontests suites (rfi_propose_bands_test)
addpath('tests');  ok = rfi_excise_test();  assert(ok)   % function-style phase-safety test
```

`runtests('tests')` runs the `functiontests`-style suites and skips
`rfi_excise_test.m`, which is a plain function (not a `functiontests` file); it
returns a PASS/FAIL logical, so it is called directly (with `tests/` on the
path). All pipeline code is additionally kept `checkcode`-clean.

## Further reading

- [`docs/config-reference.md`](docs/config-reference.md) — every `cfg`
  field, its units, consumers, and hidden defaults
- Each `stages/*.m` and `viewer/*.m` file header documents that module's
  inputs, outputs, and contract

# Config reference

Every field lives on a single `cfg` struct built once in `BrundageSoOp.m` and
passed to `soop_run_pipeline` and, from there, to each stage. This page is the
full explanation for every field that only gets a one-line comment at its
point of assignment in the entry script.

Site-, machine-, and season-specific values (paths, site geometry,
`capture_tz`, weather file, confirmed satellite) are not literals in
`BrundageSoOp.m`: they are read from `Processing/site_config.json` and copied
onto `cfg` — edit the JSON, not the script, when they change (see the README's
"Deploying at a new site"). The values documented below are the shipped
Brundage entries. Science parameters remain assignments in `BrundageSoOp.m`.

## cfg fields

### Paths

| Field | Set to | Consumed by |
|---|---|---|
| `cfg.data_dir` | Raw `.dat` capture folder (HPC: `/bsuscratch/.../Data/`; local: `F:\Data\`, ~95% of season raw data). Discovered recursively (`dir(fullfile(cfg.data_dir, '**', '<pattern>'))`), so this may point at either a legacy flat directory of `.dat` files or a cryosoop `<DATA_ROOT>` containing nested `<YYYYMMDD>/<HHMMSS>/` run folders — see `Processing/README.md#dual-format-support-legacy-flat-vs-cryosoop-per-run` | compute_L1, compute_calib, compute_rfi_spectrum |
| `cfg.input_dir` | STABLE season inputs shared by every dated run — `overflow_timestamps.txt`, `muos_elevation_*.csv`, `rfi_bands.csv` — decoupled from the per-run output dir, so a new dated run only changes `cfg.out_dir` | compute_calib, compute_snr, compare_sat_candidates, compute_L2, compute_rfi_spectrum |
| `cfg.out_dir` (as first set) | The dated run ROOT (e.g. `...\2026-06-24\`) — the one thing to edit per re-run | re-derived below, not read directly |
| `cfg.fig_dir` | `<root>\Figures\` — re-derived from `cfg.out_dir` before the L1-leaf rewrite; viewer "Export PNG" target | viewer |
| `cfg.out_dir` (final, re-derived) | `<root>\L1\` — the L1/base product leaf. `rfi_excise.method_out_dir()` string-suffixes this leaf name, so `'notch_interp'` lands in a sibling `L1_notch\` folder inside the same dated root | every stage |

### Signal-processing constants

| Field | Default | Notes |
|---|---|---|
| `cfg.fs` | `20e6` Hz | sample rate |
| `cfg.Ti` | `0.9` s | coherent integration time per segment |
| `cfg.num_segs` | `2` | segments coherently averaged per file |
| `cfg.peak_lag` | `-0.575` samples | target lag. Sign resolved on the 2026-01-28 example day (180 pairs): -0.575 gives +25% amplitude, +1.4 dB SNR, and lower phase scatter vs +0.575. |
| `cfg.lag_half_win` | `2500` | analysis window half-width (matches the Python `llm`/`uum` window, +/-2500) |
| `cfg.freq_hz` | `370e6` Hz | center frequency; `lambda = c/f = 0.8102 m` for the L2 geometric model |
| `cfg.tower_h_m` | `6.096` m (20 ft) | confirmed 2026-06-12; RS2 survey 2026-06-15 (point 20 ft below antennas) reconfirms |
| `cfg.T_load_K` | `303` K | load temperature, assumed ambient |

### Site geometry (Emlid Reach RS2 survey, 2026-06-15)

| Field | Value | Notes |
|---|---|---|
| `cfg.site_lat` | `44.99908744` deg N | |
| `cfg.site_lon` | `-116.133436` deg E | |
| `cfg.site_alt_m` | `2247.113` m, WGS84 ellipsoidal | antenna phase center = surveyed ground point 2241.017 m + 6.096 m tower; <0.001 deg effect at GEO range |
| `cfg.capture_tz` | `'America/Boise'` (legacy season) / `'UTC'` (UTC-era) | Timebase of the capture filename stamps. Legacy 2025-26 data used the Pi's LOCAL clock (`'America/Boise'`, VERIFIED 2026-06-12 via `timedatectl`; season spans the Mar 8 MST->MDT change, `datetime` TimeZone conversion in compute_L2 / compare_sat_candidates handles both offsets). cryosoop builds from 2026-07 on stamp UTC in code — set `'UTC'` (the conversion becomes an exact identity), and compute_L1 hard-errors if a UTC-marked run (summary.json `wall_clock: "UTC"`) is processed under a local zone. Never mix the two eras under one data root. If absent, timestamps are assumed already UTC |

### Weather overlay (viewer only)

| Field | Value | Notes |
|---|---|---|
| `cfg.wx_dat` | local TOA5 `.dat` file (not distributed with the repo) | weather station 15-min data, viewer L2 + SNOdar plots only |
| `cfg.wx_temp_cols` | `{'AirTC_Avg', 'Temp_C_Avg'}` | temperature columns overlaid on the SNOdar plots (two toggleable lines): `AirTC_Avg` = air temp (the melt-freeze driver); `Temp_C_Avg` = the sensor that `Processing/TemperaturePlot_SnowDepth.py` plots. Order maps to the viewer's `airtc_c`, `temp_c` toggles |
| `cfg.wx_tz` | unset (legacy) / `'Etc/GMT+7'` | optional weather-logger clock zone (`site_config.json` `weather.wx_tz`). Campbell loggers run FIXED standard time year-round (no DST); Brundage's is UTC−7 = `'Etc/GMT+7'` — **POSIX sign convention: `Etc/GMT+7` IS UTC−7**, the sign is inverted. When set, `load_snodar` converts weather timestamps into the capture timebase (`cfg.capture_tz`, else UTC) so the viewer overlay aligns. When unset, timestamps pass through unconverted — the legacy 2025-26 behavior (logger standard time read as capture-local; a known ~1 h overlay offset during DST, accepted rather than retro-corrected). An invalid zone warns (naming the value) and yields an empty weather table |

### Elevation / satellite

| Field | Value | Notes |
|---|---|---|
| `cfg.elev_dir` | `= cfg.input_dir` | compare_sat_candidates scans this dir for `muos_elevation_*.csv` |
| `cfg.elev_table` | `fullfile(cfg.elev_dir, sprintf('muos_elevation_%d.csv', site.season.norad))` | elevation table for the CONFIRMED satellite (`season.norad` in site_config.json, shipped 41622 = MUOS-5), read by compute_L2. Confirm with `compare_sat_candidates(cfg)` first if unconfirmed |
| `cfg.matlab_jobs_dir` | `site.paths.hpc.matlab_jobs` | parpool JobStorageLocation root on the HPC (job-unique subdir per SLURM job) — soop_run_pipeline |
| `cfg.snr_threshold` | `10` dB | used by compare_sat_candidates scoring |

### Overflow

| Field | Value | Notes |
|---|---|---|
| `cfg.overflow_file` | `fullfile(cfg.input_dir, 'overflow_timestamps.txt')` | stable season input (not per-run), produced by `find_overflows.m`. Read by compute_L1, compute_calib, compute_L2, and (as of the 2026-07-06 port) compute_snr, which prefers this field and falls back to a legacy `cfg.out_dir`-relative path only if it is absent |

### Batching / sizing

| Field | Value | Notes |
|---|---|---|
| `cfg.min_bytes` | `cfg.fs * cfg.Ti * cfg.num_segs * 2 * 2` = 144 MB | minimum valid size PER CHANNEL FILE (`UHF_*_ch0.dat` / `_ch1.dat` each hold one channel of interleaved I/Q int16): `num_segs` segments x `Ti` x `fs` samples x 2 (I,Q) x 2 bytes. Healthy 2 s captures are 160 MB |
| `cfg.batch_size` | `200` | pairs per batch between CSV appends. If the session dies mid-run, at most one batch of work is lost; restart skips everything already in the CSVs |
| `cfg.use_gpu` | `false` | CPU parfor is the validated path |

### RFI excision (off by default; bands from compute_rfi_spectrum)

Each method writes a self-contained product set: `'none'` -> `cfg.out_dir` (the
production path, unchanged), `'notch_interp'` -> `<out_dir>_notch`.
compute_L1/compute_calib process all selected methods in a single read/FFT
pass; the downstream stages (snr, sat-id, L2) then run once per method dir
(see `soop_run_pipeline.m`). See `rfi\rfi_excise.m` for the method, citations,
and phase-safety.

| Field | Value | Notes |
|---|---|---|
| `cfg.rfi_methods` | `{'notch_interp'}`, prepended with `'none'` when `update_base = true` (the entry script's local variable, not itself a `cfg` field) | `update_base` also (re)processes the base/`'none'` set in `cfg.out_dir` alongside the excised sets — safe, because the per-method incremental logic adds only genuinely new captures (no duplication). Set `update_base = false` to leave the base frozen |
| `cfg.rfi_bands_file` | `fullfile(cfg.input_dir, 'rfi_bands.csv')` | the curated season band list, exported from the viewer's RFI explorer ("Export bands" -> `rfi_bands_proposed.csv`; rename/copy to `rfi_bands.csv`, both in `cfg.input_dir`/Static). This CSV is the single source of truth — edit it (incl. the ~360/380 MHz edge bands) rather than hardcoding bands in the entry script. Columns: `f_lo_hz, f_hi_hz(, source)`. If missing, a warning is logged and `cfg.rfi_bands = []` (notch becomes a no-op, behaves like `'none'`) |
| `cfg.rfi_bands` | `[B.f_lo_hz, B.f_hi_hz]`, N x 2, RF Hz | loaded from `cfg.rfi_bands_file` |
| `cfg.muos_bands` | N x 2 RF Hz, see below | |
| `cfg.rfi_apply_calib` | `true` | also excise calibration captures, for consistency with signal captures |

**cfg.muos_bands** — the four MUOS WCDMA downlink channels (360-380 MHz, 5 MHz
spacing, centers 362.5/367.5/372.5/377.5 MHz; guard nulls at 365/370/375 MHz —
the four ch0 humps in the raw PSD). compute_L1 evaluates a SECOND
frequency-domain phase over ONLY these bins (`peak_phase_deg_fd_muos`) to
compare against the full-band value. Format: N x 2 `[f_lo_hz f_hi_hz]`, same
convention as `cfg.rfi_bands`. Each row's occupied passband = center +/- 2.3
MHz (~4.6 MHz WCDMA occupied bandwidth, RRC alpha ~= 0.22), kept just inside
each guard null; widen to the full 5 MHz slots if desired.

```
cfg.muos_bands = 1e6 * [ ...
    360.20, 364.80;   % MUOS ch1 (center 362.5)
    365.20, 369.80;   % MUOS ch2 (center 367.5)
    370.20, 374.80;   % MUOS ch3 (center 372.5)
    375.20, 379.80];  % MUOS ch4 (center 377.5)
```

**Band-finder fields** (compute_rfi_spectrum + the viewer's interactive
explorer) — these seed the explorer's controls; tune them live there, then
Export to `rfi_bands.csv`:

**Corrected 2026-07-06**: the "Entry value" column below previously showed
the compute_rfi_spectrum/viewer *fallback* defaults for several fields, not
the values `BrundageSoOp.m` actually assigns (confirmed by a direct read of
`BrundageSoOp.m` lines 115-122). Six of the eight fields below differ from
their stage/viewer fallback, not just the two previously flagged — see
[Divergent defaults](#divergent-defaults-entry-vs-viewer-fallbacks).

| Field | Entry value | Notes |
|---|---|---|
| `cfg.rfi_excess_db` | `3` | flag bins this many dB above the smoothed PSD envelope — **diverges from the stage/viewer fallback of 6; see below** |
| `cfg.rfi_sk_threshold` | `50` | also flag bins with spectral kurtosis >= this (bursty RFI) — **diverges from the stage/viewer fallback of 100; see below** |
| `cfg.rfi_use_sk` | `true` | include the SK gate in the proposed bands |
| `cfg.rfi_env_khz` | `500` | PSD-envelope movmedian width — **diverges from the stage/viewer fallback of 1000; see below** |
| `cfg.rfi_merge_khz` | `15` | merge flagged runs closer than this into one band — **diverges from the stage/viewer fallback of 25; see below** |
| `cfg.rfi_edge_guard_khz` | `0` | drop the outer band edges (FFT-edge artifacts) — **diverges from the stage/viewer fallback of 150; see below** |
| `cfg.rfi_band_pad_khz` | `1` | widen each proposed band for the L1 notch |
| `cfg.rfi_min_width_khz` | `0.1` | drop runs narrower than this — **diverges from the stage/viewer fallback of 0.3; see below** |

## Defaults

Hidden fallbacks, i.e. values used only if the corresponding `cfg` field is
absent/empty. All confirmed directly from `getfield_default`/`getdef` calls
in the stage source (not inferred).

**compute_L2** (`getfield_default`) — **corrected 2026-07-06**: only
`chain_run_gap_min` and `chain_join_tol_min` are actually left to these
fallbacks in production; `chain_phase_ref_deg` IS set explicitly by
`BrundageSoOp.m` (line 65: `cfg.chain_phase_ref_deg = -81.4;`), overriding
its fallback below. The code fallback itself is also negative
(`getfield_default(cfg, 'chain_phase_ref_deg', -81.4)` in
`compute_L2.m`), not `+81.4` as this table previously stated:

| Field | Fallback | Notes |
|---|---|---|
| `chain_run_gap_min` | `20` | not set by the entry script; see [Chain-cal knobs](#chain-cal-knobs) |
| `chain_join_tol_min` | `60` | not set by the entry script; see [Chain-cal knobs](#chain-cal-knobs) |
| `chain_phase_ref_deg` | `-81.4` | **set explicitly by the entry script** (also `-81.4`, matching the fallback) — see [Chain-cal knobs](#chain-cal-knobs) |

**compute_rfi_spectrum** (`getdef`) — the "hidden" set below is never set by
the entry script at all (no corresponding `cfg.*` assignment exists in
`BrundageSoOp.m`):

| Field | Fallback | Notes |
|---|---|---|
| `rfi_seg_len` | `2^16` | ~305 Hz bins at 20 MS/s |
| `rfi_read_samples` | `16*seg_len` | |
| `rfi_max_captures` | `500` | even season subsample |
| `rfi_baseline_khz` | `750` | per-capture occupancy baseline width |
| `rfi_protect_hz` | `50e3` | +/- around DC (LO leak) |

The remaining `compute_rfi_spectrum` `getdef` fallbacks (`rfi_excess_db`,
`rfi_sk_threshold`, `rfi_use_sk`, `rfi_env_khz`, `rfi_merge_khz`,
`rfi_edge_guard_khz`, `rfi_band_pad_khz`, `rfi_min_width_khz`) ARE also set
explicitly by the entry script — see [Divergent defaults](#divergent-defaults-entry-vs-viewer-fallbacks).

The stage header for `compute_rfi_spectrum` used to also mention
`cfg.rfi_occupancy` as the candidate-band threshold, even though no such
field was ever read anywhere in the source (`rfi_propose_bands.m` gates on
`excess_db`/`sk_threshold` instead). **Update, 2026-07-06**: the dead header
line was removed as part of the cryosoop port.

## Divergent defaults (entry vs viewer fallbacks)

**Corrected 2026-07-06**: a fresh re-check (`Processing/BrundageSoOp.m` lines
115-122 vs `stages/compute_rfi_spectrum.m`'s `getdef(...)` calls and
`viewer/soop_viewer_layout.m` + `viewer/soop_viewer_render_rfi.m`'s
`cfgdef(...)` calls) found the entry script diverges from the stage/viewer
fallback for **six** of the eight RFI band-finder fields, not two as
previously documented here — the viewer and stage fallbacks agree with each
other in every field checked, but several previously assumed to match the
entry script's value do not:

| Field | Entry value | Stage/viewer fallback |
|---|---|---|
| `rfi_excess_db` | `3` | `6` |
| `rfi_sk_threshold` | `50` | `100` |
| `rfi_env_khz` | `500` | `1000` |
| `rfi_merge_khz` | `15` | `25` |
| `rfi_edge_guard_khz` | `0` | `150` |
| `rfi_min_width_khz` | `0.1` | `0.3` |

Only two band-finder fields actually match their stage/viewer fallback:
`rfi_use_sk` (`true` both) and `rfi_band_pad_khz` (`1` both). Because the
entry always sets all eight fields explicitly, production runs always use
the entry-value column above in its entirety; the fallback column only
takes effect if a caller builds `cfg` without copying these fields from the
entry (e.g. a bare `compute_rfi_spectrum(cfg)` call in a script or test that
starts from an empty struct, or the viewer opened against a `cfg` that never
went through `BrundageSoOp.m`).

## Chain-cal knobs

From compute_L2.m's chain-phase calibration block (schema 2026-07-04),
relocated here verbatim:

> Chain-cal knobs, all overridable from cfg (kept together here):
>   `chain_run_gap_min`  — calib rows further apart than this start a new run
>   `chain_join_tol_min` — max |capture time - calib run time| to accept
>   `chain_phase_ref_deg`— FIXED reference subtracted so the correction is
>                          ~zero-mean; keep constant across reprocessing so
>                          incremental appends stay consistent (81.4 = season
>                          circular mean of the notch chain series, 2026-07-04).

**Corrected 2026-07-06**: `chain_run_gap_min` and `chain_join_tol_min` are
not set by the entry script, so those two use the fallbacks above (20 / 60).
`chain_phase_ref_deg` IS set explicitly by the entry script
(`BrundageSoOp.m` line 65: `cfg.chain_phase_ref_deg = -81.4;`) — the value in
production is `-81.4`, matching the (also `-81.4`) code fallback, not the
positive `81.4` this page previously showed. The magnitude, 81.4 deg, is
still the same season-specific circular-mean constant computed 2026-07-04;
only the documented sign was wrong. It should still be treated as a
season-specific constant, not a universal one — if the receiver chain phase
steps (UHD/firmware/hardware change), this value needs re-deriving from a
fresh circular mean of the notch chain series.

**Sign convention, updated 2026-07-06 (schema v5 conjugation unification)**:
as of the cryosoop-port adaptation, `compute_calib` correlates `D.*conj(R)`
(the same convention `compute_L1` already used),
so `compute_L2`'s chain term now **SUBTRACTS** from the signal phase (it
previously ADDED, back when `compute_calib` correlated the opposite order,
`R.*conj(D)`). The reference constant's sign flipped to match (`-81.4`, was
`+81.4`). This is a scientific/sign-convention change and must
be re-checked (not assumed) if the receiver chain phase or the calib
conjugation convention changes again.

# Config reference

Every field lives on a single `cfg` struct built once in `BrundageSoOp.m` and
passed to `soop_run_pipeline` and, from there, to each stage. This page is the
full explanation for every field that only gets a one-line comment at its
point of assignment in the entry script.

Site-, machine-, and season-specific values (paths, site geometry, antenna
gains/pols, `capture_tz`, weather file, confirmed satellite) and the SDR /
correlation constants (`sdr` block) are not literals in `BrundageSoOp.m`:
they are read from `Processing/site_config.json` and copied onto `cfg` — edit
the JSON, not the script, when they change (see the README's "Deploying at a
new site"). The values documented below are the shipped Brundage entries.
The remaining science parameters (RFI tuning, sigma0 estimator knobs,
chain-phase reference, thresholds) stay as assignments in `BrundageSoOp.m`.

## cfg fields

### Paths

| Field | Set to | Consumed by |
|---|---|---|
| `cfg.data_dir` | Raw `.dat` capture folder (HPC: `/bsuscratch/.../Data/`; local: `F:\Data\`, ~95% of season raw data). Discovered recursively (`dir(fullfile(cfg.data_dir, '**', '<pattern>'))`), so this may point at either a legacy flat directory of `.dat` files or a cryosoop `<DATA_ROOT>` containing nested `<YYYYMMDD>/<HHMMSS>/` run folders — see `Processing/README.md#dual-format-support-legacy-flat-vs-cryosoop-per-run` | compute_L1, compute_calib, compute_rfi_spectrum |
| `cfg.input_dir` | STABLE season inputs shared by every dated run — `overflow_timestamps.txt`, `muos_elevation_*.csv`, the curated band CSVs `rfi_bands.csv` / `rfi_bands_NL.csv` / `rfi_bands_L.csv`, and the season RFI products `rfi_spectrum{,_NL,_L}.csv` / `.png` + `rfi_bands_proposed{,_NL,_L}.csv` — decoupled from the per-run output dir, so a new dated run only changes `cfg.out_dir` | compute_calib, compute_snr, compare_sat_candidates, compute_L2, compute_rfi_spectrum |
| `cfg.out_dir` (as first set) | The dated run ROOT (e.g. `...\2026-06-24\`) — the one thing to edit per re-run | re-derived below, not read directly |
| `cfg.fig_dir` | `<root>\Figures\` — re-derived from `cfg.out_dir` before the L1-leaf rewrite; viewer "Export PNG" target | viewer |
| `cfg.out_dir` (final, re-derived) | `<root>\L1\` — the L1/base product leaf. `rfi_excise.method_out_dir()` string-suffixes this leaf name, so `'notch_interp'` lands in a sibling `L1_notch\` folder inside the same dated root | every stage |

### Signal-processing constants

Values live in `site_config.json`'s `sdr` block (per-deployment instance);
`BrundageSoOp.m` maps them onto the `cfg` fields below. The "Default" column
shows the Brundage settings.

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

### Radar-equation calibration (compute_sigma0)

`compute_sigma0` derives apparent normalized bistatic radar cross section
(sigma0, incoherent — from the variance of the calibrated direct/reflected
cross-correlation over a sliding window) and coherent power reflectivity
(Gamma), via a direct-referenced radar equation: EIRP cancels by referencing
to the measured direct-channel power, standard practice for MUOS signals of
opportunity, since MUOS EIRP is not published as a measured value and the
signal is power-controlled (Shah et al. 2017, IEEE Geoscience and Remote
Sensing Letters 14(3)). Inputs: L1 (incl. the `pow_ch0_fd` / `pow_ch0_fd_muos`
/ `pow_ch1_fd` / `pow_ch1_fd_muos` channel-power columns), L2 (detrended
phase + `theta_deg`), compute_calib's gain ratio (`G_De`/`G_Re`,
nearest-within-tolerance join), the elevation table's `range_km` column, and
SNOdar snow depth for the snow-corrected footprint variant. Output:
`BrundageSoOp_sigma0.csv`, written per RFI-method product dir like every
other stage.

Footprint: first-Fresnel-zone ellipse (Larson & Nievinski 2013, GPS
Solutions 17(1), appendix): `d = lambda/2; b = sqrt(2*d*h/sin(e) +
(d/sin(e))^2); a = b/sin(e); A_eff = pi*a*b`, computed twice per capture —
once with `cfg.tower_h_m` and once with the SNOdar-corrected height — for
the fixed-height and snow-corrected footprint variants. The viewer also
draws two forward-model map views from the same geometry (no sigma0 CSV
needed): the footprint ellipse at a selected date, and the within-day
specular-point track `x_sp = h/tan(e)` (`lib/soop_specular_track.m` — note
the specular point sits inside the ellipse-center offset `R`).

Antenna gain/pol fields are deployment hardware, REQUIRED in
`site_config.json`'s `site.*` block (see the README's "Deploying at a new
site"). The `sigma0_*` fields are science parameters that stay in
`BrundageSoOp.m`.

| Field | Default | Notes |
|---|---|---|
| `cfg.ant_gain_direct_dbi` | `site.ant_gain_direct_dbi` (Brundage: `4.1` dBic) | Direct-channel antenna gain toward the satellite, REQUIRED in `site_config.json`. Brundage carries the measured value **4.1 dBic** for the deployed OSU compact P-band dual-CP patch (Shen & Chen, *P-Band Signals of Opportunity Antenna Fabrication and Testing*, OSU ElectroScience Laboratory report AWD106817-Final, July 2022: measured boresight realized gain ~4.1 dBic on both CP ports, ~90° 3-dB beamwidth, >20 dB cross-pol isolation, axial ratio < 1.25 over 360–380 MHz). This is a BORESIGHT gain — the stage assumes the antenna is boresighted on the satellite |
| `cfg.ant_gain_reflected_dbi` | `site.ant_gain_reflected_dbi` (Brundage: `4.1` dBic) | Reflected-channel antenna gain toward the specular point — same OSU patch, LHCP port, measured **4.1 dBic** boresight (in `site_config.json`). Boresight assumption: if the downlooking antenna is not aimed at the specular point, the ~90° beam rolls the effective gain off (≈ −3 dB at 45° off boresight) |
| `cfg.ant_pol_direct` | `site.ant_pol_direct` (Brundage: `'RHCP'`) | Direct-channel antenna polarization — provenance only (RHCP = MUOS co-pol); no polarization-mismatch factor is applied to the products |
| `cfg.ant_pol_reflected` | `site.ant_pol_reflected` (Brundage: `'LHCP'`) | Reflected-channel antenna polarization — provenance only (LHCP matches the reflection handedness flip); no mismatch factor applied |
| `site.ant_az_mag_deg` | Brundage: `159` | As-installed boresight azimuth of the antenna mount, **magnetic** degrees (both antennas share the mount azimuth). Recorded for provenance / a future off-boresight gain correction — **not read by any stage yet**. Brundage value is the installation guidance figure; a precise survey is pending |
| `site.ant_el_direct_deg` | Brundage: `38` | Uplooking (direct) antenna boresight elevation above the horizon, deg. Provenance only, not read by any stage yet; approximate as-installed value |
| `site.ant_tilt_reflected_deg` | Brundage: `38` | Downlooking (reflected) antenna boresight depression below the horizon, deg (specular symmetry with the direct elevation → ~76° between groundplanes). Provenance only, not read by any stage yet; approximate as-installed value |
| `cfg.sigma0_win_hours` | `24` h | Centered sliding-window width for the incoherent-sigma0 window statistics |
| `cfg.sigma0_min_count` | `5` | Minimum valid captures required in a window; below this the window's products are left NaN (the row is still written) |
| `cfg.sigma0_min_elev_deg` | `5` deg | Elevation gate — below this the flat-horizontal-reflector footprint assumption breaks down near grazing, so the capture is excluded |
| `cfg.sigma0_min_dsnr_db` | `10` dB | Direct-channel SNR gate protecting the ratio estimator |
| `cfg.sigma0_cal_max_age_hr` | `1` h | Nearest-within-tolerance join window to the calib gain ratio (`G_De`/`G_Re`); matches compute_L2's chain-cal join tolerance |
| `cfg.sigma0_corr_family` | `'fd_muos'` | Which L1 amplitude / L2 phase family feeds the correlation: `'fd_muos'` (default, MUOS sub-channels), `'fd'` (full-band frequency-domain), or `'td'` (time-domain) |

**Limitations**: both gain fields are scalar, boresight-style values — there
is no directional antenna pattern support (a documented limitation, not a
bug); with the deployed patches' ~90° beamwidth, mispointing from the
satellite / specular directions rolls the true gain off by up to a few dB.
The Fresnel footprint assumes a flat, HORIZONTAL reflector: local terrain
slope at the specular point shifts both the specular geometry and A_eff
(≈ −4.5 %/deg of effective-elevation change at 38°), and for dry snow the
dominant P-band reflector can be the snow–ground interface rather than the
snow surface (the fixed-h and snow-h variants bracket the two cases). The
first-Fresnel-zone A_eff is the coherent footprint; diffuse (incoherent)
scatter is antenna-beam-weighted and can extend well beyond it, so the
absolute sigma0 scale carries that area-model choice. The products are
*apparent* (noise-contaminated) sigma0/Gamma with
competing, unsigned biases: receiver noise is not subtracted in this release,
which pulls both products low, while residual estimator noise inflates the
sigma0 variance high — so neither product is a one-sided bound on the true
value (Gamma, having no variance term, is predominantly biased low). The
`dsnr_db` and `c_var_noise_est` columns in the output CSV are per-row
diagnostics of the two effects rather than corrections.

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
| `cfg.rfi_bands` | `[B.f_lo_hz, B.f_hi_hz]`, N x 2, RF Hz | loaded from `cfg.rfi_bands_file`; the **Signal** band list — applied to signal captures (compute_L1) |
| `cfg.rfi_bands_nl` | `[B.f_lo_hz, B.f_hi_hz]`, N x 2, RF Hz | loaded from `rfi_bands_NL.csv` in `cfg.input_dir`; applied to **NL** (noise+load) calibration captures (compute_calib). **Missing file -> `zeros(0,2)`: NL calibration runs UNEXCISED** (empty band list is a pass-through), not a fall-back to the signal bands. Same columns as `rfi_bands.csv` |
| `cfg.rfi_bands_l` | `[B.f_lo_hz, B.f_hi_hz]`, N x 2, RF Hz | loaded from `rfi_bands_L.csv` in `cfg.input_dir`; applied to **L** (load-only) calibration captures (compute_calib). Missing file -> `zeros(0,2)`: L calibration runs UNEXCISED. Same columns as `rfi_bands.csv` |
| `cfg.muos_bands` | N x 2 RF Hz, see below | |
| `cfg.rfi_apply_calib` | `true` | also excise calibration captures. With per-state band files, NL uses `cfg.rfi_bands_nl` and L uses `cfg.rfi_bands_l` (each independent of the signal `cfg.rfi_bands`) |

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
Export to the per-dataset proposed CSV and curate into the matching band file
(`rfi_bands.csv` for Signal, `rfi_bands_NL.csv` / `rfi_bands_L.csv` for the
calibration states).

**Per-dataset RFI (Signal / NL / L).** `compute_rfi_spectrum` aggregates three
datasets — signal captures, NL (noise+load) and L (load-only) calibration
captures — into `rfi_spectrum{,_NL,_L}.csv` + `.png` and
`rfi_bands_proposed{,_NL,_L}.csv` (all in `cfg.input_dir`). The viewer's two
season-RFI views carry an **RFI set** selector (Signal/NL/L) that switches which
spectrum/bands are shown. **NL and L band-finding uses the PSD-excess gate only
— the SK gate (`cfg.rfi_sk_threshold`, `cfg.rfi_use_sk`) is forced off for those
sets** (SK is still computed, written to the CSV, and plotted as a diagnostic);
only the Signal set uses SK. The curated band files are independent per state,
so a band that applies to more than one dataset is duplicated across files.

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
| `cfg.rfi_env_khz` | `500` | **The single PSD-envelope movmedian width.** Drives the season-aggregate envelope, the band-finder gate (`rfi_propose_bands`), the per-capture occupancy baseline (formerly `rfi_baseline_khz`), and the viewer's single-capture `Raw: PSD` + `Raw: FFT Amplitude` display envelopes. All go through the shared helper `rfi/rfi_env_window.m` (kHz -> odd movmedian window in bins). **Diverges from the stage/viewer fallback of 1000; see below** |
| `cfg.rfi_merge_khz` | `15` | merge flagged runs closer than this into one band — **diverges from the stage/viewer fallback of 25; see below** |
| `cfg.rfi_edge_guard_khz` | `0` | drop the outer band edges (FFT-edge artifacts) — **diverges from the stage/viewer fallback of 150; see below** |
| `cfg.rfi_band_pad_khz` | `1` | widen each proposed band for the L1 notch |
| `cfg.rfi_min_width_khz` | `0.1` | drop runs narrower than this — **diverges from the stage/viewer fallback of 0.3; see below** |

## Defaults

Hidden fallbacks, i.e. values used only if the corresponding `cfg` field is
absent/empty. All confirmed directly from `getfield_default`/`getdef` calls
in the stage source (not inferred).

**compute_L2** (`getfield_default`) — the two chain-cal knobs are left to
these fallbacks in production (the entry script sets neither; the former
third knob, `chain_phase_ref_deg`, was retired 2026-07-17 — see
[Chain-cal knobs](#chain-cal-knobs)):

| Field | Fallback | Notes |
|---|---|---|
| `chain_run_gap_min` | `20` | not set by the entry script; legacy-flat gap grouping only — see [Chain-cal knobs](#chain-cal-knobs) |
| `chain_join_tol_min` | `60` | not set by the entry script; hard limit for legacy-flat joins, diagnostic-only for session-keyed joins — see [Chain-cal knobs](#chain-cal-knobs) |

**compute_rfi_spectrum** (`getdef`) — the "hidden" set below is never set by
the entry script at all (no corresponding `cfg.*` assignment exists in
`BrundageSoOp.m`):

| Field | Fallback | Notes |
|---|---|---|
| `rfi_seg_len` | `2^16` | ~305 Hz bins at 20 MS/s |
| `rfi_read_samples` | `16*seg_len` | |
| `rfi_max_captures` | `500` | even season subsample |
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

The two knobs, both overridable from cfg:

- `chain_run_gap_min` — legacy-flat calib rows further apart than this start
  a new gap run (20). Session-keyed rows ignore it: one cryosoop run folder
  (`session_id` = `<YYYYMMDD>/<HHMMSS>`) is one run by identity.
- `chain_join_tol_min` — max |capture time − calib run time| for the
  legacy-flat nearest-run join (60). Session-keyed joins are exact identity
  joins with **no time limit**; the tolerance only fires a diagnostic
  (`WARNING(chaincal-key)`) if a same-session match is suspiciously far away.

**Full per-session subtraction — no reference knob (2026-07-17)**: the
correction is unconditionally
`phase_corr_cal = wrap180(phase_corr − phase_chain)` — each capture is
corrected by its own UHD session's measured inter-channel chain phase alone,
no season-derived constant, nothing to re-derive after a UHD/firmware/
hardware step (the per-session measurement absorbs the step by
construction). This zeroes the calibrated phase at the calibration injection
reference plane, the same full-offset behavior as the Ettus gr-doa
direction-finding correction. Calibrated phase columns therefore sit
~`−phase_chain` (~+81 deg) offset from the uncorrected columns; circular
differences, trends, and sigma0 magnitudes are unaffected by the constant.

**Retired reference knob (`chain_phase_ref_deg`) — history**: from
2026-07-04 to 2026-07-17 a FIXED reference was subtracted alongside the
chain phase (`phase_corr_cal = wrap180(phase_corr − (phase_chain − ref))`),
anchored to the 2025-26 season circular mean of the notch chain series
(`+81.4`, then `−81.4` after the 2026-07-06 v5 conjugation unification
below) so the *applied* correction was ~zero-mean — a monitoring/insurance
framing. On 2026-07-17 the reference moved to `0` (full subtraction) and the
knob was then removed entirely: a knob that must forever stay `0` invites a
silent phase-level convention change. Setting `cfg.chain_phase_ref_deg`
today is ignored. Reproducing the legacy anchored phase level is possible
only from git history / archived CSVs (accepted — the season products are
being reprocessed and the legacy anchored outputs dropped). The removal
bumped the dependency-stamp `algo_version` to 2, so any product built under
a v1 stamp rebuilds once.

**Session-keyed join + dependency stamp (2026-07-17)**: calib and L1 CSVs
carry a `session_id` sentinel (schema v6; `lib/session_key.m`): the
`<YYYYMMDD>/<HHMMSS>` run-folder key (one cryosoop folder == one UHD
session), `legacy-flat` (data-root capture, time-gap grouping), or `unknown`
(fails closed: no chain cal). compute_L2 records the association per row in
`chain_session` and gates incremental appends on two checks made before the
existing-row filter: the config/algorithm stamp
(`BrundageSoOp_L2_chaincal_stamp.json`: algorithm version + the two knobs;
the run table is stored for provenance) must match, and every existing row's
freshly recomputed chain association (phase + session) must equal what it
has stored. Any difference — knob change, algorithm change, late-added pairs
shifting a session mean, repaired overflow flags or session_id values, newly
usable calibration (e.g. after the v6 migration), a regenerated calib CSV —
archives and rebuilds the whole L2 CSV (cheap) and renames any sigma0
product aside (`_stale_*`).

**Frequency-flat assumption (accepted 2026-07-17)**: one full-band, lag-zero
chain phase is applied to all three phase domains (sinc / fd / fd_muos).
The `nl_peak_lag` / `l_peak_lag` calib diagnostics exist if a differential
group delay or band-dependent chain response is ever suspected; known
caveat — the notch method's state-specific NL/L RFI operators degrade the
baseline cancellation (~0.5 vs ~0.1 deg season scatter), accepted as-is.

**Sign convention, updated 2026-07-06 (schema v5 conjugation unification)**:
as of the cryosoop-port adaptation, `compute_calib` correlates `D.*conj(R)`
(the same convention `compute_L1` already used),
so `compute_L2`'s chain term now **SUBTRACTS** from the signal phase (it
previously ADDED, back when `compute_calib` correlated the opposite order,
`R.*conj(D)`). This is a scientific/sign-convention change and must
be re-checked (not assumed) if the calib conjugation convention changes
again; pre-v5 calib CSVs store negated phases and are archived + reprocessed
by `compute_calib` before use.

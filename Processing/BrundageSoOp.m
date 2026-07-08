%% BrundageSoOp.m — main entry SCRIPT for Brundage SoOp post-processing.
% Runs in three contexts, platform detected automatically:
%   sbatch on Borah (matlab -batch)  -> process (parfor), no viewer
%   MATLAB GUI on Borah (TurboVNC)   -> process + interactive viewer
%   MATLAB GUI on local PC           -> interactive viewer (toggles off by default)
% Each stage checks existing output and appends only new files — safe to re-run.
% Config-field rationale: docs/config-reference.md (relocated from this script).
% Author: Thomas Van Der Weide
% Date: 2026-07-08

%% Path setup (must be first — puts stages/rfi/lib/viewer/tools on the path)
soop_setup_paths;

%% Platform detection
on_hpc   = isunix;                  % Borah (Linux) vs local Windows
is_batch = batchStartupOptionUsed;  % true when launched via matlab -batch (sbatch) — no figure windows possible

%% Configuration (processing params identical on both systems)
% cfg.input_dir = STABLE season inputs (overflow list, muos_elevation_*, rfi_bands) shared by every dated run.
% cfg.out_dir below is the dated run ROOT (edit per re-run); it is re-derived into fig_dir (Figures) + out_dir (L1 leaf).
% rfi_excise.method_out_dir string-suffixes the leaf, so 'notch_interp' lands in a sibling L1_notch\ folder.
if on_hpc
    % Retired 2025-26 season scratch tree (flat rx_samples_to_file captures on
    % Borah). The cryosoop Borah/Borah-scratch deploy is TBD — update these
    % paths (and expect the per-run <YYYYMMDD>/<HHMMSS>/ layout) when it lands.
    cfg.data_dir  = '/bsuscratch/thomasvanderweide/BrundageSoOp/Data/';
    cfg.input_dir = '/bsuscratch/thomasvanderweide/BrundageSoOp/Static';
    cfg.out_dir   = '/bsuscratch/thomasvanderweide/BrundageSoOp/2026-06-24/';
else
    % --- FUTURE: cryosoop B210 field data (per-run layout) --------------------
    % cryosoop writes <DATA_ROOT>/<YYYYMMDD>/<HHMMSS>/ per-run subfolders;
    % compute_L1 / compute_calib / compute_rfi_spectrum now discover captures
    % recursively (dir '**'), so cfg.data_dir points at the DATA_ROOT and the
    % nested run folders are found automatically. Regenerate the overflow list
    % from the per-run events.csv logs (events auto-mode) with, e.g.:
    %   find_overflows('<DATA_ROOT>', '<input_dir>\overflow_timestamps.txt')
    % TODO: set these once B210 field data lands:
    %   cfg.data_dir  = '<DATA_ROOT>';   % e.g. ...\CryoSoOp\Data
    %   cfg.input_dir = '<STATIC_DIR>';  % stable season inputs (overflow list, elev, rfi_bands)
    %   cfg.out_dir   = '<DATED_RUN_ROOT>';
    % -------------------------------------------------------------------------
    cfg.data_dir  = 'F:\Data\';   % external drive: ~95% of season raw data
    cfg.input_dir = 'C:\Users\thomasvanderweide\Documents\Data\BrundageSoOp\Static';
    cfg.out_dir   = 'C:\Users\thomasvanderweide\Documents\Data\BrundageSoOp\2026-06-24\';
end
cfg.fig_dir = fullfile(cfg.out_dir, 'Figures');
cfg.out_dir = fullfile(cfg.out_dir, 'L1');
cfg.fs           = 20e6;        % sample rate (Hz)
cfg.Ti           = 0.9;         % coherent integration time per segment (s)
cfg.num_segs     = 2;           % segments to coherently average per file
cfg.peak_lag     = -0.575;      % target lag (samples); sign validated 2026-01-28: -0.575 (+1.4 dB SNR vs +0.575)
cfg.lag_half_win = 2500;        % analysis window half-width (matches Python llm/uum ±2500)
cfg.freq_hz      = 370e6;       % center frequency (Hz); lambda = c/f = 0.8102 m for L2
cfg.tower_h_m    = 6.096;       % tower height (m), 20 ft — confirmed 2026-06-12; RS2 survey 2026-06-15 reconfirms
cfg.T_load_K     = 303;         % load temperature (K), assumed ambient

% --- L2 geometric correction (site from Emlid Reach RS2 survey, 2026-06-15) ---
cfg.site_lat   = 44.99908744;   % deg N  (RS2)
cfg.site_lon   = -116.133436;   % deg E  (RS2)
cfg.site_alt_m = 2247.113;      % m, WGS84 ellipsoidal — antenna phase center (ground 2241.017 + 6.096 m tower); <0.001 deg at GEO
cfg.capture_tz = 'America/Boise';  % Pi clock TZ — VERIFIED 2026-06-12 timedatectl (Local MDT, RTC UTC); filenames local, span Mar 8 MST->MDT
% Chain-phase cal reference (compute_L2): sign flipped 2026-07-06 when compute_calib
% was unified to the D.*conj(R) convention (calib chain series negates); magnitude
% 81.4 deg from the season notch-phase series (docs/config-reference.md#chain-cal-knobs).
cfg.chain_phase_ref_deg = -81.4;
cfg.snr_threshold  = 10;        % dB; used by compare_sat_candidates scoring
% Stable season input (not per-run): overflow capture list (find_overflows.m).
cfg.overflow_file  = fullfile(cfg.input_dir, 'overflow_timestamps.txt');
% Weather station TOA5 file (local copy) — viewer L2: Candidates weather overlay
% (Snow depth / AirTC_Avg / Temp_C_Avg checkboxes) only.
cfg.wx_dat = 'C:\Users\thomasvanderweide\Documents\Projects\CryoSoOp\Background\20260608_Brundage_15Min.dat';
% Temp columns overlaid on SNOdar plots: AirTC_Avg (air temp, melt-freeze driver), Temp_C_Avg (TemperaturePlot_SnowDepth.py sensor); order maps to airtc_c, temp_c.
cfg.wx_temp_cols = {'AirTC_Avg', 'Temp_C_Avg'};
% Elevation tables (make_muos_elevation.py), stable inputs in cfg.elev_dir: sat-id scans elev_dir for muos_elevation_*.csv; compute_L2 reads cfg.elev_table for the CONFIRMED sat (predicted MUOS-5 41622 — confirm via compare_sat_candidates first).
cfg.elev_dir   = cfg.input_dir;
cfg.elev_table = fullfile(cfg.elev_dir, 'muos_elevation_41622.csv');

% Minimum valid size PER CHANNEL FILE (interleaved I/Q int16): num_segs*Ti*fs*2*2 = 144,000,000 B.
% Healthy cryosoop captures are EXACTLY 160,000,000 B (2.0 s * 20 MS/s * 4 B sc16); old-season
% captures were ~156 MB (truncated), still above the 144 MB gate. Gate unchanged for both formats.
cfg.min_bytes    = cfg.fs * cfg.Ti * cfg.num_segs * 2 * 2;

% Pairs per batch between CSV appends; a mid-run death loses at most one batch (restart skips CSV'd work).
cfg.batch_size   = 200;
cfg.use_gpu      = false;       % CPU parfor is the validated path

% --- RFI excision (off by default; bands from compute_rfi_spectrum) ---
% Each method writes a self-contained product set: 'none' -> cfg.out_dir (v3 path), 'notch_interp' -> <out_dir>_notch.
% L1/calib process all selected methods in one read/FFT pass; downstream stages then run per method dir (Run section).
cfg.rfi_methods = {'notch_interp'};
% update_base also (re)processes the base/'none' set in cfg.out_dir alongside the excised sets (incremental adds only new captures). Set false to leave the base frozen.
update_base = true;
if update_base, cfg.rfi_methods = [{'none'}, cfg.rfi_methods]; end
% RFI bands: loaded from the curated season CSV (cfg.rfi_bands_file) exported from the viewer's RFI explorer. The CSV is the single source of truth — edit it, not here. Columns: f_lo_hz, f_hi_hz (, source).
cfg.rfi_bands_file = fullfile(cfg.input_dir, 'rfi_bands.csv');
if isfile(cfg.rfi_bands_file)
    B = readtable(cfg.rfi_bands_file);
    cfg.rfi_bands = [B.f_lo_hz, B.f_hi_hz];   % N x 2 [f_lo_hz f_hi_hz], RF Hz
    fprintf('[BrundageSoOp] Loaded %d RFI band(s) from %s\n', ...
            size(cfg.rfi_bands, 1), cfg.rfi_bands_file);
else
    warning('BrundageSoOp:noRfiBands', ['rfi_bands_file not found (%s) — ' ...
            'notch will be a no-op (behaves like ''none'').'], cfg.rfi_bands_file);
    cfg.rfi_bands = [];
end
% --- MUOS sub-channel bands (freq_muos frequency-domain comparison) ---
% Four MUOS WCDMA downlink channels (360–380 MHz, centers 362.5/367.5/372.5/377.5); compute_L1 evaluates a SECOND phase over ONLY these bins (peak_phase_deg_fd_muos). RF Hz, N x 2 [f_lo_hz f_hi_hz], center ± 2.3 MHz inside each guard null.
cfg.muos_bands = 1e6 * [ ...
    360.20, 364.80;   % MUOS ch1 (center 362.5)
    365.20, 369.80;   % MUOS ch2 (center 367.5)
    370.20, 374.80;   % MUOS ch3 (center 372.5)
    375.20, 379.80];  % MUOS ch4 (center 377.5)
cfg.rfi_apply_calib  = true;       % also excise calibration captures (consistency)
% Band-finder (compute_rfi_spectrum + viewer explorer); these seed the explorer's controls — tune live, then Export to rfi_bands.
cfg.rfi_excess_db    = 3;          % flag bins this many dB above the smoothed PSD envelope
cfg.rfi_sk_threshold = 50;        % also flag bins with spectral kurtosis >= this (bursty RFI)
cfg.rfi_use_sk       = true;       % include the SK gate in the proposed bands
cfg.rfi_env_khz      = 500;       % PSD-envelope movmedian width
cfg.rfi_merge_khz    = 15;         % merge flagged runs closer than this into one band
cfg.rfi_edge_guard_khz = 0;        % drop the outer band edges (FFT-edge artifacts)
cfg.rfi_band_pad_khz = 1;          % widen each proposed band for the L1 notch
cfg.rfi_min_width_khz = 0.1;       % drop runs narrower than this

%% Processing toggles
% Default: process on the HPC, inspect locally. Override here (e.g. run_calib = true locally for a ~1.5-2 h calib pass from F:).
run_L1    = on_hpc;
run_calib = on_hpc;
run_snr   = false;   % needs the L1 CSV; run after the first full L1 pass
run_satid = false;    % compare_sat_candidates: produces sat_candidates_corrected.csv
run_L2    = false;    % needs cfg.elev_table for the CONFIRMED satellite
run_rfi   = false;   % compute_rfi_spectrum: season RFI diagnostic + proposed bands

%% Run pipeline (parpool sizing + stage dispatch + per-method downstream loop)
toggles.run_L1    = run_L1;
toggles.run_calib = run_calib;
toggles.run_snr   = run_snr;
toggles.run_satid = run_satid;
toggles.run_L2    = run_L2;
toggles.run_rfi   = run_rfi;
soop_run_pipeline(cfg, toggles);

%% Interactive viewer (skipped under matlab -batch: no display)
% Opens on cfg.out_dir; to inspect an excised set point cfg.out_dir at the method dir (e.g. ...\L1_notch) and re-run.
if ~is_batch
    BrundageSoOp_viewer(cfg);
end

function BrundageSoOp_viewer(cfg)
% Interactive season viewer for Brundage SoOp products and raw captures.
%
% Usage: BrundageSoOp_viewer(cfg)  — same cfg struct as BrundageSoOp.m.
%   cfg.out_dir   — folder holding BrundageSoOp_L1_sig.csv / _calib.csv
%                   (local results or CSVs copied back from Borah)
%   cfg.data_dir  — raw capture folder (e.g. F:\Data\) for the Raw: views
%   cfg.fs, cfg.Ti, cfg.num_segs, cfg.freq_hz, cfg.peak_lag, cfg.lag_half_win
%
% Three plot families share the same date-range selection:
%   L1:    time series / distributions from BrundageSoOp_L1_sig.csv
%   Calib: stability time series from BrundageSoOp_calib.csv
%   Raw:   on-demand reads of single captures from cfg.data_dir
%          (PSD spur-hunting, cross-correlation profiles, spectrogram)
%
% Aggregation (CSV time series only): Raw captures | Per-run mean (the 15
% captures of each 2-hourly run) | Daily mean | Range mean. Phase columns
% aggregate with CIRCULAR statistics (arithmetic means are wrong for
% ±180°-wrapped phase); SNR (dB) averages in linear power.
%
% This file is UI only. All math/DSP/stats and data IO (Hanning, Welch PSD,
% STFT, cross-correlation, circular stats, sc16/CSV/SNOdar reads) live in
% BrundageSoOp_fun.m, reached via the handle struct M = BrundageSoOp_fun().
% Each plot's side panel shows its core formula and links to the function used.

    % ---- Math / DSP / IO helpers (see BrundageSoOp_fun.m) ----
    % The viewer is UI-only; all number-crunching lives in BrundageSoOp_fun.
    % V is a handle object of shared state, visible to every module callback.
    V = SoopViewerState();
    V.cfg = cfg;
    V.M   = BrundageSoOp_fun();

    % ---- Derived constants ----
    V.npts   = floor(cfg.fs * cfg.Ti);   % samples per segment
    V.n_want = V.npts * cfg.num_segs;    % samples read per channel for raw views
    % Nominal independent looks for the calib lag-0 cross-correlation = B*T, used
    % only by the expected-thermal-phase-noise floor in the Calib rho-phase views.
    % The lag-0 mean (compute_calib.m) runs over the ENTIRE capture (read_capture
    % reads the full file), so N_L = fs * T_capture (~2 s), NOT fs*Ti*num_segs.
    % load_csvs replaces this default with exact n_samps_nl/n_samps_l counts
    % when present. notch/butterworth sets drop bins, so effective N_L is slightly
    % lower (second-order; documented, not modeled).
    V.calib_N_looks = cfg.fs * 2;        % ~ 4e7 (20 MHz x 2 s)

    V.Erfi = rfi_excise();

    % ---- State shared by module callbacks ----
    V.L1   = table();      % L1 CSV (sorted by timestamp)
    V.CAL  = table();      % calib CSV
    V.cache = struct('key', "", 'data', []);   % last raw-capture computation
    % Base (unfiltered) calib table cache, and notch (RFI-excised) cache — read
    % once per dir, not every render. dir="" forces a load on first use.
    V.calib_base_cache  = struct('dir', "", 'T', table());
    V.calib_notch_cache = struct('dir', "", 'T', table());
    V.busy    = false;     % a render is in progress (re-entrancy guard)
    V.pending = false;     % a newer refresh arrived mid-render; re-run on exit
    V.last_n  = 0;         % rows plotted by the last CSV render (side panel)
    V.OVF = strings(0, 1); % overflow-flagged capture bases (from find_overflows)
    % base_name -> containing folder, filled by the recursive capture discovery
    % (rebuild_caplist / rr_nearest_capture) and read by rr_load_capture.
    V.cap_folders = containers.Map('KeyType', 'char', 'ValueType', 'char');
    % Per-plot label-text overrides (empty = auto label from the render).
    V.ov_title     = '';
    V.ov_xlabel    = '';
    V.ov_ylabel    = '';
    V.ov_plot_kind = '';   % plot the text overrides belong to (reset on switch)

    % ---- Module handle structs (set before layout so callbacks can bind) ----
    V.U  = soop_viewer_util();
    V.D  = soop_viewer_data();
    V.CB = soop_viewer_callbacks();

    % ---- Product directories ----
    V.base_out_dir  = cfg.out_dir;                              % base product directory
    V.rfi_dir       = V.U.cfgdef(V, 'input_dir', V.base_out_dir);   % Static: season-wide RFI products
    V.notch_out_dir = V.Erfi.method_out_dir(cfg.out_dir, 'notch_interp');

    % ---- Plot catalog (names, side-panel text, math table) ----
    [V.PLOT_INFO, V.CAP_PATTERNS] = soop_viewer_catalog(cfg);

    % ---- Figure & layout ----
    soop_viewer_layout(V);

    % ---- Initial load ----
    V.D.load_csvs(V);
    V.CB.set_range(V, 'full');
    V.CB.rebuild_caplist(V, false);
    V.CB.refresh(V);
end

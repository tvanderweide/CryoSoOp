function D = soop_viewer_data()
% Product-CSV loading + calib-table helpers for BrundageSoOp_viewer.
    D.load_csvs = @load_csvs;
    D.base_calib_table = @base_calib_table;
    D.notch_calib_table = @notch_calib_table;
    D.filter_calib = @filter_calib;
    D.chaincal_delta = @chaincal_delta;
    D.chain_phase_col = @chain_phase_col;
end


function load_csvs(V)
    S = V;
    cfg = V.cfg;
    M = V.M;
    S.L1   = M.read_product(fullfile(cfg.out_dir, 'BrundageSoOp_L1_sig.csv'));
    S.CAL  = M.read_product(fullfile(cfg.out_dir, 'BrundageSoOp_calib.csv'));
    S.L2   = M.read_product(fullfile(cfg.out_dir, 'BrundageSoOp_L2.csv'));
    S.SIG0 = M.read_product(fullfile(cfg.out_dir, 'BrundageSoOp_sigma0.csv'));
    S.CAND = M.read_product(fullfile(cfg.out_dir, 'sat_candidates_corrected.csv'));
    S.WX   = M.load_snodar(cfg);

    % Independent looks N_L for the calib lag-0 cross-correlation thermal
    % phase-noise floor (sigma_phi). Schema v5 stores the EXACT per-capture
    % complex-sample counts read per NL/L pair (n_samps_nl / n_samps_l); the
    % defensible per-pair look count is min(n_samps_nl, n_samps_l). The floor
    % consumers (rc_phase_noise_plot uses per-BIN mean rho; looks_curve_plot
    % takes a median) all reduce N_L to a single scalar, so a representative
    % scalar — the median per-pair look count — is used here rather than
    % per-row counts. Fall back to the nominal B*T (~ cfg.fs * 2 s) for a pre-v5
    % CSV that predates these columns (columns absent => tolerated gracefully).
    S.calib_N_looks = cfg.fs * 2;
    if ~isempty(S.CAL) && all(ismember({'n_samps_nl', 'n_samps_l'}, ...
            S.CAL.Properties.VariableNames))
        per_pair = min(S.CAL.n_samps_nl, S.CAL.n_samps_l);
        per_pair = per_pair(isfinite(per_pair) & per_pair > 0);
        if ~isempty(per_pair)
            S.calib_N_looks = median(per_pair);
        end
    end
    % Overflow-flagged capture bases (optional; from find_overflows.m).
    % Prefer cfg.overflow_file (stable season input, decoupled from out_dir);
    % else fall back to the per-method dir then the base dir.
    S.OVF = strings(0, 1);
    if isfield(cfg, 'overflow_file') && ~isempty(cfg.overflow_file) ...
            && isfile(cfg.overflow_file)
        ovf_file = cfg.overflow_file;
    else
        ovf_file = fullfile(cfg.out_dir, 'overflow_timestamps.txt');
        if ~isfile(ovf_file) && ~isempty(S.base_out_dir)
            ovf_file = fullfile(S.base_out_dir, 'overflow_timestamps.txt');  % shared input
        end
    end
    if isfile(ovf_file)
        S.OVF = strtrim(readlines(ovf_file));
        S.OVF = S.OVF(strlength(S.OVF) > 0);
    end
end


function Tb = base_calib_table(V)
    S = V;
    cfg = V.cfg;
    M = V.M;
    filter_calib = @(varargin) V.D.filter_calib(V, varargin{:});
    % Base (unfiltered) calib rows for the current date range + overflow
    % filter, used to anchor the Calib y-axis. Reuses S.CAL when the active
    % Dataset already IS base; otherwise reads the base product CSV once and
    % caches it (re-read only if base_out_dir changes). Empty => caller skips
    % anchoring and keeps the current autoscale.
    if strcmp(cfg.out_dir, S.base_out_dir)
        Traw = S.CAL;
    else
        if ~strcmp(S.calib_base_cache.dir, string(S.base_out_dir))
            S.calib_base_cache.dir = string(S.base_out_dir);
            S.calib_base_cache.T = M.read_product( ...
                fullfile(S.base_out_dir, 'BrundageSoOp_calib.csv'));
        end
        Traw = S.calib_base_cache.T;
    end
    Tb = filter_calib(Traw);
end


function Tn = notch_calib_table(V)
    S = V;
    M = V.M;
    filter_calib = @(varargin) V.D.filter_calib(V, varargin{:});
    % Notch (RFI-excised) calib rows for the current range + overflow filter,
    % for the 'base vs notch' overlay. Cached like base_calib_table; empty
    % (e.g. notch products not generated) => caller skips the overlay.
    if ~strcmp(S.calib_notch_cache.dir, string(S.notch_out_dir))
        S.calib_notch_cache.dir = string(S.notch_out_dir);
        S.calib_notch_cache.T = M.read_product( ...
            fullfile(S.notch_out_dir, 'BrundageSoOp_calib.csv'));
    end
    Tn = filter_calib(S.calib_notch_cache.T);
end


function Tf = filter_calib(V, Traw)
    range_bounds = @(varargin) V.U.range_bounds(V, varargin{:});
    tcol = V.U.tcol;
    % Date-range + overflow filtering matching render_calib's main table, but
    % silent (no warnings/messages) — used to build the base-anchor table.
    Tf = table();
    if isempty(Traw), return; end
    [t0, t1] = range_bounds();
    Tf = Traw(tcol(Traw) >= t0 & tcol(Traw) < t1, :);
    if isempty(Tf), return; end
    if ismember('overflow_flag', Tf.Properties.VariableNames)
        Tf = Tf(Tf.overflow_flag == 0, :);
    end
end


function [dlt, ok, why] = chaincal_delta(V, TT)
    S = V;
    wrap_deg = V.U.wrap_deg;
    % Per-row chain-phase correction wrap180(phase_corr_cal_deg -
    % phase_corr_deg) from the active product dir's L2 CSV, joined to TT by
    % base_name (== -phase_chain_deg, full per-session subtraction — the
    % sign the L2 runtime applies; identical for all phase domains, so one
    % delta serves sinc/fd/muos columns).
    % Rows without an L2 match or with NaN chain phase get NaN (dropped
    % from the plot rather than silently left uncorrected). ok=false with a
    % message when the L2 CSV predates the chain-cal schema.
    dlt = nan(height(TT), 1);
    ok  = false;
    why = ['Chain-cal needs phase_corr_cal_deg in BrundageSoOp_L2.csv ' ...
           'for this Dataset — re-run compute_L2 (chain-cal schema).'];
    if isempty(S.L2) || ~all(ismember({'base_name', 'phase_corr_cal_deg', ...
            'phase_corr_deg'}, S.L2.Properties.VariableNames))
        return;
    end
    d = wrap_deg(S.L2.phase_corr_cal_deg - S.L2.phase_corr_deg);
    [tf, loc] = ismember(string(TT.base_name), string(S.L2.base_name));
    dlt(tf) = d(loc(tf));
    ok  = true;
    why = '';
end


function ph = chain_phase_col(Tin)
    % Per-pair leak-cancelled receiver chain phase angle(C_RDNS - C_RDL),
    % degrees. The NL and L states share the injection path and the
    % receiver-internal common-mode leak, so the complex difference cancels
    % the leak (and the small common-load term), isolating the noise-diode
    % path. Mirrors chain_phase_runs() in compute_L2.m (per-pair here; the
    % L2 correction reduces pairs to per-run circular means).
    z = Tin.C_RDNS_amp .* exp(1i * deg2rad(Tin.C_RDNS_phase_deg)) ...
      - Tin.C_RDL_amp  .* exp(1i * deg2rad(Tin.C_RDL_phase_deg));
    ph = rad2deg(angle(z));
end

function compute_sigma0(cfg)
% Sigma0: direct-referenced radar-equation calibration (apparent normalized
% bistatic radar cross section sigma0 + coherent power reflectivity Gamma).
%
% IIP-SoOpSAR-processing-equations §2.2, Eqs. 41-42; first-Fresnel-zone
% footprint from Larson & Nievinski (2013). Following Shah et al. (2017), the
% direct-referenced per-capture complex correlation C is normalized by the
% measured direct-channel power P_dsig so
% the (time-varying, power-controlled) MUOS EIRP and the wavelength cancel and
% only gain RATIOS survive. The observable is
%       c_hat = C / P_dsig     (dimensionless),
% and over a centered sliding window of captures (default 24 h),
%   sigma0 = 4 pi (r1 r2/rd)^2 (Gd/Gr)(Gde/Gre) <|c_hat-<c_hat>|^2> / A_eff
%   Gamma  =      ((r1+r2)/rd)^2 (Gd/Gr)(Gde/Gre) |<c_hat>|^2.
% The pure geometry/estimator math lives in lib/sigma0_math.m (unit-testable).
%
% ESTIMATOR NOTES / KNOWN BIASES (competing, UNSIGNED net bias — do not read
% the products as upper or lower bounds of the true values):
%   * NO receiver-noise subtraction. P_dsig = pow_ch0_<band> includes receiver
%     noise, which shrinks c_hat by ~1/(1 + 1/DSNR) and pulls both products
%     DOWN by up to (1 + 1/DSNR)^2. Numerator estimator noise (thermal
%     correlation noise, residual RFI, real geophysical change in the window)
%     simultaneously inflates the sigma0 variance UP. The net sign of the
%     sigma0 bias is therefore NOT guaranteed; Gamma has no such variance term
%     and is predominantly biased LOW by the noisy denominator. dsnr_db (the
%     true signal/noise ratio, see below) and c_var_noise_est are emitted as
%     per-row diagnostics. P_DN is used for the SNR guard but not subtracted;
%     only G_De/G_Re is treated as robust, and notch noise bandwidth depends on
%     the selected operator.
%   * Coherent-mean removal is done in c_hat space (NOT on prefactor-scaled
%     samples), then per-capture prefactors multiply each squared residual;
%     geometry/gain are therefore applied per capture, before the window
%     statistic (see sigma0_math.window_stats).
%   * The window variance uses 1/(N-1) (unbiased iid sample variance). Captures
%     are temporally clustered and overlapping windows are strongly correlated,
%     so n_window OVERCOUNTS independent looks; n_runs (contiguous-run count) is
%     emitted alongside as a coarse effective-DOF hint. Real geophysical change
%     within the window also mixes into the "incoherent" variance — hence
%     "apparent" sigma0.
%   * Dividing by the noisy per-capture P_dsig is a ratio estimator (biased for
%     small denominators); captures with dsnr_db < cfg.sigma0_min_dsnr_db are
%     excluded from the windows, and so are captures whose ratio is
%     UNASSESSABLE (flag_dsnr_na: P_DN missing/nonpositive, or an empty family
%     band) — the guard cannot be verified for them.
%
% APPROXIMATIONS:
%   * r2 ~= rd: the receiver-to-specular-point range equals the receiver-to-
%     satellite range to < 1e-6 for a 6 m tower at GEO, so rd (from the
%     elevation table's range_km) is used for r2.
%   * Gamma is height-independent to first order (r1+r2 ~ r2 ~ rd), so the
%     fixed-h r1 is used for the Gamma prefactor.
%   * Fixed tower + locally planar horizontal reflector (r1 = h/sin e and the
%     Fresnel footprint both assume this).
%
% RECOMPUTE-FULL: the centered sliding window means a newly appended capture
% changes other rows' window membership, so this stage is not incremental —
% it recomputes every row each run and ATOMICALLY overwrites the output (write a
% temp CSV in the same dir, then movefile over the destination). The math is
% cheap (CSV-only), so a full recompute is inexpensive. STALE-OUTPUT GUARD:
% when a prerequisite is unmet (missing L1/L2/elevation table, required L1
% columns, or joined rows), the stage cannot recompute, so any existing CSV is
% renamed aside (_stale_<yyyyMMdd_HHmmss>) rather than left in place — a
% recompute-full product must never be silently consumable when its inputs are
% gone. A missing calib CSV is NOT a prerequisite failure (see INPUTS).
%
% INPUTS (all in cfg.out_dir, the per-method product dir):
%   BrundageSoOp_L1_sig.csv  (requires channel-power fields pow_ch0_*),
%   BrundageSoOp_L2.csv      (theta_deg + chain-calibrated phase, overflow-free),
%   BrundageSoOp_calib.csv   (G_De, G_Re, P_DN; OPTIONAL — a method dir without
%                             calib still yields a product with NaN gains,
%                             flag_cal_missing=1, and NaN science products),
%   cfg.elev_table           (range_km column; interpolated at capture times).
%
% cfg FIELDS CONSUMED:
%   out_dir, freq_hz, fs, Ti, num_segs, tower_h_m, muos_bands, capture_tz,
%   elev_table, and (all via getfield_default so the stage runs standalone):
%   sigma0_corr_family (default 'fd_muos'; also 'fd', 'td'),
%   sigma0_cal_max_age_hr (default 1.0 h), sigma0_win_hours (24),
%   sigma0_min_count (5),
%   sigma0_min_elev_deg (5), sigma0_min_dsnr_db (10),
%   ant_gain_direct_dbi (2), ant_gain_reflected_dbi (2). The direct antenna is
%   RHCP and the reflected LHCP; both are the co-pol expected signal, so no
%   polarization-mismatch factor is applied (scalar, non-directional gains — a
%   documented limitation). Snow depth is read via BrundageSoOp_fun().load_snodar
%   (cfg.wx_dat etc.).
%
% OUTPUT: cfg.out_dir/BrundageSoOp_sigma0.csv — one row per joined capture
% (guard failures give NaN products; rows are kept). Columns / units:
%   timestamp                 capture time (capture timebase)
%   base_name                 capture base name
%   theta_deg                 satellite elevation (deg, from L2)
%   range_km                  receiver-satellite range (km, elev-table interp)
%   r_d_m                     rd = range (m)
%   r1_fixed_m / r1_snow_m    reflected path length h/sin(e) (m) for fixed / snow h
%   Aeff_fixed_m2/Aeff_snow_m2 first-Fresnel footprint area (m^2), fixed / snow h
%   snow_depth_m              SNOdar snow depth (m); NaN if no weather data
%   h_fixed_m / h_snow_m      tower height and tower - snow_depth (m)
%   G_De / G_Re               joined direct/reflected electronics gains (ADC^2/W)
%   cal_age_s                 |capture - nearest calib| (s); NaN if no calib
%   P_dsig_adc2               direct-channel power in the family band (ADC^2)
%   dsnr_db                   direct-channel SNR 10log10((P_dsig-P_noise)/P_noise),
%                             P_noise = NG*f_band*P_DN with the band matched to
%                             the selected family; NaN when unassessable, -Inf
%                             when the direct power does not exceed the noise
%   c_mean_re / c_mean_im     window coherent mean of c_hat (dimensionless)
%   c_var                     window sample variance of c_hat, 1/(N-1) (dimensionless)
%   c_var_noise_est           predicted thermal c_hat variance floor (dimensionless,
%                             independent-bin approximation — see below)
%   n_window                  # valid captures in the window
%   n_runs                    # contiguous capture runs in the window (gap>1 h)
%   flag_dsnr_low             1 if assessed dsnr_db < sigma0_min_dsnr_db (excluded)
%   flag_dsnr_na              1 if the SNR guard is unassessable (P_DN missing/
%                             nonpositive or empty family band) — excluded
%   flag_cal_missing          1 if no calib within tolerance (gains NaN)
%   flag_geom_invalid         1 if theta out of (min_elev, 90] or range invalid
%   sigma0_app_lin_fixed_h    apparent sigma0 (linear, dimensionless), fixed h
%   sigma0_app_lin_snow_h     apparent sigma0 (linear), snow h
%   gamma_lin                 coherent power reflectivity |gamma|^2 (linear, 0 dB
%                             ceiling)
%   ant_gain_direct_dbi/ant_gain_reflected_dbi  gains used (dBi)
%   corr_family               correlation family string ('fd_muos'/'fd'/'td')
%   lambda_m                  wavelength c/freq_hz (m)
% Products are stored LINEAR (dB is applied in the viewer).
%
% c_var_noise_est DERIVATION (independent-bin approximation; label it as such):
% for a matched-normalization cross-spectral estimate, var(<D R*>) ~ P_D P_R /
% n_looks, so var(c_hat) = var(C / P_D) ~ (P_D P_R / n_looks) / P_D^2 =
% P_R / (n_looks P_D). Per capture this is pow_ch1_<band> / (n_looks *
% pow_ch0_<band>) with n_looks = cfg.num_segs * (# band bins of the selected
% family: MUOS bins for fd_muos, all npts bins for fd/td); it is then
% averaged over the same window as c_var. The Hann window correlates adjacent
% FFT bins, so n_looks (and thus the floor) is APPROXIMATE. NaN if the L1
% pow_ch1_<band> column is absent.

    % --- File paths / existence guards -----------------------------------
    l1_csv    = fullfile(cfg.out_dir, 'BrundageSoOp_L1_sig.csv');
    l2_csv    = fullfile(cfg.out_dir, 'BrundageSoOp_L2.csv');
    calib_csv = fullfile(cfg.out_dir, 'BrundageSoOp_calib.csv');
    out_csv   = fullfile(cfg.out_dir, 'BrundageSoOp_sigma0.csv');

    if ~isfile(l1_csv)
        fprintf('[sigma0] %s not found — run compute_L1 first.\n', l1_csv);
        invalidate_stale(out_csv);
        return;
    end
    if ~isfile(l2_csv)
        fprintf('[sigma0] %s not found — run compute_L2 first.\n', l2_csv);
        invalidate_stale(out_csv);
        return;
    end
    if ~isfile(calib_csv)
        % A method dir may legitimately have no calibration CSV (e.g.
        % rfi_apply_calib=false writes calib only in the base dir). The stage
        % still writes its product: NaN gains + flag_cal_missing=1, and (P_DN
        % being unavailable) the DSNR guard is unassessable, so the science
        % products come out NaN while geometry/diagnostic rows remain usable.
        fprintf('[sigma0] %s absent — proceeding with NaN gains (flag_cal_missing).\n', calib_csv);
    end
    if ~isfield(cfg, 'elev_table') || ~isfile(cfg.elev_table)
        fprintf(['[sigma0] Elevation table not found (cfg.elev_table) — run ' ...
                 'make_muos_elevation.py for the confirmed satellite.\n']);
        invalidate_stale(out_csv);
        return;
    end

    % --- Read L1/L2 and validate required fields --------------------------
    L1 = read_stamped(l1_csv);
    L2 = read_stamped(l2_csv);
    if ~ismember('pow_ch0_fd_muos', L1.Properties.VariableNames)
        fprintf(['[sigma0] %s lacks pow_ch0_fd_muos — re-run compute_L1 ' ...
                 '(channel-power schema).\n'], l1_csv);
        invalidate_stale(out_csv);
        return;
    end

    % --- Correlation family -> L1/L2 column mapping ----------------------
    fam = char(getfield_default(cfg, 'sigma0_corr_family', 'fd_muos'));
    switch fam
        case 'fd_muos'
            amp_col = 'peak_amplitude_fd_muos';
            ph_col  = 'phase_corr_cal_fd_muos_deg';
            pow0col = 'pow_ch0_fd_muos';
            pow1col = 'pow_ch1_fd_muos';
        case 'fd'
            amp_col = 'peak_amplitude_fd';
            ph_col  = 'phase_corr_cal_fd_deg';
            pow0col = 'pow_ch0_fd';        % full-band power for the fd family
            pow1col = 'pow_ch1_fd';
        case 'td'
            amp_col = 'peak_amplitude';
            ph_col  = 'phase_corr_cal_deg';
            pow0col = 'pow_ch0_fd';        % no separate td power; use full-band fd
            pow1col = 'pow_ch1_fd';
        otherwise
            error('compute_sigma0:badFamily', ...
                  ['Unknown cfg.sigma0_corr_family "%s" (expected ' ...
                   '''fd_muos'', ''fd'', or ''td'').'], fam);
    end
    if ~ismember(amp_col, L1.Properties.VariableNames)
        error('compute_sigma0:missingAmp', '%s lacks %s (family %s).', l1_csv, amp_col, fam);
    end
    if ~ismember(pow0col, L1.Properties.VariableNames)
        error('compute_sigma0:missingPow', '%s lacks %s (family %s).', l1_csv, pow0col, fam);
    end
    if ~ismember(ph_col, L2.Properties.VariableNames)
        error('compute_sigma0:missingPhase', '%s lacks %s (family %s).', l2_csv, ph_col, fam);
    end

    % --- Inner join L1 <-> L2 on base_name (both must be unique) ----------
    if numel(unique(L1.base_name)) ~= height(L1)
        error('compute_sigma0:dupL1', 'Duplicate base_name in %s.', l1_csv);
    end
    if numel(unique(L2.base_name)) ~= height(L2)
        error('compute_sigma0:dupL2', 'Duplicate base_name in %s.', l2_csv);
    end
    [tf, loc] = ismember(L1.base_name, L2.base_name);
    J1 = L1(tf, :);
    J2 = L2(loc(tf), :);
    if isempty(J1)
        fprintf('[sigma0] No L1<->L2 base_name matches — nothing to do.\n');
        invalidate_stale(out_csv);
        return;
    end
    if max(abs(J1.timestamp - J2.timestamp)) >= seconds(1)
        error('compute_sigma0:tsMismatch', ...
              'Joined L1/L2 timestamps disagree by >= 1 s (check %s vs %s).', l1_csv, l2_csv);
    end
    [~, ord] = sort(J1.timestamp);
    J1 = J1(ord, :);
    J2 = J2(ord, :);
    t  = J1.timestamp;
    t.Format = 'yyyy-MM-dd HH:mm:ss';      % ISO round-trip in the written CSV
    n  = height(J1);

    % --- Per-capture correlation sample c_hat = C / P_dsig ---------------
    amp    = J1.(amp_col);
    phase  = J2.(ph_col);
    P_dsig = J1.(pow0col);
    c_hat  = amp .* exp(1j * deg2rad(phase)) ./ P_dsig;
    c_hat(~(P_dsig > 0)) = NaN;            % guard degenerate/zero direct power

    % --- Geometry: theta from L2, range from the elevation table ----------
    theta = J2.theta_deg;
    E = read_stamped(cfg.elev_table);
    if ~ismember('range_km', E.Properties.VariableNames)
        error('compute_sigma0:noRange', ...
              '%s has no range_km column — regenerate with make_muos_elevation.py.', cfg.elev_table);
    end
    t_utc    = to_utc(t, cfg);             % elevation table is UTC
    range_km = interp1(E.timestamp, E.range_km, t_utc, 'linear', NaN);
    lambda_m = 299792458 / cfg.freq_hz;

    phys_geom = isfinite(theta) & theta > 0 & theta <= 90 & ...
                isfinite(range_km) & range_km > 0;
    r_d = range_km * 1e3;
    r_d(~(isfinite(range_km) & range_km > 0)) = NaN;
    r2  = r_d;                             % r2 ~= rd (see header)

    % --- Calibration join (nearest calib run within tolerance) -----------
    min_elev = getfield_default(cfg, 'sigma0_min_elev_deg', 5);
    cal_tol_hr = getfield_default(cfg, 'sigma0_cal_max_age_hr', 1.0);  % nearest-calibration tolerance (h)
    if isfile(calib_csv)
        [G_De, G_Re, P_DN, cal_age_s, flag_cal_missing] = ...
            join_calib(calib_csv, t, cal_tol_hr);
    else
        % No calibration in this method dir (see the guard note above): NaN
        % gains/noise, every row flagged; products come out NaN downstream.
        G_De = nan(n, 1);  G_Re = nan(n, 1);  P_DN = nan(n, 1);
        cal_age_s = nan(n, 1);  flag_cal_missing = ones(n, 1);
    end
    gde_over_gre = G_De ./ G_Re;           % NaN where calib missing

    % --- Antenna gains (dBi -> linear ratio) -----------------------------
    gd_dbi = getfield_default(cfg, 'ant_gain_direct_dbi',    2);
    gr_dbi = getfield_default(cfg, 'ant_gain_reflected_dbi', 2);
    gd_over_gr = 10 ^ ((gd_dbi - gr_dbi) / 10);

    % --- Direct-channel SNR guard (dsnr_db) -------------------------------
    % NG = Hann window power gain (mean(w^2)), rebuilt EXACTLY as compute_L1's
    % window. The band bin count MATCHES THE SELECTED FAMILY: the fd_muos
    % family's L1 powers cover only the MUOS bins (mask rebuilt with the same
    % rfi_excise band_mask call compute_L1 uses), while the full-band fd/td
    % power columns cover all npts bins (f_band = 1).
    npts = floor(cfg.fs * cfg.Ti);
    nwin = (0:npts-1)';
    win  = 0.5 * (1 - cos(2*pi*nwin / (npts-1)));   % Hanning, matches compute_L1
    NG   = mean(win.^2);
    if strcmp(fam, 'fd_muos')
        E_rfi = rfi_excise();
        muos_bands = getfield_default(cfg, 'muos_bands', []);
        if isempty(muos_bands)
            n_band_bins = 0;                        % no MUOS band -> unassessable
        else
            muos_mask   = E_rfi.band_mask(muos_bands, cfg.freq_hz, cfg.fs, npts);
            n_band_bins = sum(muos_mask);
        end
    else
        n_band_bins = npts;                         % full-band fd/td families
    end
    f_band = n_band_bins / npts;
    % P_dsig is deliberately signal PLUS noise, so the true direct-channel SNR
    % is (P_dsig - P_noise)/P_noise with P_noise = NG*f_band*P_DN. The ratio is
    % ASSESSABLE only when the noise estimate is finite and positive (calib's
    % Eq. 36 P_DN carries no positivity guarantee) and P_dsig is finite and
    % positive; unassessable captures get flag_dsnr_na = 1 and are EXCLUDED
    % from the windows — the ratio-estimator guard cannot be verified for them.
    % An assessable capture whose direct power does not exceed the noise
    % estimate gets dsnr_db = -Inf (assessed, definitively low).
    P_noise    = NG .* f_band .* P_DN;
    assessable = isfinite(P_noise) & P_noise > 0 & isfinite(P_dsig) & P_dsig > 0;
    dsnr_db    = nan(n, 1);
    sig_est    = P_dsig - P_noise;
    dsnr_db(assessable) = 10 * log10(max(sig_est(assessable), 0) ./ P_noise(assessable));
    dsnr_min      = getfield_default(cfg, 'sigma0_min_dsnr_db', 10);
    flag_dsnr_na  = double(~assessable);
    flag_dsnr_low = double(assessable & (dsnr_db < dsnr_min));

    % --- Geometry-invalid flag (out of (min_elev, 90] or bad range) ------
    flag_geom_invalid = double(~phys_geom | theta < min_elev);

    % --- Snow-depth height variant ---------------------------------------
    Mfun = BrundageSoOp_fun();
    WX = Mfun.load_snodar(cfg);
    snow_depth = nan(n, 1);
    if isempty(WX) || ~ismember('depth_m', WX.Properties.VariableNames) || ...
            ~any(isfinite(WX.depth_m))
        fprintf('[sigma0] No SNOdar snow depth — snow-height columns are NaN.\n');
    else
        [wt, iu] = unique(WX.timestamp);             % interp1 needs unique nodes
        snow_depth = interp1(wt, WX.depth_m(iu), t, 'linear', NaN);  % NO to_utc (capture timebase)
    end
    h_fixed = repmat(cfg.tower_h_m, n, 1);
    h_snow  = cfg.tower_h_m - snow_depth;
    h_snow(~(h_snow > 0)) = NaN;                      % require 0 < h_snow

    % --- Per-capture geometry + prefactors -------------------------------
    Hs = sigma0_math();
    r1_fixed = Hs.r1(h_fixed, theta);
    r1_snow  = Hs.r1(h_snow,  theta);
    [Aeff_fixed, ~, ~] = Hs.fresnel(lambda_m, h_fixed, theta);
    [Aeff_snow,  ~, ~] = Hs.fresnel(lambda_m, h_snow,  theta);
    % Non-physical geometry -> NaN so the prefactors (and products) drop out.
    r1_fixed(~phys_geom)   = NaN;   r1_snow(~phys_geom)   = NaN;
    Aeff_fixed(~phys_geom) = NaN;   Aeff_snow(~phys_geom) = NaN;

    k_fixed = Hs.k_sigma0(r1_fixed, r2, r_d, gd_over_gr, gde_over_gre, Aeff_fixed);
    k_snow  = Hs.k_sigma0(r1_snow,  r2, r_d, gd_over_gr, gde_over_gre, Aeff_snow);
    K  = [k_fixed, k_snow];
    kg = Hs.k_gamma(r1_fixed, r2, r_d, gd_over_gr, gde_over_gre);  % fixed-h (Gamma is h-indep.)

    % --- Exclude grazing / geom-invalid / low-DSNR captures from windows --
    exclude = (flag_geom_invalid == 1) | (flag_dsnr_low == 1) | (flag_dsnr_na == 1);
    c_hat(exclude) = NaN;

    % --- Window estimators ------------------------------------------------
    win_hours = getfield_default(cfg, 'sigma0_win_hours', 24);
    min_count = getfield_default(cfg, 'sigma0_min_count', 5);
    S = Hs.window_stats(t, c_hat, K, kg, win_hours, min_count);

    % --- Predicted thermal c_hat variance floor (window mean) -------------
    n_looks = cfg.num_segs * n_band_bins;   % band bins of the SELECTED family
    if ismember(pow1col, L1.Properties.VariableNames) && n_looks > 0
        per_capture_noise = J1.(pow1col) ./ (n_looks .* P_dsig);
        per_capture_noise(~isfinite(c_hat)) = NaN;    % same members as c_var
        c_var_noise_est = window_mean(t, per_capture_noise, win_hours, min_count);
    else
        c_var_noise_est = nan(n, 1);
        fprintf('[sigma0] %s absent (or no MUOS bins) — c_var_noise_est is NaN.\n', pow1col);
    end

    % --- NaN products for geom-invalid rows (Eq. 42 undefined there) ------
    sig0_fixed = S.sigma0(:, 1);
    sig0_snow  = S.sigma0(:, 2);
    gam        = S.gamma;
    gi = flag_geom_invalid == 1;
    sig0_fixed(gi) = NaN;
    sig0_snow(gi)  = NaN;
    gam(gi)        = NaN;

    % --- Assemble output table -------------------------------------------
    out = table( ...
        t, J1.base_name, theta, range_km, r_d, ...
        r1_fixed, r1_snow, Aeff_fixed, Aeff_snow, snow_depth, ...
        h_fixed, h_snow, G_De, G_Re, cal_age_s, P_dsig, dsnr_db, ...
        real(S.c_mean), imag(S.c_mean), S.c_var, c_var_noise_est, ...
        S.n_window, S.n_runs, flag_dsnr_low, flag_dsnr_na, flag_cal_missing, flag_geom_invalid, ...
        sig0_fixed, sig0_snow, gam, ...
        repmat(gd_dbi, n, 1), repmat(gr_dbi, n, 1), repmat(string(fam), n, 1), ...
        repmat(lambda_m, n, 1), ...
        'VariableNames', {'timestamp', 'base_name', 'theta_deg', 'range_km', ...
        'r_d_m', 'r1_fixed_m', 'r1_snow_m', 'Aeff_fixed_m2', 'Aeff_snow_m2', ...
        'snow_depth_m', 'h_fixed_m', 'h_snow_m', 'G_De', 'G_Re', 'cal_age_s', ...
        'P_dsig_adc2', 'dsnr_db', 'c_mean_re', 'c_mean_im', 'c_var', ...
        'c_var_noise_est', 'n_window', 'n_runs', 'flag_dsnr_low', 'flag_dsnr_na', ...
        'flag_cal_missing', 'flag_geom_invalid', 'sigma0_app_lin_fixed_h', ...
        'sigma0_app_lin_snow_h', 'gamma_lin', 'ant_gain_direct_dbi', ...
        'ant_gain_reflected_dbi', 'corr_family', 'lambda_m'});

    % --- Atomic overwrite (temp in the SAME dir, then movefile) ----------
    tmp = [tempname(cfg.out_dir) '.csv'];
    try
        writetable(out, tmp);
        movefile(tmp, out_csv);
    catch ME
        if isfile(tmp), delete(tmp); end
        rethrow(ME);
    end

    fprintf(['[sigma0] %d rows -> %s  (flags: dsnr_low %.1f%%, cal_missing %.1f%%, ' ...
             'geom_invalid %.1f%%; finite sigma0_fixed %d/%d).\n'], ...
            n, out_csv, 100*mean(flag_dsnr_low | flag_dsnr_na), 100*mean(flag_cal_missing), ...
            100*mean(flag_geom_invalid), sum(isfinite(sig0_fixed)), n);
end


% =========================================================================
function [G_De, G_Re, P_DN, cal_age_s, flag_missing] = join_calib(calib_csv, t, tol_hr)
% Nearest-within-tolerance join of calib gains to capture times t (both in the
% capture timebase — no to_utc, matching compute_L2's chain-cal join). Overflow
% rows dropped; timestamps sorted and required unique (post-overflow); only rows
% with finite positive G_De and G_Re kept. Returns per-capture G_De/G_Re/P_DN
% (NaN outside tolerance / when no calib), cal_age_s = |capture - nearest calib|
% in seconds, and flag_missing (1 where gains are NaN).
    n = numel(t);
    G_De = nan(n, 1);  G_Re = nan(n, 1);  P_DN = nan(n, 1);
    cal_age_s = nan(n, 1);  flag_missing = ones(n, 1);

    C = read_stamped(calib_csv);
    need = {'timestamp', 'G_De', 'G_Re'};
    if ~all(ismember(need, C.Properties.VariableNames))
        error('compute_sigma0:calibSchema', ...
              '%s lacks G_De/G_Re — re-run compute_calib.', calib_csv);
    end
    if ismember('overflow_flag', C.Properties.VariableNames)
        C = C(C.overflow_flag == 0, :);
    end
    C = sortrows(C, 'timestamp');
    if numel(unique(C.timestamp)) ~= height(C)
        error('compute_sigma0:calibDupTs', 'Duplicate calib timestamps in %s.', calib_csv);
    end
    ok = isfinite(C.G_De) & C.G_De > 0 & isfinite(C.G_Re) & C.G_Re > 0;
    C  = C(ok, :);
    if isempty(C)
        fprintf('[sigma0] No usable calib rows in %s — gains are NaN.\n', calib_csv);
        return;
    end

    tc = C.timestamp;
    if isscalar(tc)
        idx = ones(n, 1);
    else
        idx = interp1(tc, 1:numel(tc), t, 'nearest', 'extrap');
    end
    dt = abs(t - tc(idx));
    cal_age_s = seconds(dt);
    okc = dt <= hours(tol_hr);

    G_De(okc) = C.G_De(idx(okc));
    G_Re(okc) = C.G_Re(idx(okc));
    if ismember('P_DN', C.Properties.VariableNames)
        P_DN(okc) = C.P_DN(idx(okc));
    end
    flag_missing = double(~okc);
end


% =========================================================================
function xm = window_mean(t, x, win_hours, min_count)
% Mean of x over each centered win_hours window, finite members only; a window
% with < max(min_count, 2) finite members yields NaN. Mirrors the window used
% by sigma0_math.window_stats so c_var_noise_est is comparable to c_var.
    N  = numel(t);
    tn = posixtime(t);
    half_s  = (win_hours / 2) * 3600;
    min_row = max(min_count, 2);
    xm = nan(N, 1);
    fin = isfinite(x);
    for i = 1:N
        in = (abs(tn - tn(i)) <= half_s) & fin;
        if sum(in) >= min_row
            xm(i) = mean(x(in));
        end
    end
end


% =========================================================================
function T = read_stamped(csv_path)
% readtable with the timestamp column normalized to datetime (same style as
% compute_L2): text on read, parsed with the ISO capture format if not already
% datetime.
    T = readtable(csv_path, 'TextType', 'string');
    if ismember('timestamp', T.Properties.VariableNames) && ~isdatetime(T.timestamp)
        T.timestamp = datetime(T.timestamp, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
    end
end


% =========================================================================
function v = getfield_default(s, name, default)
% Return a cfg field or its fallback when absent or empty.
    if isfield(s, name) && ~isempty(s.(name)), v = s.(name); else, v = default; end
end


% =========================================================================
function t_utc = to_utc(t, cfg)
% Convert naive capture timestamps from cfg.capture_tz to naive UTC for
% elevation-table interpolation. UTC or an absent zone is an identity mapping.
    if isfield(cfg, 'capture_tz') && ~isempty(cfg.capture_tz)
        t.TimeZone = cfg.capture_tz;
        t.TimeZone = 'UTC';
        t.TimeZone = '';
    end
    t_utc = t;
end


% =========================================================================
function invalidate_stale(out_csv)
% Stale-output guard for a recompute-full stage: when prerequisites are unmet
% the stage cannot recompute, so an existing product must not stay silently
% consumable. Rename it aside (timestamped _stale_ suffix, data preserved)
% so the viewer reports "no sigma0 CSV" instead of loading stale rows.
    if isfile(out_csv)
        stamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
        stale = strrep(out_csv, '.csv', ['_stale_' stamp '.csv']);
        movefile(out_csv, stale);
        fprintf('[sigma0] Prerequisites unmet — existing %s renamed to %s.\n', ...
                out_csv, stale);
    end
end

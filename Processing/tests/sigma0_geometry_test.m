function tests = sigma0_geometry_test
% Unit + fixture tests for the direct-referenced sigma0 (+ Gamma) stage.
%
% Two layers:
%   (1) Pure math (lib/sigma0_math.m) — closed-form geometry, prefactor formulas,
%       window_stats exactness, a varying-geometry regression that is the primary
%       correctness gate for the estimator, and the ADC/EIRP/phase-wrap
%       invariances that guard the c_hat = C/P_dsig construction.
%   (2) Fixture-driven end-to-end (stages/compute_sigma0.m) — tiny synthetic
%       L1/L2/calib + elevation CSVs drive the stage through its schema, guard,
%       calib-join, and atomic-overwrite behavior.
%
% Deterministic: any pseudo-random scatter uses a fixed rng seed AND is
% normalized to unit empirical variance so tolerances are set by the
% finite-window estimator residual, not by sampling noise.
%
% Run (from Processing/):
%   matlab -batch "soop_setup_paths; runtests('tests/sigma0_geometry_test')"

    tests = functiontests(localfunctions);
end


% =========================================================================
% A. Closed-form geometry
% =========================================================================
function test_r1_reflected_path(tc)
% r1 = h / sin(e): zenith -> h, e = 30 deg -> 2h.
    H = sigma0_math();
    verifyEqual(tc, H.r1(6.096, 90), 6.096,  'AbsTol', 1e-12);
    verifyEqual(tc, H.r1(6.096, 30), 12.192, 'AbsTol', 1e-12);
end

function test_fresnel_zone_axes_and_area(tc)
% First Fresnel zone (Larson & Nievinski 2013): d = lambda/2, s = sin(e),
% b = sqrt(2 d h / s + (d/s)^2), a = b/s, A_eff = pi a b.
    H = sigma0_math();
    lambda = 0.8102;  h = 6.096;  d = lambda / 2;

    % e = 90 deg (s = 1): a == b, A_eff == pi b^2, center offset R == 0
    % (tand(90) = Inf exactly).
    [Aeff, a, b, R] = H.fresnel(lambda, h, 90);
    b_expected = sqrt(2 * d * h + d^2);
    verifyEqual(tc, b,    b_expected,          'RelTol', 1e-12);
    verifyEqual(tc, a,    b,                   'RelTol', 1e-12);
    verifyEqual(tc, Aeff, pi * b_expected^2,   'RelTol', 1e-12);
    verifyEqual(tc, R,    0,                   'AbsTol', 1e-12);

    % e = 30 deg: a == b / sin(30); R = h/tan(e) + (d/sin(e))/tan(e).
    [~, a30, b30, R30] = H.fresnel(lambda, h, 30);
    verifyEqual(tc, a30, b30 / sind(30), 'RelTol', 1e-12);
    verifyEqual(tc, R30, h / tand(30) + (d / sind(30)) / tand(30), 'RelTol', 1e-12);
end


% =========================================================================
% B. Prefactor formulas (hand-transcribed closed forms)
% =========================================================================
function test_prefactor_formulas(tc)
    H = sigma0_math();
    r1 = 10;  r2 = 3e7;  rd = 3e7;  gdr = 2;  gder = 1.5;  Aeff = 500;

    k_sig_expected = 4*pi * (r1 * r2 / rd)^2 * gdr * gder / Aeff;
    k_gam_expected = ((r1 + r2) / rd)^2 * gdr * gder;

    verifyEqual(tc, H.k_sigma0(r1, r2, rd, gdr, gder, Aeff), k_sig_expected, 'RelTol', 1e-12);
    verifyEqual(tc, H.k_gamma(r1, r2, rd, gdr, gder),        k_gam_expected, 'RelTol', 1e-12);
end


% =========================================================================
% C. window_stats exactness (hand-built series)
% =========================================================================
function test_window_cmean_cvar_boundary(tc)
% Centered window, inclusive |dt| <= win/2 boundary, 1/(N-1) complex variance,
% and n_window bookkeeping. win_hours = 4 -> row at t=2h includes t in [0,4].
    H = sigma0_math();
    [t, c_hat, K, kg] = build_window_series();

    S = H.window_stats(t, c_hat, K, kg, 4, 3);

    % Row 3 (t = 2 h): members {1..5} (t = 0..4); t=0 and t=4 at |dt| = 2 h
    % (= win/2) are INCLUDED, t=5 excluded -> n_window = 5.
    verifyEqual(tc, S.n_window(3), 5);
    % cb = mean of c_hat(1:5) = (10 + 10i)/5 = 2 + 2i.
    verifyEqual(tc, S.c_mean(3), 2 + 2i, 'AbsTol', 1e-12);
    % sum|res|^2 = 18 -> c_var = 18/(5-1) = 4.5.
    verifyEqual(tc, S.c_var(3), 4.5, 'AbsTol', 1e-12);
end

function test_window_sigma0_nan_prefactor_excluded(tc)
% Per-variant sigma0 excludes a NaN-prefactor member from BOTH the weighted sum
% and the (nm-1) count. Variant 2 has K(4,2)=NaN.
    H = sigma0_math();
    [t, c_hat, K, kg] = build_window_series();

    S = H.window_stats(t, c_hat, K, kg, 4, 3);

    % Variant 1: all K=1 over {1..5} -> sigma0 == c_var == 4.5.
    verifyEqual(tc, S.sigma0(3, 1), 4.5, 'AbsTol', 1e-12);
    % Variant 2: idx 4 (res^2 = 8) dropped -> sum = 1+5+0+4 = 10, nm = 4,
    % sigma0 = 10/(4-1) = 10/3.
    verifyEqual(tc, S.sigma0(3, 2), 10/3, 'AbsTol', 1e-12);
end

function test_window_gamma_nan_kg_excluded(tc)
% Gamma = |mean(sqrt(kg).*c_hat)|^2 over finite-kg members. With kg all 1,
% gamma(3) = |cb|^2 = 8. With kg(4)=NaN, member 4 drops -> gamma = 8.5.
    H = sigma0_math();
    [t, c_hat, K, kg] = build_window_series();

    S = H.window_stats(t, c_hat, K, kg, 4, 3);
    verifyEqual(tc, S.gamma(3), 8, 'AbsTol', 1e-12);      % |2+2i|^2

    kg2 = kg;  kg2(4) = NaN;
    S2 = H.window_stats(t, c_hat, K, kg2, 4, 3);
    % members {1,2,3,5}: mean = (7 + 6i)/4 = 1.75 + 1.5i -> |.|^2 = 8.5.
    verifyEqual(tc, S2.gamma(3), 8.5, 'AbsTol', 1e-12);
end

function test_window_min_count_nan_row_emitted(tc)
% n_window < max(min_count,2) -> products NaN but the row is still emitted with
% its n_window recorded. Row 3 has 5 members; min_count = 6 forces NaN.
    H = sigma0_math();
    [t, c_hat, K, kg] = build_window_series();

    S = H.window_stats(t, c_hat, K, kg, 4, 6);
    verifyEqual(tc, S.n_window(3), 5);          % still counted
    verifyTrue(tc, isnan(S.c_var(3)));
    verifyTrue(tc, isnan(S.sigma0(3, 1)));
    verifyTrue(tc, isnan(S.gamma(3)));
end

function test_window_n_runs_gap_split(tc)
% n_runs splits contiguous runs on a > 1 h gap. Row 7 (t=6.5h) window {t=5,6.5,8}
% has two 1.5 h gaps -> 3 runs. Row 3 window (t=0..4, all 1 h gaps) -> 1 run.
    H = sigma0_math();
    [t, c_hat, K, kg] = build_window_series();

    S = H.window_stats(t, c_hat, K, kg, 4, 3);
    verifyEqual(tc, S.n_runs(3), 1);
    verifyEqual(tc, S.n_window(7), 3);
    verifyEqual(tc, S.n_runs(7), 3);
end


% =========================================================================
% D. Varying-geometry regression (primary correctness gate)
% =========================================================================
function test_varying_geometry_sigma0_recovery(tc)
% Season with a DOMINANT static coherent component + small scatter whose
% z-space (post-prefactor) variance is a KNOWN CONSTANT sigma0_true, under
% STRONGLY varying prefactors K(i) (factor-of-3 daily cycle). Per-capture
% prefactor application must recover sigma0_true; the naive "K_center * c_var"
% estimator must NOT (K varies within the window).
    H = sigma0_math();
    N = 200;
    off_h = (0:N-1)' * 2;                        % captures 2 h apart (~16.7 d)
    t = datetime(2026,1,1,0,0,0) + hours(off_h);

    sigma0_true = 1e-2;
    coh = 5 + 3i;                                % |coh|^2 = 34 >> scatter power
    K = 2 + cos(2*pi * off_h / 24);              % in [1, 3], factor-of-3 sweep

    rng(42);
    eps = (randn(N,1) + 1i*randn(N,1)) / sqrt(2);
    eps = eps / sqrt(mean(abs(eps).^2));         % empirical unit variance, exactly

    % z-space incoherent variance K*|c_hat-<c_hat>|^2 has expectation sigma0_true
    % for every capture regardless of K.
    c_hat = coh + sqrt(sigma0_true ./ K) .* eps;

    S = H.window_stats(t, c_hat, K, K, 24, 5);

    good = isfinite(S.sigma0(:,1));
    est  = mean(S.sigma0(good, 1));
    rel_err = abs(est - sigma0_true) / sigma0_true;
    verifyLessThan(tc, rel_err, 0.05, ...
        sprintf('sigma0 recovery rel err %.4f (est %.4g vs %.4g)', rel_err, est, sigma0_true));

    % Naive contrast (optional sanity): K_center * c_var swings with the row's
    % own prefactor and is far off for some rows.
    naive = K(good) .* S.c_var(good);
    naive_max_rel = max(abs(naive - sigma0_true) / sigma0_true);
    verifyGreaterThan(tc, naive_max_rel, 0.25, ...
        'naive K_center*c_var should be strongly biased for a factor-3 sweep');
end

function test_varying_geometry_gamma_recovery(tc)
% Constant injected Gamma_true via z_gamma scaling: c_hat_i carries a coherent
% term sqrt(Gamma_true/kg_i)*exp(i*phi0), so z_gamma = sqrt(kg)*c_hat has a
% capture-independent coherent part. gamma = |mean(z_gamma)|^2 -> Gamma_true
% despite a factor-of-3 kg sweep.
    H = sigma0_math();
    N = 200;
    off_h = (0:N-1)' * 2;
    t = datetime(2026,1,1,0,0,0) + hours(off_h);

    Gamma_true = 34;
    phi0 = 0.5;
    kg = 2 + cos(2*pi * off_h / 24);             % factor-of-3 sweep
    sigma0_small = 1e-4;

    rng(7);
    eps = (randn(N,1) + 1i*randn(N,1)) / sqrt(2);
    eps = eps / sqrt(mean(abs(eps).^2));

    c_hat = sqrt(Gamma_true ./ kg) .* exp(1j*phi0) + sqrt(sigma0_small ./ kg) .* eps;

    S = H.window_stats(t, c_hat, [kg kg], kg, 24, 5);

    good = isfinite(S.gamma);
    est  = mean(S.gamma(good));
    rel_err = abs(est - Gamma_true) / Gamma_true;
    verifyLessThan(tc, rel_err, 0.02, ...
        sprintf('gamma recovery rel err %.4f (est %.4g vs %.4g)', rel_err, est, Gamma_true));
end


% =========================================================================
% E. EIRP-fluctuation invariance (per-capture C and P_dsig scaled together)
% =========================================================================
function test_eirp_fluctuation_invariance(tc)
% Scaling C_i and P_dsig_i by the same per-capture factor g_i (MUOS power
% control) leaves c_hat = C/P_dsig unchanged -> identical products. Powers of
% two keep the scaling bit-exact.
    H = sigma0_math();
    [t, ~, K, kg] = build_window_series();
    N = numel(t);

    amp   = (1:N)' + 5;
    phase = deg2rad((10:10:10*N)');
    C     = amp .* exp(1j*phase);
    P     = (2:N+1)' * 1e3;

    g = 2 .^ (mod((1:N)', 7) - 3);               % per-capture powers of two
    c_hat_base   = C ./ P;
    c_hat_scaled = (g .* C) ./ (g .* P);

    verifyEqual(tc, c_hat_scaled, c_hat_base);   % bit-exact (g is a power of 2)

    S1 = H.window_stats(t, c_hat_base,   K, kg, 4, 3);
    S2 = H.window_stats(t, c_hat_scaled, K, kg, 4, 3);
    verifyEqual(tc, S2.sigma0, S1.sigma0);
    verifyEqual(tc, S2.gamma,  S1.gamma);
    verifyEqual(tc, S2.c_var,  S1.c_var);
end


% =========================================================================
% F. ADC-scale invariance (global g^2 on C and channel powers)
% =========================================================================
function test_adc_scale_invariance(tc)
% A global ADC gain scales C ~ g^2 and P_dsig ~ g^2, so c_hat = C/P_dsig is
% unchanged and the products are identical. Power-of-two g^2 -> bit-exact.
    H = sigma0_math();
    [t, ~, K, kg] = build_window_series();
    N = numel(t);

    amp   = (3:N+2)';
    phase = deg2rad((0:15:15*(N-1))');
    C     = amp .* exp(1j*phase);
    P     = (5:N+4)' * 1e2;

    g2 = 2^6;                                    % global ADC^2 gain, power of two
    c_hat_base   = C ./ P;
    c_hat_scaled = (g2 .* C) ./ (g2 .* P);

    verifyEqual(tc, c_hat_scaled, c_hat_base);

    S1 = H.window_stats(t, c_hat_base,   K, kg, 4, 3);
    S2 = H.window_stats(t, c_hat_scaled, K, kg, 4, 3);
    verifyEqual(tc, S2.sigma0, S1.sigma0);
    verifyEqual(tc, S2.gamma,  S1.gamma);
end


% =========================================================================
% G. Phase-wrap invariance (+179 vs -181 deg, +/- 360k)
% =========================================================================
function test_phase_wrap_invariance(tc)
% Building c_hat via amp.*exp(1j*deg2rad(phase)) makes phases differing by a
% whole number of turns produce the same complex sample (to machine precision),
% guarding the complex-phasor mean path.
    H = sigma0_math();
    [t, ~, K, kg] = build_window_series();
    N = numel(t);

    amp = (1:N)';
    ph_a = repmat(179,  N, 1);
    ph_b = repmat(-181, N, 1);                   % 179 - 360
    ph_c = 179 + 360 * (mod((1:N)', 3) - 1);     % 179 +/- 360k

    z_a = amp .* exp(1j*deg2rad(ph_a));
    z_b = amp .* exp(1j*deg2rad(ph_b));
    z_c = amp .* exp(1j*deg2rad(ph_c));

    verifyEqual(tc, z_b, z_a, 'AbsTol', 1e-12);
    verifyEqual(tc, z_c, z_a, 'AbsTol', 1e-12);

    P  = (2:N+1)';
    Sa = H.window_stats(t, z_a ./ P, K, kg, 4, 3);
    Sb = H.window_stats(t, z_b ./ P, K, kg, 4, 3);
    verifyEqual(tc, Sb.gamma,  Sa.gamma,  'RelTol', 1e-9);
    verifyEqual(tc, Sb.sigma0, Sa.sigma0, 'RelTol', 1e-9);
end


% =========================================================================
% H. Fixture-driven end-to-end compute_sigma0
% =========================================================================
function test_e2e_schema_guards_roundtrip(tc)
% Full stage run: 34-column schema in order (flag_dsnr_na present), row count,
% ISO timestamp round-trip, grazing -> flag_geom_invalid + NaN products,
% no-calib -> flag_cal_missing + flag_dsnr_na (P_DN unavailable) + NaN gains,
% and finite products (and flag_dsnr_na = 0) on a clean row.
    [L1, L2, CAL, ELEV] = happy_tables();
    [~, cfg, t_in] = write_fixture(tc, L1, L2, CAL, ELEV);

    compute_sigma0(cfg);

    out_csv = fullfile(cfg.out_dir, 'BrundageSoOp_sigma0.csv');
    verifyTrue(tc, isfile(out_csv), 'output CSV was not written');

    OUT = readtable(out_csv, 'TextType', 'string');
    verifyEqual(tc, OUT.Properties.VariableNames, sigma0_schema());
    verifyEqual(tc, height(OUT), height(L1));

    % ISO timestamp round-trip (sorted by time in the output).
    ts_out = datetime(OUT.timestamp, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
    verifyEqual(tc, ts_out, sort(t_in), 'AbsTol', seconds(0.5));

    % Grazing capture (cap5, theta = 2 deg): geom-invalid flag + NaN products.
    ig = OUT.base_name == "cap5";
    verifyEqual(tc, OUT.flag_geom_invalid(ig), 1);
    verifyTrue(tc, isnan(OUT.sigma0_app_lin_fixed_h(ig)));
    verifyTrue(tc, isnan(OUT.sigma0_app_lin_snow_h(ig)));
    verifyTrue(tc, isnan(OUT.gamma_lin(ig)));

    % Cal-missing capture (cap8, > tolerance from any calib): flag + NaN gains.
    % With no calib P_DN the DSNR guard is unassessable -> flag_dsnr_na = 1.
    im = OUT.base_name == "cap8";
    verifyEqual(tc, OUT.flag_cal_missing(im), 1);
    verifyEqual(tc, OUT.flag_dsnr_na(im), 1);
    verifyTrue(tc, isnan(OUT.G_De(im)));

    % A clean interior row (cap4) yields finite products and is assessable.
    ic = OUT.base_name == "cap4";
    verifyEqual(tc, OUT.flag_dsnr_na(ic), 0);
    verifyEqual(tc, OUT.flag_dsnr_low(ic), 0);
    verifyTrue(tc, isfinite(OUT.sigma0_app_lin_fixed_h(ic)));
    verifyTrue(tc, isfinite(OUT.gamma_lin(ic)));

    % No snow data (no cfg.wx_dat) -> snow columns are NaN.
    verifyTrue(tc, all(isnan(OUT.snow_depth_m)));
end

function test_e2e_duplicate_base_name_errors(tc)
% Duplicate base_name in L1 -> compute_sigma0:dupL1.
    [L1, L2, CAL, ELEV] = happy_tables();
    L1 = [L1; L1(1, :)];                          % duplicate first base_name
    [~, cfg] = write_fixture(tc, L1, L2, CAL, ELEV);
    verifyError(tc, @() compute_sigma0(cfg), 'compute_sigma0:dupL1');
end


% =========================================================================
% I. Calib-join rules (tolerance boundary + invalid-gain rows ignored)
% =========================================================================
function test_e2e_calib_join_rules(tc)
% Captures straddle the nearest-within-tolerance boundary (default 1 h): inside
% rows get finite gains + cal_age_s, outside rows get NaN gains +
% flag_cal_missing. Negative/nonfinite-gain calib rows are ignored, so captures
% near them fall back to the far valid calib and read as missing.
    t0 = datetime(2026,1,1,0,0,0);
    off_h = [0; 0.9; 1.0; 1.1; 2.4; 3.0];        % capture offsets (h)
    N = numel(off_h);
    t = t0 + hours(off_h);
    bn = "cap" + string((1:N)');

    L1 = table(t, bn, repmat(1000,N,1), repmat(1e6,N,1), repmat(1e5,N,1), ...
        'VariableNames', {'timestamp','base_name','peak_amplitude_fd_muos', ...
                          'pow_ch0_fd_muos','pow_ch1_fd_muos'});
    L2 = table(t, bn, repmat(40,N,1), zeros(N,1), ...
        'VariableNames', {'timestamp','base_name','theta_deg','phase_corr_cal_fd_muos_deg'});

    % Valid calib at 0 and 5 h; a negative-gain row at 2.5 h and a NaN-gain row
    % at 3.0 h that MUST be dropped.
    ct = t0 + hours([0; 2.5; 3.0; 5.0]);
    CAL = table(ct, [100; -1; 100; 100], [50; 50; NaN; 50], [1;1;1;1], [0;0;0;0], ...
        'VariableNames', {'timestamp','G_De','G_Re','P_DN','overflow_flag'});

    ELEV = elev_table(t0);
    [~, cfg] = write_fixture(tc, L1, L2, CAL, ELEV);

    compute_sigma0(cfg);
    OUT = readtable(fullfile(cfg.out_dir, 'BrundageSoOp_sigma0.csv'), 'TextType', 'string');
    OUT = sortrows(OUT, 'base_name');            % cap1..cap6 order

    inside  = [true;  true;  true;  false; false; false];
    verifyEqual(tc, OUT.flag_cal_missing, double(~inside));
    verifyTrue(tc, all(isfinite(OUT.G_De(inside))));
    verifyTrue(tc, all(OUT.G_De(inside) == 100));
    verifyTrue(tc, all(isnan(OUT.G_De(~inside))));
    % Inside cal_age_s equals |capture - nearest valid calib (t=0)|.
    verifyEqual(tc, OUT.cal_age_s(1:3), [0; 0.9; 1.0] * 3600, 'AbsTol', 1e-6);
end


% =========================================================================
% J. Atomic-overwrite behavior
% =========================================================================
function test_e2e_atomic_overwrite(tc)
% Running the stage twice into the same dir overwrites cleanly: the output is
% readable with the full schema and NO stray temp CSV is left behind.
    [L1, L2, CAL, ELEV] = happy_tables();
    [d, cfg] = write_fixture(tc, L1, L2, CAL, ELEV);

    compute_sigma0(cfg);
    compute_sigma0(cfg);

    out_csv = fullfile(d, 'BrundageSoOp_sigma0.csv');
    verifyTrue(tc, isfile(out_csv));
    OUT = readtable(out_csv, 'TextType', 'string');
    verifyEqual(tc, OUT.Properties.VariableNames, sigma0_schema());

    % Only the four inputs + the elevation table + the one output remain.
    listing = dir(fullfile(d, '*.csv'));
    got = sort(string({listing.name}'));
    want = sort(["BrundageSoOp_L1_sig.csv"; "BrundageSoOp_L2.csv"; ...
                 "BrundageSoOp_calib.csv"; "muos_elev.csv"; "BrundageSoOp_sigma0.csv"]);
    verifyEqual(tc, got, want, 'stray temp CSV left in the output dir');
end


% =========================================================================
% K. Stale-output invalidation + calib-absent product (Codex F1)
% =========================================================================
function test_e2e_stale_output_invalidated(tc)
% Codex F1 regression: a recompute-full stage must never leave a stale product
% consumable when a prerequisite disappears. Produce finite output, then remove
% the L1 CSV and re-run: the canonical BrundageSoOp_sigma0.csv must be renamed
% aside (_stale_<stamp>) so nothing finite is loadable under the canonical name.
    [L1, L2, CAL, ELEV] = happy_tables();
    [d, cfg] = write_fixture(tc, L1, L2, CAL, ELEV);

    compute_sigma0(cfg);
    out_csv = fullfile(d, 'BrundageSoOp_sigma0.csv');
    verifyTrue(tc, isfile(out_csv), 'first run should write the product');
    OUT0 = readtable(out_csv, 'TextType', 'string');
    verifyTrue(tc, any(isfinite(OUT0.sigma0_app_lin_fixed_h)), ...
        'first run should have at least one finite product');

    % Prerequisite gone: delete the L1 CSV and re-run.
    delete(fullfile(d, 'BrundageSoOp_L1_sig.csv'));
    compute_sigma0(cfg);

    % Canonical name must be GONE (renamed to a timestamped _stale_ file); no
    % finite stale product survives under the name the viewer loads.
    verifyFalse(tc, isfile(out_csv), ...
        'stale product still loadable under the canonical name');
    stale = dir(fullfile(d, 'BrundageSoOp_sigma0_stale_*.csv'));
    verifyEqual(tc, numel(stale), 1, 'exactly one _stale_ file expected');
    % The renamed file preserves the original finite product (data not lost).
    OUTs = readtable(fullfile(d, stale(1).name), 'TextType', 'string');
    verifyEqual(tc, OUTs.Properties.VariableNames, sigma0_schema());
    verifyTrue(tc, any(isfinite(OUTs.sigma0_app_lin_fixed_h)));
end

function test_e2e_calib_absent_products_nan(tc)
% Codex F1: a method dir WITHOUT BrundageSoOp_calib.csv (e.g. rfi_apply_calib
% = false writes calib only in the base dir) must still WRITE a product: NaN
% gains + flag_cal_missing = 1, unassessable DSNR (flag_dsnr_na = 1) so science
% products are NaN, while geometry columns stay finite and the rows are kept.
    [L1, L2, CAL, ELEV] = happy_tables();
    L2.theta_deg(:) = 40;                         % all valid geometry (no grazing)
    [d, cfg] = write_fixture(tc, L1, L2, CAL, ELEV);
    delete(fullfile(d, 'BrundageSoOp_calib.csv'));  % no calib in this method dir

    compute_sigma0(cfg);
    out_csv = fullfile(d, 'BrundageSoOp_sigma0.csv');
    verifyTrue(tc, isfile(out_csv), 'product must be written even with no calib');
    OUT = readtable(out_csv, 'TextType', 'string');

    verifyEqual(tc, height(OUT), height(L1));
    verifyTrue(tc, all(OUT.flag_cal_missing == 1));
    verifyTrue(tc, all(isnan(OUT.G_De)) && all(isnan(OUT.G_Re)));
    verifyTrue(tc, all(OUT.flag_dsnr_na == 1), 'no P_DN -> DSNR unassessable');
    verifyTrue(tc, all(isnan(OUT.sigma0_app_lin_fixed_h)));
    verifyTrue(tc, all(isnan(OUT.sigma0_app_lin_snow_h)));
    verifyTrue(tc, all(isnan(OUT.gamma_lin)));
    % Geometry columns remain finite (all captures now have valid geometry).
    verifyTrue(tc, all(isfinite(OUT.theta_deg)));
    verifyTrue(tc, all(isfinite(OUT.range_km)));
    verifyTrue(tc, all(isfinite(OUT.r_d_m)));
    verifyTrue(tc, all(isfinite(OUT.r1_fixed_m)));
    verifyTrue(tc, all(isfinite(OUT.Aeff_fixed_m2)));
end


% =========================================================================
% L. DSNR guard: P_DN edge cases (Codex F4)
% =========================================================================
function test_e2e_dsnr_pdn_edge_cases(tc)
% Codex F4: the DSNR ratio-estimator guard must treat P_DN = 0 / negative / NaN
% as UNASSESSABLE (dsnr_db NaN, flag_dsnr_na = 1, excluded), an ordinary
% positive P_DN as assessable, and an assessable capture whose direct power does
% not exceed the noise estimate as definitively low (dsnr_db = -Inf,
% flag_dsnr_low = 1). One coincident calib row per capture carries its P_DN.
    t0 = datetime(2026,1,1,0,0,0);
    off_h = (0:4)';                              % 0..4 h, within elev_table span
    N = numel(off_h);
    t = t0 + hours(off_h);
    bn = "cap" + string((1:N)');

    P_DN    = [0; -5; NaN; 1;   1e12];           % edge cases per capture
    pow_ch0 = [1e6;1e6;1e6;1e6; 1   ];           % cap5 tiny -> P_dsig < P_noise

    L1 = table(t, bn, repmat(1000,N,1), pow_ch0, repmat(1e5,N,1), ...
        'VariableNames', {'timestamp','base_name','peak_amplitude_fd_muos', ...
                          'pow_ch0_fd_muos','pow_ch1_fd_muos'});
    L2 = table(t, bn, repmat(40,N,1), zeros(N,1), ...
        'VariableNames', {'timestamp','base_name','theta_deg','phase_corr_cal_fd_muos_deg'});
    % One calib row coincident with each capture (dt = 0 < 1 h tol) so each
    % capture's nearest calib carries its own P_DN. G_De/G_Re finite+positive so
    % every calib row is kept (only P_DN varies, incl. non-positive / NaN).
    CAL = table(t, repmat(100,N,1), repmat(50,N,1), P_DN, zeros(N,1), ...
        'VariableNames', {'timestamp','G_De','G_Re','P_DN','overflow_flag'});
    ELEV = elev_table(t0);

    [d, cfg] = write_fixture(tc, L1, L2, CAL, ELEV);
    compute_sigma0(cfg);
    OUT = readtable(fullfile(d, 'BrundageSoOp_sigma0.csv'), 'TextType', 'string');
    OUT = sortrows(OUT, 'base_name');            % cap1..cap5

    % cap1..cap3: P_DN 0 / -5 / NaN -> unassessable (na, not "low", dsnr NaN).
    verifyEqual(tc, OUT.flag_dsnr_na(1:3),  [1;1;1]);
    verifyEqual(tc, OUT.flag_dsnr_low(1:3), [0;0;0]);
    verifyTrue(tc, all(isnan(OUT.dsnr_db(1:3))));
    % cap4: ordinary positive P_DN, strong signal -> assessable-high, exact dsnr.
    verifyEqual(tc, OUT.flag_dsnr_na(4),  0);
    verifyEqual(tc, OUT.flag_dsnr_low(4), 0);
    verifyTrue(tc, isfinite(OUT.dsnr_db(4)));
    dsnr4 = expected_dsnr_local(cfg, pow_ch0(4), P_DN(4), 'fd_muos');
    verifyEqual(tc, OUT.dsnr_db(4), dsnr4, 'RelTol', 1e-9);
    % cap5: assessable but direct power below the noise estimate -> -Inf, low.
    verifyEqual(tc, OUT.flag_dsnr_na(5),  0);
    verifyEqual(tc, OUT.flag_dsnr_low(5), 1);
    verifyEqual(tc, OUT.dsnr_db(5), -Inf);
end


% =========================================================================
% M. Family-band consistency: fd_muos (MUOS bins) vs fd (full band) — Codex F3
% =========================================================================
function test_e2e_family_band_fd_vs_fdmuos(tc)
% Codex F3: the DSNR noise floor P_noise = NG*f_band*P_DN must use the band of
% the SELECTED family — f_band = 1 for the full-band fd/td families, f_band =
% (# MUOS bins)/npts for fd_muos. Same fixture, same P_dsig and P_DN; only the
% family changes. The MUOS band is narrower (lower noise floor -> higher DSNR),
% so P_dsig is placed at the geometric mean of the two families' 10 dB break
% points: fd lands BELOW the guard, fd_muos ABOVE — a discriminating flag flip
% that the pre-fix MUOS-bandwidth-for-fd bug would get wrong.
    t0 = datetime(2026,1,1,0,0,0);
    off_h = (0:4)';
    N = numel(off_h);
    t = t0 + hours(off_h);
    bn = "cap" + string((1:N)');

    % Match write_fixture's cheap-FFT params so npts / f_muos are the stage's.
    fs = 2e6;  Ti = 0.001;  freq_hz = 370e6;  muos_bands = 1e6*[369.5 370.5];
    npts = floor(fs*Ti);
    win  = 0.5*(1 - cos(2*pi*(0:npts-1)'/(npts-1)));
    NG   = mean(win.^2);
    f_muos = sum(rfi_excise().band_mask(muos_bands, freq_hz, fs, npts)) / npts;

    P_DN = 1e6;
    lo = 11*NG*f_muos*P_DN;      % dsnr = 10 dB break point for fd_muos
    hi = 11*NG*1     *P_DN;      % dsnr = 10 dB break point for fd
    P_common = sqrt(lo*hi);      % between them -> straddles the guard

    L1 = table(t, bn, repmat(1000,N,1), repmat(P_common,N,1), repmat(P_common,N,1), ...
                       repmat(1000,N,1), repmat(P_common,N,1), repmat(0.5*P_common,N,1), ...
        'VariableNames', {'timestamp','base_name', ...
            'peak_amplitude_fd','pow_ch0_fd','pow_ch1_fd', ...
            'peak_amplitude_fd_muos','pow_ch0_fd_muos','pow_ch1_fd_muos'});
    L2 = table(t, bn, repmat(40,N,1), zeros(N,1), zeros(N,1), ...
        'VariableNames', {'timestamp','base_name','theta_deg', ...
                          'phase_corr_cal_fd_deg','phase_corr_cal_fd_muos_deg'});
    CAL = table(t, repmat(100,N,1), repmat(50,N,1), repmat(P_DN,N,1), zeros(N,1), ...
        'VariableNames', {'timestamp','G_De','G_Re','P_DN','overflow_flag'});
    ELEV = elev_table(t0);

    [d, cfg] = write_fixture(tc, L1, L2, CAL, ELEV);

    cfg.sigma0_corr_family = 'fd_muos';
    compute_sigma0(cfg);
    OUTm = readtable(fullfile(d,'BrundageSoOp_sigma0.csv'), 'TextType', 'string');

    cfg.sigma0_corr_family = 'fd';
    compute_sigma0(cfg);
    OUTf = readtable(fullfile(d,'BrundageSoOp_sigma0.csv'), 'TextType', 'string');

    % Exact per-family DSNR proves the family-specific f_band was used.
    dsnr_m = expected_dsnr_local(cfg, P_common, P_DN, 'fd_muos');
    dsnr_f = expected_dsnr_local(cfg, P_common, P_DN, 'fd');
    verifyEqual(tc, OUTm.dsnr_db(1), dsnr_m, 'RelTol', 1e-9);
    verifyEqual(tc, OUTf.dsnr_db(1), dsnr_f, 'RelTol', 1e-9);
    verifyGreaterThan(tc, dsnr_m, dsnr_f);       % narrower band -> lower noise floor

    % Discriminating flag flip across the 10 dB guard.
    verifyEqual(tc, OUTm.flag_dsnr_low(1), 0);   % fd_muos assessable-high (included)
    verifyEqual(tc, OUTf.flag_dsnr_low(1), 1);   % fd assessable-low (excluded)
    verifyEqual(tc, OUTm.flag_dsnr_na(1),  0);
    verifyEqual(tc, OUTf.flag_dsnr_na(1),  0);
end


% =========================================================================
% N. Ratio-estimator bias + noise-floor validation (disposition 8, pure math)
% =========================================================================
function test_ratio_estimator_bias_montecarlo(tc)
% The direct-referenced observable c_hat = C / P_dsig is a RATIO estimator. With
% P_dsig = P_true*(1 + eps_d) and eps_d a zero-mean relative direct-power noise
% (std CV), the denominator u = 1/(1+eps_d) has, for eps ~ N(0, CV^2),
%   mu_u = E[u]   = 1 + CV^2 + 3 CV^4              (>1: inflates c_hat)
%   Eu2  = E[u^2] = 1 + 3 CV^2 + 15 CV^4.
% "DSNR = 10 dB equivalent" -> linear DSNR = 10, CV = 1/DSNR_lin = 0.1. Leading-
% order bias of the two products (coh = constant coherent part, scat = zero-mean
% incoherent scatter with E|scat|^2 = sigma0_true, independent of u):
%   var(c_hat) = (|coh|^2 + sigma0_true) Eu2 - |coh|^2 mu_u^2
%   sigma0 = <|c_hat-<c_hat>|^2>  (1/(N-1) sample var, unbiased) -> var(c_hat)
%   Gamma  = |<c_hat>|^2 = |E[cb]|^2 + var(cb)
%          = |coh|^2 mu_u^2   [DENOMINATOR/ratio bias, ~1 + 2 CV^2]
%          + var(c_hat)/N     [finite-window mean-square bias].
% Both biases are POSITIVE. Monte-Carlo M windows of N captures and compare the
% measured relative bias to these closed forms (margin covers finite-M sampling
% noise + the dropped O(CV^4) terms).
    rng(20260716);
    M = 2000;  N = 20;
    CV = 0.1;                                    % DSNR 10 dB -> 1/10
    sigma0_true = 1.0;                           % E|scat|^2 per capture (K = 1)
    coh = 1 + 0i;                                % gamma_true = |coh|^2 = 1

    scat  = sqrt(sigma0_true) * (randn(N,M) + 1i*randn(N,M)) / sqrt(2);
    eps_d = CV * randn(N,M);
    c_hat = (coh + scat) ./ (1 + eps_d);         % ratio estimator

    cb          = mean(c_hat, 1);                % 1 x M coherent means
    gamma_est   = abs(cb).^2;
    sigma0_est  = sum(abs(c_hat - cb).^2, 1) / (N - 1);
    gamma_meas  = mean(gamma_est);
    sigma0_meas = mean(sigma0_est);

    mu_u = 1 + CV^2 + 3*CV^4;
    Eu2  = 1 + 3*CV^2 + 15*CV^4;
    var_chat = (abs(coh)^2 + sigma0_true)*Eu2 - abs(coh)^2*mu_u^2;

    gamma_denom_bias   = mu_u^2 - 1;             % ~ 2 CV^2 (ratio/denominator part)
    gamma_bias_theory  = (abs(coh)^2*mu_u^2 + var_chat/N)/abs(coh)^2 - 1;
    sigma0_bias_theory = var_chat/sigma0_true - 1;

    gamma_bias_meas  = gamma_meas  / abs(coh)^2 - 1;
    sigma0_bias_meas = sigma0_meas / sigma0_true - 1;

    % The documented ratio/denominator piece is the leading ~2 CV^2 term
    % (mu_u^2 - 1 = 2 CV^2 + O(CV^4)).
    verifyEqual(tc, gamma_denom_bias, 2*CV^2, 'AbsTol', 1e-3);
    % Bias is upward (positive) and matches theory within the MC + O(CV^4) margin.
    verifyGreaterThan(tc, gamma_bias_meas,  0);
    verifyGreaterThan(tc, sigma0_bias_meas, 0);
    verifyEqual(tc, gamma_bias_meas,  gamma_bias_theory,  'AbsTol', 0.015, ...
        sprintf('gamma bias %.4f vs theory %.4f',  gamma_bias_meas,  gamma_bias_theory));
    verifyEqual(tc, sigma0_bias_meas, sigma0_bias_theory, 'AbsTol', 0.02, ...
        sprintf('sigma0 bias %.4f vs theory %.4f', sigma0_bias_meas, sigma0_bias_theory));
end

function test_noise_floor_validation(tc)
% Validate the c_var_noise_est floor  var(c_hat) = var(C/P_D) ~ P_R/(n_looks*P_D)
% against a DIRECT simulation of the cross-spectral estimator with coh = 0
% (independent D, R), then confirm signal+noise adds variances.
    rng(20260716);
    P_D = 4;  P_R = 2;  n_looks = 50;  n_cap = 4000;
    v_pred = P_R / (n_looks * P_D);              % predicted c_hat variance floor

    % Each capture: C = mean over n_looks independent bin products D_k conj(R_k),
    % D_k ~ CN(0, P_D), R_k ~ CN(0, P_R), independent (coh = 0). c_hat = C / P_D.
    D = sqrt(P_D/2) * (randn(n_looks, n_cap) + 1i*randn(n_looks, n_cap));
    R = sqrt(P_R/2) * (randn(n_looks, n_cap) + 1i*randn(n_looks, n_cap));
    C = mean(D .* conj(R), 1);                   % 1 x n_cap
    c_hat = C / P_D;

    c_var_noise = var(c_hat, 0);                 % 1/(N-1), matches window_stats
    verifyEqual(tc, c_var_noise, v_pred, 'RelTol', 0.06, ...
        sprintf('noise-only c_var %.4g vs predicted %.4g', c_var_noise, v_pred));

    % Signal + noise: add an independent zero-mean geophysical scatter of known
    % variance -> c_var ~ v_pred + v_geo (independent contributions add).
    v_geo = 0.05;
    g = sqrt(v_geo/2) * (randn(1, n_cap) + 1i*randn(1, n_cap));
    c_var_sn = var(c_hat + g, 0);
    verifyEqual(tc, c_var_sn, v_pred + v_geo, 'RelTol', 0.05, ...
        sprintf('signal+noise c_var %.4g vs %.4g', c_var_sn, v_pred + v_geo));
end


% =========================================================================
% O. Shuffled-join invariance + snow-height guard
% =========================================================================
function test_e2e_shuffled_join_identical(tc)
% The stage sorts L1/L2 by timestamp internally, so independently shuffling the
% L1 and L2 input row orders must yield an identical output product.
    [L1, L2, CAL, ELEV] = happy_tables();
    [d, cfg] = write_fixture(tc, L1, L2, CAL, ELEV);

    compute_sigma0(cfg);
    ref = readtable(fullfile(d,'BrundageSoOp_sigma0.csv'), 'TextType', 'string');

    rng(99);
    L1s = L1(randperm(height(L1)), :);
    L2s = L2(randperm(height(L2)), :);           % independent permutation
    write_csv(fullfile(d,'BrundageSoOp_L1_sig.csv'), L1s);
    write_csv(fullfile(d,'BrundageSoOp_L2.csv'),     L2s);

    compute_sigma0(cfg);
    shuf = readtable(fullfile(d,'BrundageSoOp_sigma0.csv'), 'TextType', 'string');

    verifyTrue(tc, isequaln(ref, shuf), 'shuffled-input output differs');
end

function test_e2e_snow_height_guard(tc)
% Snow-height guard: when SNOdar snow depth >= tower height, h_snow = tower_h -
% depth <= 0 is set NaN, so the snow-height sigma0 variant is NaN while the
% fixed-height products stay finite. Drives the real load_snodar path via a
% minimal synthetic Campbell TOA5 file (which also exercises its spike filter).
    t0 = datetime(2026,1,1,0,0,0);
    off_h = (0.5:0.25:1.75)';                    % 6 clean captures
    N = numel(off_h);
    t = t0 + hours(off_h);
    bn = "cap" + string((1:N)');
    phase = linspace(0, 60, N)';                 % vary c_hat -> nonzero variance

    L1 = table(t, bn, repmat(1000,N,1), repmat(1e6,N,1), repmat(1e5,N,1), ...
        'VariableNames', {'timestamp','base_name','peak_amplitude_fd_muos', ...
                          'pow_ch0_fd_muos','pow_ch1_fd_muos'});
    L2 = table(t, bn, repmat(40,N,1), phase, ...
        'VariableNames', {'timestamp','base_name','theta_deg','phase_corr_cal_fd_muos_deg'});
    CAL = table(t, repmat(100,N,1), repmat(50,N,1), ones(N,1), zeros(N,1), ...
        'VariableNames', {'timestamp','G_De','G_Re','P_DN','overflow_flag'});
    ELEV = elev_table(t0);

    [d, cfg] = write_fixture(tc, L1, L2, CAL, ELEV);
    cfg.tower_h_m = 3.0;                          % small synthetic tower

    % Minimal TOA5: 15-min depth nodes spanning the captures, depth = 3.5 m
    % (>= tower 3.0 -> h_snow < 0). One dip node (2.5 h, away from captures) the
    % spike filter drops; dist + depth = 4.0 < 4.2 keeps the good rows.
    wt    = t0 + hours((0:0.25:3.0)');
    nw    = numel(wt);
    depth = repmat(3.5, nw, 1);
    dist  = repmat(0.5, nw, 1);
    depth(11) = 0.1;                             % 2.5 h dip -> spike-filtered NaN
    wx_path = fullfile(d, 'brundage_toa5.dat');
    write_toa5(wx_path, wt, dist, depth, -5*ones(nw,1), -4*ones(nw,1));
    cfg.wx_dat = wx_path;

    compute_sigma0(cfg);
    OUT = readtable(fullfile(d,'BrundageSoOp_sigma0.csv'), 'TextType', 'string');

    % Snow depth loaded and finite at the captures (~3.5 m); h_snow guarded NaN.
    verifyTrue(tc, all(isfinite(OUT.snow_depth_m)));
    verifyEqual(tc, OUT.snow_depth_m, repmat(3.5, N, 1), 'AbsTol', 1e-9);
    verifyTrue(tc, all(isnan(OUT.h_snow_m)));
    verifyTrue(tc, all(isnan(OUT.r1_snow_m)));
    verifyTrue(tc, all(isnan(OUT.Aeff_snow_m2)));
    % Snow-height product NaN everywhere; fixed-height products finite.
    verifyTrue(tc, all(isnan(OUT.sigma0_app_lin_snow_h)));
    verifyTrue(tc, any(isfinite(OUT.sigma0_app_lin_fixed_h)));
    verifyTrue(tc, any(isfinite(OUT.gamma_lin)));
end


% =========================================================================
% Local helpers (not test functions — names avoid the test prefix/suffix)
% =========================================================================
function [t, c_hat, K, kg] = build_window_series()
% 8 captures used by the window_stats exactness tests. Offsets in hours; the
% 1.5 h gaps after t=5 h exercise n_runs. c_hat(1:5) sum to 10+10i (mean 2+2i).
    off_h = [0; 1; 2; 3; 4; 5; 6.5; 8];
    t = datetime(2026,1,1,0,0,0) + hours(off_h);
    c_hat = [1+2i; 3+0i; 2+2i; 0+4i; 4+2i; 10+0i; 20+0i; 30+0i];
    K = [ones(8,1), ones(8,1)];
    K(4, 2) = NaN;                               % variant-2 NaN prefactor
    kg = ones(8,1);
end

function [L1, L2, CAL, ELEV] = happy_tables()
% Standard 8-capture fixture: all clean except cap5 (grazing, theta=2 deg) and
% cap8 (> 1 h from any calib -> cal-missing). Calib runs at 0.25/1.25/2.25 h.
    t0 = datetime(2026,1,1,0,0,0);
    off_h = [0; 0.5; 1.0; 1.5; 2.0; 2.5; 3.0; 3.5];
    N = numel(off_h);
    t = t0 + hours(off_h);
    bn = "cap" + string((1:N)');

    theta = repmat(40, N, 1);
    theta(5) = 2;                                % grazing -> flag_geom_invalid
    phase = linspace(0, 40, N)';

    L1 = table(t, bn, repmat(1000,N,1), repmat(1e6,N,1), repmat(1e5,N,1), ...
        'VariableNames', {'timestamp','base_name','peak_amplitude_fd_muos', ...
                          'pow_ch0_fd_muos','pow_ch1_fd_muos'});
    L2 = table(t, bn, theta, phase, ...
        'VariableNames', {'timestamp','base_name','theta_deg','phase_corr_cal_fd_muos_deg'});

    ct = t0 + hours([0.25; 1.25; 2.25]);
    CAL = table(ct, [100;100;100], [50;50;50], [1;1;1], [0;0;0], ...
        'VariableNames', {'timestamp','G_De','G_Re','P_DN','overflow_flag'});

    ELEV = elev_table(t0);
end

function ELEV = elev_table(t0)
% Elevation table (UTC) spanning the fixture captures; GEO range ~3.7e4 km.
    et = t0 + hours((-1:0.5:5)');
    n = numel(et);
    ELEV = table(et, repmat(40,n,1), repmat(180,n,1), repmat(37000,n,1), ...
        'VariableNames', {'timestamp','elevation_deg','azimuth_deg','range_km'});
end

function [d, cfg, t_in] = write_fixture(tc, L1, L2, CAL, ELEV)
% Create a temp product dir, write the four CSVs, register teardown, and return
% a minimal standalone cfg (sigma0_* left to the stage's getfield_default's).
    d = tempname;
    mkdir(d);
    tc.addTeardown(@() rmdir(d, 's'));

    elev_path = fullfile(d, 'muos_elev.csv');
    write_csv(fullfile(d, 'BrundageSoOp_L1_sig.csv'), L1);
    write_csv(fullfile(d, 'BrundageSoOp_L2.csv'),     L2);
    write_csv(fullfile(d, 'BrundageSoOp_calib.csv'),  CAL);
    write_csv(elev_path,                              ELEV);

    cfg = struct();
    cfg.out_dir    = d;
    cfg.freq_hz    = 370e6;
    % Small FFT length keeps the stage's runtime band_mask / Hann window cheap
    % (npts = floor(fs*Ti) = 2000) so the fixture-driven suite stays fast. The
    % single-block muos_bands sits inside the RF passband (370 +/- 1 MHz) so the
    % fd_muos family stays assessable (~half the bins in-band).
    cfg.fs         = 2e6;
    cfg.Ti         = 0.001;
    cfg.num_segs   = 2;
    cfg.tower_h_m  = 6.096;
    cfg.capture_tz = 'UTC';
    cfg.elev_table = elev_path;
    cfg.muos_bands = 1e6 * [369.5 370.5];

    t_in = L1.timestamp;
end

function write_csv(path, T)
% Write a fixture table with the ISO timestamp format the stage parses on read.
    if ismember('timestamp', T.Properties.VariableNames) && isdatetime(T.timestamp)
        T.timestamp.Format = 'yyyy-MM-dd HH:mm:ss';
    end
    writetable(T, path);
end

function dsnr = expected_dsnr_local(cfg, P_dsig, P_DN, fam)
% Mirror compute_sigma0's per-capture DSNR so tests can assert the exact
% dsnr_db: P_noise = NG*f_band*P_DN, NG = mean(hann.^2), f_band = 1 for the
% full-band fd/td families, (# MUOS bins)/npts for fd_muos; unassessable
% (non-finite/non-positive P_noise or P_dsig) -> NaN.
    npts = floor(cfg.fs * cfg.Ti);
    win  = 0.5*(1 - cos(2*pi*(0:npts-1)'/(npts-1)));
    NG   = mean(win.^2);
    if strcmp(fam, 'fd_muos')
        if isempty(cfg.muos_bands)
            nb = 0;
        else
            nb = sum(rfi_excise().band_mask(cfg.muos_bands, cfg.freq_hz, cfg.fs, npts));
        end
    else
        nb = npts;
    end
    P_noise = NG * (nb / npts) * P_DN;
    if isfinite(P_noise) && P_noise > 0 && isfinite(P_dsig) && P_dsig > 0
        dsnr = 10 * log10(max(P_dsig - P_noise, 0) / P_noise);
    else
        dsnr = NaN;
    end
end

function write_toa5(path, ts, dist, depth, airtc, tempc)
% Minimal Campbell TOA5 for load_snodar: line 1 station info + lines 3/4
% units/proc are skipped; line 2 is the comma-separated header (UNQUOTED so
% load_snodar's exact name match works); data rows are %q-quoted timestamp +
% numeric columns keyed by name.
    ts.Format = 'yyyy-MM-dd HH:mm:ss';
    fid = fopen(path, 'w');
    fprintf(fid, '"TOA5","stn","logger","sn","os","prog","sig","table"\n');
    fprintf(fid, 'TIMESTAMP,SnoDAR_distance_Avg,SnoDAR_snow_depth_Avg,AirTC_Avg,Temp_C_Avg\n');
    fprintf(fid, 'TS,m,m,degC,degC\n');
    fprintf(fid, 'Smp,Avg,Avg,Avg,Avg\n');
    for i = 1:numel(ts)
        fprintf(fid, '"%s",%.6g,%.6g,%.6g,%.6g\n', char(ts(i)), ...
                dist(i), depth(i), airtc(i), tempc(i));
    end
    fclose(fid);
end

function names = sigma0_schema()
% The 34 output columns of compute_sigma0, in order. flag_dsnr_na is inserted
% immediately after flag_dsnr_low (the unassessable-SNR guard state added when
% the DSNR ratio-estimator guard cannot be verified — P_DN missing/nonpositive,
% P_dsig nonpositive, or an empty family band).
    names = {'timestamp', 'base_name', 'theta_deg', 'range_km', 'r_d_m', ...
             'r1_fixed_m', 'r1_snow_m', 'Aeff_fixed_m2', 'Aeff_snow_m2', ...
             'snow_depth_m', 'h_fixed_m', 'h_snow_m', 'G_De', 'G_Re', ...
             'cal_age_s', 'P_dsig_adc2', 'dsnr_db', 'c_mean_re', 'c_mean_im', ...
             'c_var', 'c_var_noise_est', 'n_window', 'n_runs', 'flag_dsnr_low', ...
             'flag_dsnr_na', 'flag_cal_missing', 'flag_geom_invalid', ...
             'sigma0_app_lin_fixed_h', 'sigma0_app_lin_snow_h', 'gamma_lin', ...
             'ant_gain_direct_dbi', 'ant_gain_reflected_dbi', 'corr_family', ...
             'lambda_m'};
end

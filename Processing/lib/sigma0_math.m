function H = sigma0_math()
% Pure geometry / estimator math for the direct-referenced sigma0 (+ Gamma)
% calibration stage (compute_sigma0). Returns a struct of vectorized function
% handles (the same function-handle-factory idiom as rfi_excise and
% BrundageSoOp_fun), so the numerics can be exercised independently of file IO:
%   H = sigma0_math();  [A, a, b] = H.fresnel(lambda, h, elev_deg);
%
% CONVENTIONS (documented once here):
%   * All handles are vectorized elementwise on COLUMN vectors; scalars
%     broadcast (fixed tower height, wavelength, scalar gain ratios).
%   * ANGLES ARE IN DEGREES (sind used internally).
%   * Lengths in metres, areas in m^2.
%   * Gains / gain ratios are LINEAR (not dB).
%   * The correlation samples c_hat are DIMENSIONLESS (per-capture C / P_dsig),
%     so sigma0 and Gamma come out dimensionless (m^2 / m^2).
%
% Handles:
%   H.r1(h_m, elev_deg)                              reflected-path length (m)
%   H.fresnel(lambda_m, h_m, elev_deg) -> [Aeff, a, b, R]   first Fresnel zone
%       (R = ellipse-center horizontal offset from the antenna along azimuth)
%   H.k_sigma0(r1, r2, rd, gdr, gder, Aeff)          per-capture sigma0 prefactor
%   H.k_gamma(r1, r2, rd, gdr, gder)                 per-capture Gamma prefactor
%   H.window_stats(t, c_hat, K, kg, win_hours, min_count)  sliding-window estimators
%   H.n_runs(t, gap_hr)                              # contiguous runs in a time vector
%
% GEOMETRY (fixed tower, locally planar horizontal reflector a height h below
% the antenna, satellite at elevation e):
%   r1 = h / sin(e)                                  reflected extra-path length
%   First Fresnel zone (Larson & Nievinski 2013, GPS Solutions 17:41-51,
%   appendix; n = 1): with d = lambda/2 and s = sin(e),
%       b = sqrt(2 d h / s + (d/s)^2)                semi-minor axis (m)
%       a = b / s                                    semi-major axis (m)
%       A_eff = pi a b                               footprint area (m^2)
%
% ESTIMATORS (theory doc IIP-SoOpSAR-processing-equations §2.2, Eqs. 41-42;
% direct-reference form a la Shah et al. 2017 — the transmit EIRP cancels
% against the measured direct-channel power, so only gain RATIOS remain):
%   sigma0 = 4 pi (r1 r2 / rd)^2 (Gd/Gr)(Gde/Gre) <|c_hat - <c_hat>|^2> / A_eff
%   Gamma  =      ((r1 + r2)/rd)^2 (Gd/Gr)(Gde/Gre) |<c_hat>|^2
% where <.> is a slow-time average over a centered window of captures.
%
% COHERENT-MEAN REMOVAL IS DONE IN c_hat SPACE (not on prefactor-scaled
% samples): window_stats forms <c_hat> and subtracts it from the raw complex
% samples BEFORE multiplying each squared residual by that capture's prefactor
% K. Rescaling the complex samples by sqrt(K) first would modulate the
% (quasi-static, dominant) coherent component and leak var(sqrt(K))*|<c_hat>|^2
% into the incoherent variance whenever the geometry varies across the window.

    H.r1           = @r1;
    H.fresnel      = @fresnel;
    H.k_sigma0     = @k_sigma0;
    H.k_gamma      = @k_gamma;
    H.window_stats = @window_stats;
    H.n_runs       = @n_runs;
end


% =========================================================================
function r = r1(h_m, elev_deg)
% Reflected-path geometric length r1 = h / sin(elevation), metres.
    r = h_m ./ sind(elev_deg);
end


% =========================================================================
function [Aeff_m2, a_m, b_m, R_m] = fresnel(lambda_m, h_m, elev_deg)
% First Fresnel-zone ellipse (n = 1) for a reflector a height h_m below the
% antenna with the satellite at elevation elev_deg. Larson & Nievinski (2013),
% appendix. Returns the footprint area A_eff (m^2), the semi-major/-minor
% axes a_m/b_m (m), and the ellipse-center horizontal offset R_m (m) from the
% antenna along the satellite azimuth (the semi-major axis is azimuth-aligned).
% Vectorized: lambda_m scalar, h_m/elev_deg columns (h_m may be scalar and
% broadcast). At elev_deg = 90 the offset is exactly 0 (tand(90) = Inf).
    d   = lambda_m / 2;
    s   = sind(elev_deg);
    b_m = sqrt(2 .* d .* h_m ./ s + (d ./ s).^2);
    a_m = b_m ./ s;
    Aeff_m2 = pi .* a_m .* b_m;
    R_m = h_m ./ tand(elev_deg) + (d ./ s) ./ tand(elev_deg);
end


% =========================================================================
function k = k_sigma0(r1_m, r2_m, rd_m, gd_over_gr, gde_over_gre, Aeff_m2)
% Per-capture apparent-sigma0 prefactor (Eq. 42, direct-referenced). Multiplies
% the squared coherent-mean-removed residual |c_hat - <c_hat>|^2.
    k = 4*pi .* (r1_m .* r2_m ./ rd_m).^2 .* gd_over_gr .* gde_over_gre ./ Aeff_m2;
end


% =========================================================================
function k = k_gamma(r1_m, r2_m, rd_m, gd_over_gr, gde_over_gre)
% Per-capture coherent-reflectivity (Gamma) prefactor. Multiplies |<c_hat>|^2.
% A_eff-free (footprint cancels in the coherent-power ratio).
    k = ((r1_m + r2_m) ./ rd_m).^2 .* gd_over_gr .* gde_over_gre;
end


% =========================================================================
function S = window_stats(t, c_hat, K, kg, win_hours, min_count)
% Sliding centered-window estimators for the direct-referenced sigma0 / Gamma.
%
% Inputs (all column vectors, aligned by capture, sorted by time by the caller):
%   t         : datetime column of capture times.
%   c_hat     : complex per-capture samples (NaN marks an excluded capture).
%   K         : N x M real matrix of per-capture sigma0 prefactors (one column
%               per h-variant, here [fixed-h snow-h]); NaN where that variant's
%               geometry/gain is unavailable for a capture.
%   kg        : N x 1 real per-capture Gamma prefactors (NaN where unavailable).
%   win_hours : full window width (h); each row i uses |t - t(i)| <= win_hours/2.
%   min_count : minimum valid member count.
%
% For each row i, W = the captures with |t - t(i)| <= win_hours/2 AND finite
% c_hat. n_window(i) = numel(W). If n_window < max(min_count, 2) the row's
% products are NaN (the row is still emitted). Otherwise, with the coherent
% mean cb = mean(c_hat(W)):
%   c_mean(i) = cb (complex);
%   c_var(i)  = sum(|c_hat(W) - cb|^2) / (n - 1)   (1/(N-1) complex sample var);
%   sigma0(i,m) = sum(K(Wm,m) .* |c_hat(Wm) - cb|^2) / (nm - 1) over the members
%                 Wm of W with FINITE K(:,m) (per-variant valid count nm; if
%                 nm < max(min_count,2) that variant is NaN). The residual uses
%                 the FULL-window cb (coherent-mean removal in c_hat space).
%   gamma(i)  = |mean(sqrt(kg(Wg)) .* c_hat(Wg))|^2 over members Wg of W with
%                 finite kg (own valid count; NaN if < min_count).
% n_runs(i) = # temporally contiguous capture runs within W (gap > 1.0 h splits)
% — a coarse effective-degrees-of-freedom hint (overlapping windows and
% clustered runs make n_window an OVERCOUNT of independent looks).
%
% Simple O(N*W) implementation over a numeric time axis (posixtime seconds);
% season N ~ 1e4, W ~ 1e2 is comfortably fast.
    N  = numel(t);
    Mv = size(K, 2);
    tn = posixtime(t);                 % numeric seconds (relative diffs only)
    half_s  = (win_hours / 2) * 3600;
    gap_hr  = 1.0;                      % n_runs gap threshold (h)
    min_row = max(min_count, 2);        % row / per-variant floor (>=2 for var)

    c_mean   = complex(nan(N, 1));
    c_var    = nan(N, 1);
    sigma0   = nan(N, Mv);
    gamma    = nan(N, 1);
    n_window = zeros(N, 1);
    n_runs_c = zeros(N, 1);

    finite_c = isfinite(c_hat);

    for i = 1:N
        in = (abs(tn - tn(i)) <= half_s) & finite_c;
        W  = find(in);
        n  = numel(W);
        n_window(i) = n;
        if n >= 1
            n_runs_c(i) = n_runs(t(W), gap_hr);
        end
        if n < min_row
            continue;
        end

        cw   = c_hat(W);
        cb   = mean(cw);
        res2 = abs(cw - cb).^2;         % |residual|^2 (real, non-negative)
        c_mean(i) = cb;
        c_var(i)  = sum(res2) / (n - 1);

        % Per-variant apparent sigma0 — exclude captures with NaN prefactor
        % from BOTH the weighted sum and the (nm - 1) count for that variant.
        for m = 1:Mv
            km = K(W, m);
            vm = isfinite(km);
            nm = sum(vm);
            if nm >= min_row
                sigma0(i, m) = sum(km(vm) .* res2(vm)) / (nm - 1);
            end
        end

        % Coherent reflectivity Gamma — exclude NaN-prefactor captures.
        vg = isfinite(kg(W));
        ng = sum(vg);
        if ng >= min_count
            gamma(i) = abs(mean(sqrt(kg(W(vg))) .* cw(vg)))^2;
        end
    end

    S = struct('c_mean',   c_mean, ...
               'c_var',    c_var, ...
               'sigma0',   sigma0, ...
               'gamma',    gamma, ...
               'n_window', n_window, ...
               'n_runs',   n_runs_c);
end


% =========================================================================
function m = n_runs(t, gap_hr)
% Number of temporally contiguous capture RUNS in a datetime vector t: sorting
% by time, a gap greater than gap_hr hours between consecutive captures starts
% a new run. Returns a scalar count (0 for empty, 1 for a single capture).
    if isempty(t)
        m = 0;
        return;
    end
    ts = sort(t(:));
    if isscalar(ts)
        m = 1;
        return;
    end
    m = 1 + sum(hours(diff(ts)) > gap_hr);
end

function tests = viewer_phase_offset_test
% Unit tests for the 'Raw: Phase Offset' viewer helpers in soop_viewer_util
% (phoff_measure: D.*conj(R) lag-0 phase + normalized coherence, fail-closed;
% phoff_prep: midpoint slice + precomputed Off/On traces) and the view's
% catalog integration.
% Run: matlab -batch "soop_setup_paths; addpath('tests'); runtests('viewer_phase_offset_test')"
    tests = functiontests(localfunctions);
end


function setupOnce(tc)
    tc.TestData.U = soop_viewer_util();
end

function e = circ_err(a, b)
% Circular phase error |wrap(a-b)| — safe at the ±pi branch.
    e = abs(angle(exp(1i * (a - b))));
end

function ch = carrier(n)
% Deterministic wideband-ish complex test signal (no rng dependency).
    t  = (0:n-1).';
    ch = exp(1i * 2*pi*0.037 * t) .* (1.5 + cos(2*pi*0.0013 * t)) + ...
         0.3 * exp(1i * 2*pi*0.211 * t);
end


% -------------------------------------------------------------- phoff_measure

function test_sign_convention(tc)
    % ch1 = ch0 .* exp(-1i*phi0) means D leads R by phi0; the D.*conj(R)
    % convention (schema v5+, compute_calib C_RDNS) must measure +phi0.
    % Scaling ch1 must not change phi or rho (rho == 1 for exact copies).
    U   = tc.TestData.U;
    ch0 = carrier(4096);
    for phi0 = [0.7, -1.2, 0]
        [phi, rho] = U.phoff_measure(ch0, 0.5 * ch0 .* exp(-1i * phi0));
        verifyLessThan(tc, circ_err(phi, phi0), 1e-10, ...
            sprintf('phi0 = %g', phi0));
        verifyEqual(tc, rho, 1, 'AbsTol', 1e-9);
    end
end

function test_wrap_edge(tc)
    % Offsets near the ±pi branch must be recovered (compare circularly).
    U   = tc.TestData.U;
    ch0 = carrier(4096);
    for phi0 = [pi - 0.01, -pi + 0.01]
        phi = U.phoff_measure(ch0, ch0 .* exp(-1i * phi0));
        verifyLessThan(tc, circ_err(phi, phi0), 1e-10, ...
            sprintf('phi0 = %g', phi0));
    end
end

function test_noisy_recovery_and_rho(tc)
    % Common noise source + independent per-channel receiver noise: the
    % injected offset is recovered within a small circular tolerance and
    % rho sits high but below 1.
    U    = tc.TestData.U;
    rng(42);
    n    = 1e5;
    s    = complex(randn(n,1), randn(n,1));
    phi0 = -1.42;   % roughly the chain-offset ballpark
    ch0  = s + 0.1 * complex(randn(n,1), randn(n,1));
    ch1  = (s + 0.1 * complex(randn(n,1), randn(n,1))) .* exp(-1i * phi0);
    [phi, rho] = U.phoff_measure(ch0, ch1);
    verifyLessThan(tc, circ_err(phi, phi0), 0.02);
    verifyGreaterThan(tc, rho, 0.9);
    verifyLessThan(tc, rho, 1);
end

function test_correction_closes_loop(tc)
    % Rotating ch1 by exp(+1i*phi) zeroes the lag-0 cross-correlation
    % phase — the corrected statistic is real and nonnegative.
    U    = tc.TestData.U;
    rng(7);
    n    = 1e5;
    s    = complex(randn(n,1), randn(n,1));
    ch0  = s + 0.2 * complex(randn(n,1), randn(n,1));
    ch1  = (s + 0.2 * complex(randn(n,1), randn(n,1))) .* exp(-1i * 2.6);
    phi  = U.phoff_measure(ch0, ch1);
    phi2 = U.phoff_measure(ch0, ch1 .* exp(1i * phi));
    verifyLessThan(tc, abs(phi2), 1e-9);
end

function test_rho_independent_noise(tc)
    % Independent channels: rho near 0 (and always within [0, 1]).
    U   = tc.TestData.U;
    rng(1);
    n   = 1e5;
    [phi, rho] = U.phoff_measure(complex(randn(n,1), randn(n,1)), ...
                                 complex(randn(n,1), randn(n,1)));
    verifyLessThan(tc, rho, 0.05);
    verifyGreaterThanOrEqual(tc, rho, 0);
    verifyTrue(tc, isfinite(phi));   % some angle — just not trustworthy (low rho)
end

function test_fail_closed(tc)
    % Empty, no finite pairs, zero-power channel, exact-zero correlation:
    % phi and rho must be NaN — a zero correlation has no phase.
    U   = tc.TestData.U;
    ch0 = carrier(1024);
    [phi, rho] = U.phoff_measure([], []);
    verifyTrue(tc, isnan(phi) && isnan(rho), 'empty');
    [phi, rho] = U.phoff_measure(NaN(8,1), NaN(8,1));
    verifyTrue(tc, isnan(phi) && isnan(rho), 'all-NaN');
    [phi, rho] = U.phoff_measure(ch0, zeros(size(ch0)));
    verifyTrue(tc, isnan(phi) && isnan(rho), 'zero-power ch1');
    % Exactly cancelling pair: C == 0 with nonzero power on both channels.
    [phi, rho] = U.phoff_measure([1; 1], [1; -1]);
    verifyTrue(tc, isnan(phi) && isnan(rho), 'exact-zero correlation');
end

function test_partial_nan_pairs(tc)
    % Non-finite samples are excluded pairwise; the offset survives.
    U    = tc.TestData.U;
    ch0  = carrier(2048);
    phi0 = 0.9;
    ch1  = ch0 .* exp(-1i * phi0);
    ch0(11:20)  = NaN;
    ch1(101:110) = Inf;
    phi = U.phoff_measure(ch0, ch1);
    verifyLessThan(tc, circ_err(phi, phi0), 1e-10);
end


% ----------------------------------------------------------------- phoff_prep

function test_prep_center_and_slice(tc)
    % Center convention c = floor((N+1)/2): t_us == 0 exactly at the center
    % sample, for even and odd N; slice clamps to short records; one-sample
    % and empty inputs are well-defined.
    U  = tc.TestData.U;
    fs = 20e6;
    for n = [10, 11]
        ch = carrier(n);
        D  = U.phoff_prep(ch, ch, fs, 3);
        c  = floor((n + 1) / 2);
        verifyEqual(tc, numel(D.t_us), 7, sprintf('N = %d slice length', n));
        k = find(D.t_us == 0);
        verifyEqual(tc, numel(k), 1);
        verifyEqual(tc, D.r0(k), real(ch(c)), 'AbsTol', 1e-12);
    end
    D = U.phoff_prep(carrier(4), carrier(4), fs, 1000);   % shorter than slice
    verifyEqual(tc, numel(D.t_us), 4);
    D = U.phoff_prep(carrier(1), carrier(1), fs, 1000);   % one sample
    verifyEqual(tc, D.t_us, 0);
    D = U.phoff_prep([], [], fs, 1000);                   % empty
    verifyEqual(tc, D.n, 0);
    verifyEmpty(tc, D.t_us);
    verifyEqual(tc, D.ymax, 0);
end

function test_prep_traces_and_ymax(tc)
    % r1_on rotates CH1 back onto CH0 for an exact scaled copy; ymax is the
    % union of both switch states (stable y-scale across toggles).
    U    = tc.TestData.U;
    fs   = 20e6;
    ch0  = carrier(4096);
    ch1  = ch0 .* exp(-1i * 1.1);
    D    = U.phoff_prep(ch0, ch1, fs, 50);
    verifyEqual(tc, D.r1_on, D.r0, 'AbsTol', 1e-9);
    verifyGreaterThanOrEqual(tc, D.ymax + 1e-12, max(abs(D.r0)));
    verifyGreaterThanOrEqual(tc, D.ymax + 1e-12, max(abs(D.r1_off)));
    verifyGreaterThanOrEqual(tc, D.ymax + 1e-12, max(abs(D.r1_on)));
end

function test_prep_nan_phi_fallback(tc)
    % No usable correlation (zero CH1): phi NaN and r1_on must fall back to
    % r1_off — the rotation can never inject NaNs into the trace.
    U = tc.TestData.U;
    D = U.phoff_prep(carrier(1024), zeros(1024, 1), 20e6, 50);
    verifyTrue(tc, isnan(D.phi));
    verifyEqual(tc, D.r1_on, D.r1_off);
    verifyTrue(tc, isfinite(D.ymax));
end


function test_title_rule(tc)
    % Title states (user spec 2026-07-20): numbers appear ONLY while the
    % correction is applied; switch on with unusable correlation says n/a;
    % switch off shows the bare capture name.
    U = tc.TestData.U;
    t_off = U.phoff_title('CAP', -1.42, 0.93, false);
    verifyEqual(tc, t_off, 'CAP');
    t_on = U.phoff_title('CAP', deg2rad(-81.4), 0.93, true);
    verifyTrue(tc, startsWith(t_on, 'CAP'));
    verifyTrue(tc, contains(t_on, 'phase offset -81.4'));
    verifyTrue(tc, contains(t_on, 'rho 0.93'));
    t_na = U.phoff_title('CAP', NaN, NaN, true);
    verifyTrue(tc, contains(t_na, 'phase offset n/a'));
    verifyFalse(tc, contains(t_na, 'rho'));
end


% ---------------------------------------------------------------- integration

function test_catalog_entry(tc)
    % The view is registered right after 'Raw: Time domain', flagged as a
    % per-capture non-aggregating view, carries help + math text, does not
    % engage the RFI-method machinery, and the NL glob is unchanged.
    U   = tc.TestData.U;
    % Minimal cfg covering every field the catalog's string builders format
    % (values are placeholders — only presence and numeric type matter).
    cfg = struct('freq_hz', 1268e6, 'fs', 20e6, 'num_segs', 2, 'Ti', 0.9, ...
                 'peak_lag', -0.575, 'T_load_K', 290);
    [PI, CP] = soop_viewer_catalog(cfg);
    names = {PI.name};
    k  = find(strcmp(names, 'Raw: Phase Offset'));
    kt = find(strcmp(names, 'Raw: Time domain'));
    verifyNumElements(tc, k, 1);
    verifyEqual(tc, k, kt + 1);
    verifyTrue(tc, PI(k).uses_cap);
    verifyFalse(tc, PI(k).uses_agg);
    verifyGreaterThan(tc, strlength(string(PI(k).expl)), 0);
    verifyGreaterThan(tc, strlength(string(PI(k).math)), 0);
    verifyGreaterThan(tc, strlength(string(PI(k).fcn)), 0);
    verifyFalse(tc, U.plot_uses_method('Raw: Phase Offset'));
    verifyEqual(tc, CP.NL, 'UHF__NL_2*_ch0.dat');
end

function tests = viewer_unwrap_test
% Tests for the 'L2: Candidates Unwrapped' figure family: the pure unwrap_deg
% helper, theory_overlay's wrap_out mode, the catalog entries/wording, and
% seeded production renders of soop_viewer_render_l2 pinning the display-subset
% (post range/TOD/SNR selection) unwrap ordering and the wrapped/unwrapped
% branching.
% Run: matlab -batch "soop_setup_paths; addpath('tests'); runtests('viewer_unwrap_test')"
    tests = functiontests(localfunctions);
end


function setupOnce(tc)
    tc.TestData.M   = BrundageSoOp_fun();
    tc.TestData.U   = soop_viewer_util();
    tc.TestData.dir = tempname;
    mkdir(tc.TestData.dir);
    tc.TestData.t0  = datetime(2026, 1, 1);
end

function teardownOnce(tc)
    if isfolder(tc.TestData.dir), rmdir(tc.TestData.dir, 's'); end
end


% --------------------------------------------------------- unwrap_deg helper

function test_unwrap_deg_basic(tc)
    % A steady 50 deg/step ramp wrapped to ±180 unwraps back to the exact
    % cumulative ramp: continuous (no step >= 180) and congruent mod 360.
    U = tc.TestData.U;
    n = 30;
    t = tc.TestData.t0 + hours(2 * (0:n-1)');
    truth = 50 * (0:n-1)';
    u = U.unwrap_deg(t, U.wrap_deg(truth));
    verifyEqual(tc, u, truth, 'AbsTol', 1e-9);
    verifyLessThan(tc, max(abs(diff(u))), 180);
    verifyEqual(tc, U.wrap_deg(u), U.wrap_deg(truth), 'AbsTol', 1e-9);
end

function test_unwrap_deg_nan_gap(tc)
    % NaN samples come back as NaN and the branch CONTINUES across the gap.
    U = tc.TestData.U;
    t = tc.TestData.t0 + hours(0:4)';
    u = U.unwrap_deg(t, [170; 179; NaN; -179; -170]);
    verifyEqual(tc, u([1 2 4 5]), [170; 179; 181; 190], 'AbsTol', 1e-9);
    verifyTrue(tc, isnan(u(3)));
end

function test_unwrap_deg_shuffle(tc)
    % Distinct timestamps: input row order never changes the values a given
    % sample receives (the unwrap runs in time order, results map back).
    U = tc.TestData.U;
    n = 20;
    t = tc.TestData.t0 + hours(2 * (0:n-1)');
    y = U.wrap_deg(75 * (0:n-1)');
    p = randperm(n)';
    u_sorted = U.unwrap_deg(t, y);
    u_shuf   = U.unwrap_deg(t(p), y(p));
    verifyEqual(tc, u_shuf, u_sorted(p), 'AbsTol', 1e-9);
end

function test_unwrap_deg_guards(tc)
    % Length mismatch is a caller-bug error; empty/all-NaN pass through;
    % Inf and NaT-timestamped samples come back NaN; shape follows y_deg.
    U = tc.TestData.U;
    t3 = tc.TestData.t0 + hours(0:2)';
    verifyError(tc, @() U.unwrap_deg(t3, [1; 2]), 'soop:unwrap_deg:length');
    verifyEqual(tc, U.unwrap_deg(datetime.empty(0, 1), zeros(0, 1)), zeros(0, 1));
    verifyTrue(tc, all(isnan(U.unwrap_deg(t3, nan(3, 1)))));
    u = U.unwrap_deg(t3, [170; Inf; -170]);
    verifyTrue(tc, isnan(u(2)));
    verifyEqual(tc, u([1 3]), [170; 190], 'AbsTol', 1e-9);   % branch continues
    u = U.unwrap_deg([t3(1); NaT; t3(3)], [170; 175; -170]);
    verifyTrue(tc, isnan(u(2)));
    verifyEqual(tc, u([1 3]), [170; 190], 'AbsTol', 1e-9);
    ur = U.unwrap_deg(t3', [170 -170 150]);                  % row in, row out
    verifyEqual(tc, size(ur), [1 3]);
    verifyEqual(tc, ur, [170 190 150], 'AbsTol', 1e-9);
end

function test_unwrap_deg_ties_and_boundary(tc)
    % Equal timestamps keep input order (stable sort); a jump of exactly
    % +180 deg is PRESERVED (MATLAB unwrap folds only strictly greater
    % jumps), while a strictly greater jump folds.
    U = tc.TestData.U;
    t = [tc.TestData.t0; tc.TestData.t0; tc.TestData.t0 + hours(1)];
    u = U.unwrap_deg(t, [170; -170; -150]);
    verifyEqual(tc, u, [170; 190; 210], 'AbsTol', 1e-9);
    u = U.unwrap_deg(tc.TestData.t0 + hours(0:1)', [0; 180]);
    verifyEqual(tc, u, [0; 180], 'AbsTol', 1e-9);
    u = U.unwrap_deg(tc.TestData.t0 + hours(0:1)', [0; 181]);
    verifyEqual(tc, u, [0; -179], 'AbsTol', 1e-9);
end


% ------------------------------------------------- theory_overlay wrap_out

function [ct, cp, wt, ws] = theory_fix(tc)
    % 15-min SWE ramp spanning >2 fringes at 400 mm/2pi, with displayed
    % captures near the record start (anchor lands on the first capture).
    wt = tc.TestData.t0 + minutes(15 * (0:96)');
    ws = linspace(0, 900, 97)';               % mm
    ct = wt(1:8:end);
    cp = 10 * ones(numel(ct), 1);             % deg, arbitrary measured level
end

function test_theory_overlay_wrap_flag(tc)
    % wrap_out=false leaves the curve continuous across fringes; default
    % and explicit true wrap to ±180 and equal wrap180(continuous).
    U = tc.TestData.U;
    [ct, cp, wt, ws] = theory_fix(tc);
    Ou = U.theory_overlay(ct, cp, wt, ws, 'first', 400, false);
    verifyTrue(tc, Ou.ok);
    verifyEqual(tc, Ou.phi_deg, 10 + 360 * ws / 400, 'AbsTol', 1e-9);
    verifyGreaterThan(tc, max(Ou.phi_deg), 180);   % continuous past a wrap
    O6 = U.theory_overlay(ct, cp, wt, ws, 'first', 400);
    Ow = U.theory_overlay(ct, cp, wt, ws, 'first', 400, true);
    verifyEqual(tc, O6.phi_deg, Ow.phi_deg, 'AbsTol', 1e-12);
    verifyEqual(tc, Ow.phi_deg, U.wrap_deg(Ou.phi_deg), 'AbsTol', 1e-9);
    verifyLessThanOrEqual(tc, max(abs(Ow.phi_deg)), 180);
end

function test_theory_overlay_wrap_out_validation(tc)
    % Seventh argument accepts scalar logical or numeric 0/1 only.
    U = tc.TestData.U;
    [ct, cp, wt, ws] = theory_fix(tc);
    On = U.theory_overlay(ct, cp, wt, ws, 'first', 400, 0);
    verifyGreaterThan(tc, max(On.phi_deg), 180);   % numeric 0 = no wrap
    O1 = U.theory_overlay(ct, cp, wt, ws, 'first', 400, 1);
    verifyLessThanOrEqual(tc, max(abs(O1.phi_deg)), 180);
    id = 'soop_viewer_util:theory_overlay:wrap_out';
    verifyError(tc, @() U.theory_overlay(ct, cp, wt, ws, 'first', 400, 2), id);
    verifyError(tc, @() U.theory_overlay(ct, cp, wt, ws, 'first', 400, [true true]), id);
    verifyError(tc, @() U.theory_overlay(ct, cp, wt, ws, 'first', 400, 'y'), id);
end


% ------------------------------------------------------------ catalog entries

function test_catalog_unwrap_entries(tc)
    % Both unwrapped entries exist directly after the wrapped MUOS-5 entry,
    % with linear-aggregation fcn lists (no circ_stats) and attached math.
    cfg = struct('freq_hz', 370e6, 'fs', 20e6, 'num_segs', 2, 'Ti', 0.9, ...
                 'peak_lag', -0.575, 'T_load_K', 290);
    [PI, ~] = soop_viewer_catalog(cfg);
    names = {PI.name};
    U = tc.TestData.U;
    i5 = find(strcmp(names, 'L2: Candidates — MUOS-5 (41622)'), 1);
    for k = {'L2: Candidates Unwrapped — MUOS-1 (38093)', ...
             'L2: Candidates Unwrapped — MUOS-5 (41622)'}
        i = find(strcmp(names, k{1}), 1);
        verifyNotEmpty(tc, i, k{1});
        verifyTrue(tc, PI(i).uses_agg, k{1});
        verifyFalse(tc, PI(i).uses_cap, k{1});
        verifyGreaterThan(tc, strlength(PI(i).math), 0, k{1});
        verifyEqual(tc, PI(i).fcn, ["aggregate", "load_snodar"], k{1});
        verifyTrue(tc, U.is_cand_kind(k{1}), k{1});
        verifyTrue(tc, U.plot_uses_domain(k{1}), k{1});
        verifyTrue(tc, U.plot_uses_method(k{1}), k{1});
    end
    verifyEqual(tc, names{i5 + 1}, 'L2: Candidates Unwrapped — MUOS-1 (38093)');
    verifyEqual(tc, names{i5 + 2}, 'L2: Candidates Unwrapped — MUOS-5 (41622)');
end

function test_catalog_wrapped_unwrapped_language(tc)
    % The parameterized passages land in the right flavor: wrapped keeps
    % circular/saw-tooth wording, unwrapped describes linear/continuous.
    cfg = struct('freq_hz', 370e6, 'fs', 20e6, 'num_segs', 2, 'Ti', 0.9, ...
                 'peak_lag', -0.575, 'T_load_K', 290);
    [PI, ~] = soop_viewer_catalog(cfg);
    names = {PI.name};
    ew = PI(strcmp(names, 'L2: Candidates — MUOS-5 (41622)')).expl;
    eu = PI(strcmp(names, 'L2: Candidates Unwrapped — MUOS-5 (41622)')).expl;
    verifyTrue(tc, contains(ew, 'circular aggregation'));
    verifyTrue(tc, contains(ew, 'saw-tooths'));
    verifyFalse(tc, contains(ew, 'UNWRAPPED'));
    verifyTrue(tc, contains(eu, 'UNWRAPPED'));
    verifyTrue(tc, contains(eu, 'LINEAR'));
    verifyTrue(tc, contains(eu, 'CONTINUOUS'));
    verifyTrue(tc, contains(eu, 'no wrap jumps'));
    verifyFalse(tc, contains(eu, 'circular aggregation'));
end


% ------------------------------------------------- seeded production renders

function V = seeded_viewer(tc)
    % Real viewer state + layout (headless), deterministic control state; the
    % tests assign synthetic CAND/L2/WX tables and call soop_viewer_render_l2
    % directly (render_now's data loading and family gating are not needed).
    cfg = struct('freq_hz', 370e6, 'fs', 20e6, 'num_segs', 2, 'Ti', 0.9, ...
                 'peak_lag', -0.575, 'T_load_K', 290, ...
                 'out_dir', tc.TestData.dir, 'data_dir', tc.TestData.dir);
    V = SoopViewerState();
    V.cfg = cfg;
    V.M   = BrundageSoOp_fun();
    V.npts = floor(cfg.fs * cfg.Ti);  V.n_want = V.npts * cfg.num_segs;
    V.calib_N_looks = cfg.fs * 2;
    V.Erfi = rfi_excise();
    V.L1 = table();  V.CAL = table();
    V.cache = struct('key', "", 'data', []);
    V.calib_base_cache  = struct('dir', "", 'T', table());
    V.calib_notch_cache = struct('dir', "", 'T', table());
    V.busy = false;  V.pending = false;  V.last_n = 0;
    V.OVF = strings(0, 1);
    V.cap_folders = containers.Map('KeyType', 'char', 'ValueType', 'char');
    V.ov_title = '';  V.ov_xlabel = '';  V.ov_ylabel = '';
    V.ov_plot_kind = '';
    V.U = soop_viewer_util();  V.D = soop_viewer_data();
    V.CB = soop_viewer_callbacks();
    [V.PLOT_INFO, V.CAP_PATTERNS] = soop_viewer_catalog(cfg);
    soop_viewer_layout(V);
    V.dd_domain.Value = 'sinc';
    V.dd_agg.Value = 'Raw captures';
    V.L2 = table();  V.WX = table();  V.CAND = table();
end

function [T, truth] = cand_ramp(tc, n, step_deg, dt)
    % Candidate table whose wrapped phase is a steady ramp: truth is the
    % season-cumulative (unwrapped) phase the display must recover.
    U = tc.TestData.U;
    t = tc.TestData.t0 + dt * (0:n-1)';
    truth = step_deg * (0:n-1)';
    T = table(t, "cap_" + string((1:n)'), 20 * ones(n, 1), ...
              U.wrap_deg(truth), ...
              'VariableNames', {'timestamp', 'base_name', 'snr_db', 'corr_41622'});
end

function y = phase_ydata(tc, V)
    % YData of the phase series (the sole line/errorbar on the first axes).
    ax = findobj(V.panel, 'Type', 'axes');
    h = [findobj(ax, 'Type', 'line'); findobj(ax, 'Type', 'errorbar')];
    verifyNumElements(tc, h, 1);
    y = h(1).YData(:);
end

function test_render_display_range_unwrap(tc)
    % The unwrap runs over the DISPLAYED samples only: the full range shows
    % the whole cumulative ramp, and a narrowed range re-unwraps just its
    % own points — re-anchoring near the first shown sample's wrapped value
    % instead of continuing the full-season branch.
    V = seeded_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    U = tc.TestData.U;
    [V.CAND, truth] = cand_ramp(tc, 30, 50, hours(2));
    kind = 'L2: Candidates Unwrapped — MUOS-5 (41622)';
    soop_viewer_render_l2(V, kind);
    verifyEqual(tc, phase_ydata(tc, V), truth, 'AbsTol', 1e-9);
    ax = findobj(V.panel, 'Type', 'axes');
    verifyEqual(tc, ax.YLabel.String, 'Unwrapped phase (deg)');
    verifyTrue(tc, contains(ax.Title.String, 'unwrapped'));
    % Narrow the range to start after 12 wrapped-branch crossings.
    V.dp1.Value = tc.TestData.t0 + days(1);
    delete(allchild(V.panel));
    soop_viewer_render_l2(V, kind);
    keep = V.CAND.timestamp >= V.dp1.Value;
    expect = U.unwrap_deg(V.CAND.timestamp(keep), U.wrap_deg(truth(keep)));
    verifyEqual(tc, phase_ydata(tc, V), expect, 'AbsTol', 1e-9);
    verifyEqual(tc, expect(1), U.wrap_deg(truth(find(keep, 1))), ...
                'AbsTol', 1e-9);                       % re-anchored
    verifyGreaterThan(tc, max(abs(expect - truth(keep))), 180);
end

function test_render_wrapped_control(tc)
    % Wrapped twin on the same data: values stay wrapped, fixed ±180 limits.
    V = seeded_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    [V.CAND, truth] = cand_ramp(tc, 30, 50, hours(2));
    soop_viewer_render_l2(V, 'L2: Candidates — MUOS-5 (41622)');
    U = tc.TestData.U;
    verifyEqual(tc, phase_ydata(tc, V), U.wrap_deg(truth), 'AbsTol', 1e-9);
    ax = findobj(V.panel, 'Type', 'axes');
    verifyEqual(tc, ax.YLim, [-180 180]);
    verifyEqual(tc, ax.YLabel.String, 'Phase (deg)');
    verifyFalse(tc, contains(ax.Title.String, 'unwrapped'));
end

function test_render_linear_aggregation(tc)
    % Per-run mean aggregates the unwrapped phase LINEARLY — matching
    % aggregate(..., 'lin') and differing from the circular aggregate the
    % wrapped views use; the hour-color scatter uses the same aggregate.
    V = seeded_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    M = tc.TestData.M;  U = tc.TestData.U;
    % Two runs (>30 min apart); run 1 straddles the ±180 boundary.
    t = tc.TestData.t0 + [minutes([0 10 20]) hours(5) + minutes([0 10])]';
    truth = [170; 190; 210; 300; 320];
    V.CAND = table(t, "cap_" + string((1:5)'), 20 * ones(5, 1), ...
                   U.wrap_deg(truth), ...
                   'VariableNames', {'timestamp', 'base_name', 'snr_db', 'corr_41622'});
    V.dd_agg.Value = 'Per-run mean';
    kind = 'L2: Candidates Unwrapped — MUOS-5 (41622)';
    soop_viewer_render_l2(V, kind);
    [~, ya_lin] = M.aggregate(t, truth, 'Per-run mean', 'lin');
    [~, ya_cir] = M.aggregate(t, U.wrap_deg(truth), 'Per-run mean', 'phase');
    verifyEqual(tc, phase_ydata(tc, V), ya_lin, 'AbsTol', 1e-9);
    verifyEqual(tc, ya_lin(1), 190, 'AbsTol', 1e-9);
    verifyGreaterThan(tc, max(abs(ya_lin - ya_cir)), 90);   % modes truly differ
    % Hour coloring draws the identical linear aggregate as colored dots.
    V.cb_hourcolor.Value = true;
    delete(allchild(V.panel));
    soop_viewer_render_l2(V, kind);
    hsc = findobj(V.panel, 'Type', 'scatter');
    verifyNumElements(tc, hsc, 1);
    verifyEqual(tc, hsc.YData(:), ya_lin, 'AbsTol', 1e-9);
    % The wrapped twin on the same fixture keeps CIRCULAR aggregation.
    V.cb_hourcolor.Value = false;
    delete(allchild(V.panel));
    soop_viewer_render_l2(V, 'L2: Candidates — MUOS-5 (41622)');
    verifyEqual(tc, phase_ydata(tc, V), ya_cir, 'AbsTol', 1e-9);
end

function test_render_theory_unwrapped_autolim(tc)
    % The theory overlay draws CONTINUOUS on the unwrapped view (past ±180)
    % and the auto left limits contain both the points and the curve.
    V = seeded_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    [V.CAND, truth] = cand_ramp(tc, 30, 50, hours(2));
    wt = tc.TestData.t0 + minutes(15 * (0:280)');
    V.WX = table(wt, linspace(0, 900, 281)', ...
                 'VariableNames', {'timestamp', 'swe_mm'});
    V.cb_swe.Value = true;  V.cb_theory.Value = true;
    V.dd_thanchor.Value = 'First shown';
    V.ef_fringe.Value = '400';   % manual rate (no L2 geometry in fixture)
    V.ef_fringe.UserData = struct('is_auto', false, 'last_auto_text', '', ...
                                  'last_auto_mm', NaN);
    soop_viewer_render_l2(V, 'L2: Candidates Unwrapped — MUOS-5 (41622)');
    th = findobj(V.panel, 'Type', 'line', 'LineStyle', '--');
    verifyNumElements(tc, th, 1);
    verifyGreaterThan(tc, max(th.YData) - min(th.YData), 360);  % continuous
    verifyGreaterThanOrEqual(tc, min(diff(th.YData(isfinite(th.YData)))), ...
                             -1e-9);                            % no saw-tooth
    ax = findobj(V.panel, 'Type', 'axes');
    verifyNumElements(tc, ax, 1);   % SWE owns the right ruler, no overlay axes
    drawnow;
    yl = ax.YLim;                   % yyaxis left is active after the render
    verifyLessThanOrEqual(tc, yl(1), min([truth; th.YData(:)]));
    verifyGreaterThanOrEqual(tc, yl(2), max([truth; th.YData(:)]));
end

function test_render_tod_daily_unwrap(tc)
    % With the daily time-of-day filter on, ONLY the daily picks feed the
    % unwrap: the shown series is the unwrap of the kept samples' wrapped
    % values at ~24 h spacing, not a subset of the full-season unwrap.
    V = seeded_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    U = tc.TestData.U;
    [V.CAND, truth] = cand_ramp(tc, 30, 50, hours(2));
    kind = 'L2: Candidates Unwrapped — MUOS-5 (41622)';
    V.cb_tod.Value = true;
    V.ef_tod.Value = '05:30';
    soop_viewer_render_l2(V, kind);
    ax = findobj(V.panel, 'Type', 'axes');
    h = findobj(ax, 'Type', 'line');
    verifyNumElements(tc, h, 1);
    % Map the plotted picks back to CAND rows by timestamp, then re-derive
    % the expected unwrap from ONLY those rows' wrapped values.
    [tf, loc] = ismember(h.XData(:), V.CAND.timestamp);
    verifyTrue(tc, all(tf));
    verifyGreaterThanOrEqual(tc, numel(loc), 2);       % one pick per day
    expect = U.unwrap_deg(V.CAND.timestamp(loc), U.wrap_deg(truth(loc)));
    verifyEqual(tc, h.YData(:), expect, 'AbsTol', 1e-9);
    % 600 deg/day wraps to -120 deg/day: the daily unwrap walks DOWN and
    % never matches the full-season branch at those samples.
    verifyLessThan(tc, max(h.YData), 180);
    verifyGreaterThan(tc, max(abs(h.YData(:) - truth(loc))), 180);
end

function test_render_chaincal_unwrap(tc)
    % Chain-cal applies row-wise BEFORE the unwrap; an L2-unmatched row goes
    % NaN (dropped from the plot) without resetting the later branch.
    V = seeded_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    U = tc.TestData.U;
    [V.CAND, truth] = cand_ramp(tc, 30, 50, hours(2));
    % L2 chain-cal schema: constant +30 deg delta; row 5 has no L2 match.
    bn = V.CAND.base_name(setdiff(1:30, 5)');
    V.L2 = table(bn, 30 * ones(29, 1), zeros(29, 1), ...
                 'VariableNames', {'base_name', 'phase_corr_cal_deg', 'phase_corr_deg'});
    V.dd_method.Value = V.CHAINCAL_DATASET;
    soop_viewer_render_l2(V, 'L2: Candidates Unwrapped — MUOS-5 (41622)');
    dlt = 30 * ones(30, 1);  dlt(5) = NaN;
    expect = U.unwrap_deg(V.CAND.timestamp, ...
                          U.wrap_deg(U.wrap_deg(truth) + dlt));
    verifyEqual(tc, phase_ydata(tc, V), expect(isfinite(expect)), 'AbsTol', 1e-9);
    ax = findobj(V.panel, 'Type', 'axes');
    verifyTrue(tc, contains(ax.Title.String, 'phase offset cal'));
end

function test_render_domain_column(tc)
    % The unwrapped view resolves the Phase-domain column before unwrapping:
    % with 'fd' selected and the _fd column present, its values are shown.
    V = seeded_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    U = tc.TestData.U;
    [V.CAND, ~] = cand_ramp(tc, 20, 50, hours(2));
    truth_fd = 40 * (0:19)';
    V.CAND.corr_41622_fd = U.wrap_deg(truth_fd);
    V.dd_domain.Value = 'fd';
    soop_viewer_render_l2(V, 'L2: Candidates Unwrapped — MUOS-5 (41622)');
    verifyEqual(tc, phase_ydata(tc, V), truth_fd, 'AbsTol', 1e-9);
    ax = findobj(V.panel, 'Type', 'axes');
    verifyTrue(tc, contains(ax.Title.String, '[fd]'));
end

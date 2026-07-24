function tests = viewer_ovf_filter_test
% Unit tests for the L2: Candidates overflow display filter: the
% soop_viewer_util helpers (ovf_load, ovf_mask, ovf_usable), the composed
% display-selection order (SNR cutoff -> overflow exclusion -> daily
% time-of-day pick -> unwrap input), and seeded production renders of
% soop_viewer_render_l2 / CB.render_now pinning the marking policy, legend
% pairing, title notes, and checkbox Enable gating.
% Run: matlab -batch "soop_setup_paths; addpath('tests'); runtests('viewer_ovf_filter_test')"
    tests = functiontests(localfunctions);
end


function setupOnce(tc)
    tc.TestData.U   = soop_viewer_util();
    tc.TestData.M   = BrundageSoOp_fun();
    tc.TestData.t0  = datetime(2026, 1, 1);
    f = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
    tc.TestData.dir = f.Folder;
end


function d = tmpdir(tc)
% Fresh auto-cleaned temp folder per call.
    f = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
    d = f.Folder;
end


% ---------------------------------------------------------------- ovf_load

function test_load_no_file_anywhere(tc)
    % No overflow file on any path: ok = false ("membership unknowable"),
    % empty bases, empty source.
    U = tc.TestData.U;
    cfg = struct('out_dir', tmpdir(tc));
    [bases, ok, src] = U.ovf_load(cfg, tmpdir(tc));
    verifyFalse(tc, ok);
    verifyEmpty(tc, bases);
    verifyEqual(tc, src, "");
end

function test_load_empty_file_is_ok(tc)
    % An EMPTY list file is found: ok = true with zero bases ("known zero
    % overflows") — distinct from the missing-file case.
    U = tc.TestData.U;
    d = tmpdir(tc);
    p = fullfile(d, 'overflow_timestamps.txt');
    writelines(strings(0, 1), p);
    [bases, ok, src] = U.ovf_load(struct('out_dir', d), '');
    verifyTrue(tc, ok);
    verifyEmpty(tc, bases);
    verifyEqual(tc, src, string(p));
end

function test_load_reads_and_trims(tc)
    % Populated list: blank lines dropped, whitespace trimmed, order kept.
    U = tc.TestData.U;
    d = tmpdir(tc);
    p = fullfile(d, 'overflow_timestamps.txt');
    writelines(["UHF_20260101040001"; ""; "  UHF_20260102040001  "], p);
    [bases, ok] = U.ovf_load(struct('out_dir', d), '');
    verifyTrue(tc, ok);
    verifyEqual(tc, bases, ["UHF_20260101040001"; "UHF_20260102040001"]);
end

function test_load_precedence_overflow_file_first(tc)
    % cfg.overflow_file wins over the out_dir fallback when both exist.
    U = tc.TestData.U;
    d1 = tmpdir(tc);  d2 = tmpdir(tc);
    p1 = fullfile(d1, 'season_overflows.txt');
    writelines("FROM_CFG", p1);
    writelines("FROM_OUTDIR", fullfile(d2, 'overflow_timestamps.txt'));
    cfg = struct('overflow_file', p1, 'out_dir', d2);
    [bases, ok, src] = U.ovf_load(cfg, '');
    verifyTrue(tc, ok);
    verifyEqual(tc, bases, "FROM_CFG");
    verifyEqual(tc, src, string(p1));
end

function test_load_precedence_outdir_then_base(tc)
    % Missing cfg.overflow_file falls to out_dir, then to the base product
    % dir when out_dir has no list either.
    U = tc.TestData.U;
    d_out = tmpdir(tc);  d_base = tmpdir(tc);
    writelines("FROM_BASE", fullfile(d_base, 'overflow_timestamps.txt'));
    cfg = struct('overflow_file', fullfile(d_out, 'nope.txt'), 'out_dir', d_out);
    [bases, ok, src] = U.ovf_load(cfg, d_base);
    verifyTrue(tc, ok);
    verifyEqual(tc, bases, "FROM_BASE");
    verifyEqual(tc, src, string(fullfile(d_base, 'overflow_timestamps.txt')));
    % With a list in out_dir too, out_dir wins over base.
    writelines("FROM_OUTDIR", fullfile(d_out, 'overflow_timestamps.txt'));
    [bases2, ~, src2] = U.ovf_load(cfg, d_base);
    verifyEqual(tc, bases2, "FROM_OUTDIR");
    verifyEqual(tc, src2, string(fullfile(d_out, 'overflow_timestamps.txt')));
end


% ---------------------------------------------------------------- ovf_mask

function T = cand_table(bases, snr)
% Minimal candidates-like table (timestamps ascending minutes).
    n = numel(bases);
    T = table((datetime(2026, 1, 1) + minutes(1:n))', string(bases(:)), snr(:), ...
              'VariableNames', {'timestamp', 'base_name', 'snr_db'});
end

function test_mask_membership_and_order(tc)
    % Mask is a logical column aligned with row order; duplicates of a
    % flagged base all mark true.
    U = tc.TestData.U;
    T = cand_table(["a"; "b"; "a"; "c"], [10 10 10 10]);
    m = U.ovf_mask(T, ["a"; "x"]);
    verifyEqual(tc, m, logical([1; 0; 1; 0]));
end

function test_mask_char_string_tolerant(tc)
    % Cellstr list input matches string base_name values.
    U = tc.TestData.U;
    T = cand_table(["a"; "b"], [10 10]);
    m = U.ovf_mask(T, {'b'});
    verifyEqual(tc, m, logical([0; 1]));
end

function test_mask_failsafe_inputs(tc)
    % Empty table / missing base_name / empty list: all-false, never an
    % error (operator input must not break a render).
    U = tc.TestData.U;
    verifyEmpty(tc, U.ovf_mask(table(), "a"));
    T_nb = table((1:3)', 'VariableNames', {'x'});
    verifyEqual(tc, U.ovf_mask(T_nb, "a"), false(3, 1));
    T = cand_table(["a"; "b"], [10 10]);
    verifyEqual(tc, U.ovf_mask(T, strings(0, 1)), false(2, 1));
end


% -------------------------------------------------------------- ovf_usable

function test_usable_gate(tc)
    % Usable only with (list found) AND (nonempty table carrying base_name).
    U = tc.TestData.U;
    T = cand_table(["a"; "b"], [10 10]);
    verifyTrue(tc, U.ovf_usable(T, true));
    verifyFalse(tc, U.ovf_usable(T, false));            % no list found
    verifyFalse(tc, U.ovf_usable(table(), true));       % empty table
    T_nb = table((1:2)', 'VariableNames', {'x'});
    verifyFalse(tc, U.ovf_usable(T_nb, true));          % no base_name
end


% ------------------------------------- composed display-selection order

function [TC, T] = run_selection(U, T, ovf_bases, excl, tgt, t0, t1)
% Mirror the render's candidate selection order: SNR cutoff (>= 10 dB,
% producer predicate) -> optional overflow exclusion -> widened-pool daily
% time-of-day pick (target-day gated).
    W = hours(1);
    [T, ~] = U.snrcut_apply(T, 10);
    if excl
        T = T(~U.ovf_mask(T, ovf_bases), :);
    end
    Tw = T(T.timestamp >= t0 - W & T.timestamp < t1 + W, :);
    [ix, tday] = U.tod_daily_idx(Tw.timestamp, tgt, W);
    TC = Tw(ix(tday >= t0 & tday < t1), :);
end

function test_exclusion_swaps_daily_pick(tc)
    % Day with an overflow capture at the target and a clean one 20 min
    % away: exclusion swaps the day's pick to the clean capture instead of
    % dropping the day.
    U = tc.TestData.U;
    d = datetime(2026, 1, 5);
    T = table([d + hours(4); d + hours(4) + minutes(20)], ...
              ["OVF_CAP"; "CLEAN_CAP"], [15; 15], ...
              'VariableNames', {'timestamp', 'base_name', 'snr_db'});
    tgt = hours(4);
    TC_in = run_selection(U, T, "OVF_CAP", false, tgt, d, d + days(1));
    verifyEqual(tc, TC_in.base_name, "OVF_CAP");    % included: nearest wins
    TC_ex = run_selection(U, T, "OVF_CAP", true, tgt, d, d + days(1));
    verifyEqual(tc, TC_ex.base_name, "CLEAN_CAP");  % excluded: clean substitute
end

function test_exclusion_drops_day_without_substitute(tc)
    % A day whose only in-window capture is overflow disappears entirely
    % under exclusion (no capture within +-1 h remains).
    U = tc.TestData.U;
    d = datetime(2026, 1, 6);
    T = table([d + hours(4); d + days(1) + hours(4)], ...
              ["ONLY_OVF"; "NEXT_DAY_CLEAN"], [15; 15], ...
              'VariableNames', {'timestamp', 'base_name', 'snr_db'});
    TC = run_selection(U, T, "ONLY_OVF", true, hours(4), d, d + days(2));
    verifyEqual(tc, TC.base_name, "NEXT_DAY_CLEAN");
    verifyNumElements(tc, TC.base_name, 1);
end

function test_exclusion_reanchors_unwrap(tc)
    % Unwrap runs over the RETAINED rows only: excluding the first
    % (overflow) capture re-anchors the unwrapped series at the next one.
    U = tc.TestData.U;
    d = datetime(2026, 1, 7);
    t = [d + hours(4); d + days(1) + hours(4); d + days(2) + hours(4)];
    T = table(t, ["OVF_FIRST"; "c2"; "c3"], [15; 15; 15], [100; 120; 130], ...
              'VariableNames', {'timestamp', 'base_name', 'snr_db', 'ph'});
    % AbsTol absorbs the deg->rad->deg round-trip of unwrap_deg.
    TC_in = run_selection(U, T, "OVF_FIRST", false, hours(4), d, d + days(3));
    u_in  = U.unwrap_deg(TC_in.timestamp, TC_in.ph);
    verifyEqual(tc, u_in(1), 100, 'AbsTol', 1e-9);
    TC_ex = run_selection(U, T, "OVF_FIRST", true, hours(4), d, d + days(3));
    u_ex  = U.unwrap_deg(TC_ex.timestamp, TC_ex.ph);
    verifyEqual(tc, u_ex(1), 120, 'AbsTol', 1e-9);
    verifyNumElements(tc, u_ex, 2);
end

function test_snr_gate_runs_before_overflow(tc)
    % A below-cutoff overflow capture is removed by the SNR gate whether or
    % not exclusion is on; the day's clean above-cutoff capture is picked.
    U = tc.TestData.U;
    d = datetime(2026, 1, 8);
    T = table([d + hours(4); d + hours(4) + minutes(30)], ...
              ["OVF_LOWSNR"; "CLEAN_CAP"], [5; 15], ...
              'VariableNames', {'timestamp', 'base_name', 'snr_db'});
    TC = run_selection(U, T, "OVF_LOWSNR", false, hours(4), d, d + days(1));
    verifyEqual(tc, TC.base_name, "CLEAN_CAP");
end


% ------------------------------------------------- seeded production renders

function V = seeded_viewer(tc)
    % Real viewer state + layout (headless), mirroring viewer_unwrap_test's
    % harness; the overflow tests assign synthetic CAND tables plus the
    % overflow-list state (OVF / OVF_ok / OVF_src) and call
    % soop_viewer_render_l2 directly (or CB.render_now for the gating tests).
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
    V.OVF = strings(0, 1);  V.OVF_ok = false;  V.OVF_src = "";
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

function T = ramp_table(tc, n)
    % Small-slope phase ramp (no wraps: unwrap = identity), 2-hourly
    % captures cap_1..cap_n, all above the SNR gate.
    t = tc.TestData.t0 + hours(2) * (0:n-1)';
    T = table(t, "cap_" + string((1:n)'), 20 * ones(n, 1), 10 * (1:n)', ...
              'VariableNames', {'timestamp', 'base_name', 'snr_db', 'corr_41622'});
end

function h = ovf_handle(V)
    % The red overflow marker handle(s) ([0.850 0.100 0.100] lines).
    h = findobj(V.panel, 'Type', 'line', '-and', 'Color', [0.850 0.100 0.100]);
end

function s = title_str(V)
    ax = findobj(V.panel, 'Type', 'axes');
    s = ax(end).Title.String;
end

function test_render_marks_raw_finite(tc)
    % Raw captures + finite overflow rows: one red marker-only handle at
    % exactly the flagged rows' displayed values, legend paired as
    % {Phase, Overflow}, marker char/size following the phase handle.
    V = seeded_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    V.CAND = ramp_table(tc, 6);
    V.OVF = ["cap_2"; "cap_5"];  V.OVF_ok = true;
    soop_viewer_render_l2(V, 'L2: Candidates Unwrapped — MUOS-5 (41622)');
    h = ovf_handle(V);
    verifyNumElements(tc, h, 1);
    verifyEqual(tc, h.YData(:), [20; 50], 'AbsTol', 1e-9);
    verifyEqual(tc, h.LineStyle, 'none');
    lg = findobj(V.fig, 'Type', 'legend');
    verifyEqual(tc, lg.String, {'Phase', 'Overflow'});
    ax = findobj(V.panel, 'Type', 'axes');
    hp = findobj(ax, 'Type', 'line', '-not', 'Color', [0.850 0.100 0.100]);
    verifyEqual(tc, h.Marker, hp(end).Marker);
    verifyEqual(tc, h.MarkerSize, hp(end).MarkerSize);
end

function test_render_nan_overflow_no_entry(tc)
    % Overflow rows whose displayed phase is NaN draw nothing and feed no
    % aggregate: no red handle, no 'Overflow' legend entry, no title count.
    V = seeded_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    T = ramp_table(tc, 6);
    T.corr_41622(2) = NaN;
    V.CAND = T;  V.OVF = "cap_2";  V.OVF_ok = true;
    soop_viewer_render_l2(V, 'L2: Candidates Unwrapped — MUOS-5 (41622)');
    verifyEmpty(tc, ovf_handle(V));
    lg = findobj(V.fig, 'Type', 'legend');
    verifyFalse(tc, any(strcmp(lg.String, 'Overflow')));
    verifyFalse(tc, contains(title_str(V), 'overflow'));
end

function test_render_aggregate_counts_finite_only(tc)
    % Aggregated mode: no raw red points; the title's included count names
    % only the FINITE overflow contributors (the NaN row is not counted).
    V = seeded_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    T = ramp_table(tc, 6);
    T.corr_41622(3) = NaN;
    V.CAND = T;  V.OVF = ["cap_2"; "cap_3"];  V.OVF_ok = true;
    V.dd_agg.Value = 'Per-run mean';
    soop_viewer_render_l2(V, 'L2: Candidates Unwrapped — MUOS-5 (41622)');
    verifyEmpty(tc, ovf_handle(V));
    verifyTrue(tc, contains(title_str(V), '1 overflow included'));
end

function test_render_exclusion_removes_rows(tc)
    % Checked + usable: flagged rows leave the calculation and display;
    % title says so; no 'Overflow' legend entry.
    V = seeded_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    V.CAND = ramp_table(tc, 6);
    V.OVF = "cap_2";  V.OVF_ok = true;
    V.cb_ovf.Value = true;
    soop_viewer_render_l2(V, 'L2: Candidates Unwrapped — MUOS-5 (41622)');
    ax = findobj(V.panel, 'Type', 'axes');
    hp = findobj(ax, 'Type', 'line');
    verifyNumElements(tc, hp, 1);
    verifyEqual(tc, hp.YData(:), [10; 30; 40; 50; 60], 'AbsTol', 1e-9);
    verifyTrue(tc, contains(title_str(V), 'overflow excluded'));
    lg = findobj(V.fig, 'Type', 'legend');
    verifyFalse(tc, any(strcmp(lg.String, 'Overflow')));
end

function test_render_checked_without_list_never_filters(tc)
    % Stale checked state with no list found (production state: empty OVF,
    % OVF_ok false): nothing is filtered and the title claims nothing.
    V = seeded_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    V.CAND = ramp_table(tc, 6);
    V.cb_ovf.Value = true;              % OVF stays empty, OVF_ok false
    soop_viewer_render_l2(V, 'L2: Candidates Unwrapped — MUOS-5 (41622)');
    ax = findobj(V.panel, 'Type', 'axes');
    hp = findobj(ax, 'Type', 'line');
    verifyNumElements(tc, hp, 1);
    verifyNumElements(tc, hp.YData, 6);
    verifyFalse(tc, contains(title_str(V), 'overflow'));
end

function test_render_hourcolor_fallback_marker(tc)
    % Hour coloring hides the phase markers; the overflow handle falls back
    % to 'o' and still draws over the colored scatter.
    V = seeded_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    V.CAND = ramp_table(tc, 6);
    V.OVF = "cap_4";  V.OVF_ok = true;
    V.cb_hourcolor.Value = true;
    soop_viewer_render_l2(V, 'L2: Candidates Unwrapped — MUOS-5 (41622)');
    h = ovf_handle(V);
    verifyNumElements(tc, h, 1);
    verifyEqual(tc, h.Marker, 'o');
    verifyEqual(tc, h.YData(:), 40, 'AbsTol', 1e-9);
end

function test_render_now_enable_and_tooltip(tc)
    % CB.render_now integration: each Enable state names its own cause in
    % the tooltip — missing list, unusable base_name, then the resolved
    % source path when usable.
    V = seeded_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    V.CAND = ramp_table(tc, 6);
    V.dd_plot.Value = 'L2: Candidates Unwrapped — MUOS-5 (41622)';
    % render_now's side-panel summary stringifies the date pickers — NaT
    % would render as <missing>, so pin a concrete range covering the ramp.
    V.dp1.Value = tc.TestData.t0;
    V.dp2.Value = tc.TestData.t0 + days(1);
    V.CB.render_now(V);                              % no list found
    verifyFalse(tc, logical(V.cb_ovf.Enable));
    verifyTrue(tc, contains(V.cb_ovf.Tooltip, 'No overflow list found'));
    V.OVF_ok = true;  V.OVF_src = "X:\fake\overflow_timestamps.txt";
    T = V.CAND;  T.base_name = (1:6)';               % unusable column type
    V.CAND = T;
    V.CB.render_now(V);
    verifyFalse(tc, logical(V.cb_ovf.Enable));
    verifyTrue(tc, contains(V.cb_ovf.Tooltip, 'base_name'));
    V.CAND = ramp_table(tc, 6);                      % usable again
    V.CB.render_now(V);
    verifyTrue(tc, logical(V.cb_ovf.Enable));
    verifyTrue(tc, contains(V.cb_ovf.Tooltip, 'overflow_timestamps.txt'));
end

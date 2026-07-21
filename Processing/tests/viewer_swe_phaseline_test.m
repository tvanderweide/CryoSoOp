function tests = viewer_swe_phaseline_test
% Tests for the L2: Candidates SWE overlay + phaseLine toggle: load_snodar's
% snow-scale SWE QC chain (error-code mask, spike/support filter, schema
% quadrants, cfg.wx_swe_cols override, row alignment), the pure wx_right_axis
% helper, and the graphics assumptions the render relies on (LineStyle
% toggling, overlay color separation, row-1 pixel budget).
% Run: matlab -batch "soop_setup_paths; addpath('tests'); runtests('viewer_swe_phaseline_test')"
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

function path = write_wx(tc, name, cols, rows)
% Minimal Campbell TOA5 with caller-chosen columns. cols is a cellstr of
% header names (TIMESTAMP prepended automatically); rows is a cell array
% {ts_strings, col1_vals, ...} — values written %.6g, NaN as NAN.
    path = fullfile(tc.TestData.dir, name);
    fid = fopen(path, 'w');
    fprintf(fid, '"TOA5","stn","logger","sn","os","prog","sig","table"\n');
    fprintf(fid, 'TIMESTAMP,%s\n', strjoin(cols, ','));
    fprintf(fid, 'TS%s\n',  repmat(',u', 1, numel(cols)));
    fprintf(fid, 'Smp%s\n', repmat(',Avg', 1, numel(cols)));
    ts = rows{1};
    for i = 1:numel(ts)
        fprintf(fid, '"%s"', char(ts(i)));
        for c = 2:numel(rows)
            fprintf(fid, ',%.6g', rows{c}(i));
        end
        fprintf(fid, '\n');
    end
    fclose(fid);
end

function [ts, base] = regular_series(tc, n)
% n 15-min timestamps and base columns (distance/depth/temps) for fixtures.
    ts = tc.TestData.t0 + minutes(15 * (0:n-1)');
    ts.Format = 'yyyy-MM-dd HH:mm:ss';
    base = {2 * ones(n, 1), ones(n, 1), -5 * ones(n, 1), -4 * ones(n, 1)};
end

function WX = load_fix(tc, name, cols, rows, extra_cfg)
    path = write_wx(tc, name, cols, rows);
    cfg = struct('wx_dat', path);
    if nargin >= 5
        for f = fieldnames(extra_cfg)'
            cfg.(f{1}) = extra_cfg.(f{1});
        end
    end
    WX = tc.TestData.M.load_snodar(cfg);
end

function cols = full_cols()
    cols = {'SnoDAR_distance_Avg', 'SnoDAR_snow_depth_Avg', 'AirTC_Avg', ...
            'Temp_C_Avg', 'SS_SWE_Avg', 'SS_SWE_ErrCode_Avg'};
end


% ------------------------------------------------------------ load_snodar QC

function test_errcode_mask_fail_closed(tc)
    % With the errcode column present, SWE survives ONLY where the errcode is
    % finite and exactly 0: nonzero (incl. fractional averages), NaN, and Inf
    % error states all mask. ±Inf SWE normalizes to NaN even at errcode 0.
    n = 40;
    [ts, base] = regular_series(tc, n);
    swe = 500 * ones(n, 1);
    err = zeros(n, 1);
    err(5) = 2000;  err(6) = 133.3;  err(7) = NaN;  err(8) = Inf;
    swe(9) = Inf;   % bad value, clean errcode
    WX = load_fix(tc, 'errmask.dat', full_cols(), {ts, base{:}, swe, err}); %#ok<CCAT>
    verifyTrue(tc, all(isnan(WX.swe_mm([5 6 7 8 9]))));
    keep = true(n, 1);  keep([5 6 7 8 9]) = false;
    verifyEqual(tc, WX.swe_mm(keep), 500 * ones(n - 5, 1));
end

function test_spike_removed_monotone_kept(tc)
    % Isolated blip > 100 mm off the local median masks; an INTERIOR monotone
    % melt staircase (45 mm steps) is untouched (the median tracks monotone
    % runs). Fixture: flat 1000 mm, one +175 blip, then a 45 mm/step decline
    % bracketed by flat runs so every staircase sample has a full window.
    flat1 = 1000 * ones(100, 1);
    stair = (1000:-45:100)';                   % 21 samples, well inside
    flat2 = 100 * ones(100, 1);
    swe   = [flat1; stair; flat2];
    swe(50) = 1175;                            % isolated +175 blip
    n = numel(swe);
    [ts, base] = regular_series(tc, n);
    WX = load_fix(tc, 'spike.dat', full_cols(), {ts, base{:}, swe, zeros(n, 1)}); %#ok<CCAT>
    verifyTrue(tc, isnan(WX.swe_mm(50)), 'isolated blip must mask');
    rest = swe;  rest(50) = NaN;
    verifyEqual(tc, WX.swe_mm, rest, 'everything else must survive verbatim');
end

function test_spike_threshold_boundary(tc)
    % The contract is STRICT > 100 mm: a deviation of exactly 100 mm from
    % the local median survives; just above masks.
    n = 120;
    [ts, base] = regular_series(tc, n);
    swe = 500 * ones(n, 1);
    swe(30) = 600;                             % dev exactly 100 — keep
    swe(90) = 601.5;                           % dev 101.5 — mask
    WX = load_fix(tc, 'thresh.dat', full_cols(), {ts, base{:}, swe, zeros(n, 1)}); %#ok<CCAT>
    verifyEqual(tc, WX.swe_mm(30), 600, 'deviation == threshold must survive');
    verifyTrue(tc, isnan(WX.swe_mm(90)), 'deviation just above must mask');
end

function test_boundary_ramp_pinned(tc)
    % Documented endpoint behavior: a steep sustained ramp starting AT the
    % record boundary sees a one-sided shrinking window, so its earliest
    % samples deviate > 100 mm from the window median and are masked. Pinned
    % here so the contract is explicit (real season boundaries are flat).
    ramp = (0:45:45*119)';                     % 120 samples, no padding
    n = numel(ramp);
    [ts, base] = regular_series(tc, n);
    WX = load_fix(tc, 'ramp.dat', full_cols(), {ts, base{:}, ramp, zeros(n, 1)}); %#ok<CCAT>
    verifyTrue(tc, isnan(WX.swe_mm(1)), 'boundary ramp start is flagged');
    verifyEqual(tc, WX.swe_mm(49:72), ramp(49:72), ...
                'full-window interior of the ramp survives');
    verifyTrue(tc, isnan(WX.swe_mm(end)), 'boundary ramp end is flagged too');
end

function test_plateau_survives(tc)
    % Documented limitation: a LONG corrupt plateau (> half the window)
    % becomes its own median and survives the deviation test — only the
    % error-code mask can remove sustained bad data.
    swe = 200 * ones(260, 1);
    swe(101:160) = 700;                        % 60-sample plateau, +500
    n = numel(swe);
    [ts, base] = regular_series(tc, n);
    WX = load_fix(tc, 'plateau.dat', full_cols(), {ts, base{:}, swe, zeros(n, 1)}); %#ok<CCAT>
    verifyEqual(tc, WX.swe_mm(130), 700, 'plateau center survives (limitation)');
end

function test_min_support_masks_sparse(tc)
    % A finite value with < 13 finite neighbors in its 97-sample window is
    % unverifiable and masks — an isolated survivor amid an error gap would
    % otherwise be its own median.
    n = 200;
    [ts, base] = regular_series(tc, n);
    swe = 600 * ones(n, 1);
    err = 2000 * ones(n, 1);                   % everything erroring...
    err(100) = 0;                              % ...except one clean sample
    WX = load_fix(tc, 'sparse.dat', full_cols(), {ts, base{:}, swe, err}); %#ok<CCAT>
    verifyTrue(tc, all(isnan(WX.swe_mm)), 'lone clean sample lacks support');
end

function test_schema_quadrants(tc)
    n = 30;
    [ts, base] = regular_series(tc, n);
    swe = 400 * ones(n, 1);
    % (a) both SWE columns absent: swe_mm present, all-NaN, NO warning.
    cols4 = full_cols();  cols4 = cols4(1:4);
    lastwarn('');
    WX = load_fix(tc, 'nosw.dat', cols4, {ts, base{:}}); %#ok<CCAT>
    verifyTrue(tc, ismember('swe_mm', WX.Properties.VariableNames));
    verifyTrue(tc, all(isnan(WX.swe_mm)));
    verifyEqual(tc, lastwarn(), '', 'optional sensor must load silently');
    % (b) value column without errcode column: kept unmasked + one warning.
    cols5 = [cols4, {'SS_SWE_Avg'}];
    WX = verifyWarning(tc, ...
        @() load_fix(tc, 'noerr.dat', cols5, {ts, base{:}, swe}), ...
        'BrundageSoOp:snodar'); %#ok<CCAT>
    verifyEqual(tc, WX.swe_mm, swe);
    % (c) errcode column without value column: all-NaN, silent.
    cols5e = [cols4, {'SS_SWE_ErrCode_Avg'}];
    lastwarn('');
    WX = load_fix(tc, 'noval.dat', cols5e, {ts, base{:}, zeros(n, 1)}); %#ok<CCAT>
    verifyTrue(tc, all(isnan(WX.swe_mm)));
    verifyEqual(tc, lastwarn(), '');
end

function test_wx_swe_cols_override(tc)
    % cfg.wx_swe_cols renames both headers; default names then don't match.
    n = 30;
    [ts, base] = regular_series(tc, n);
    swe = 250 * ones(n, 1);
    cols = full_cols();  cols{5} = 'SWE_K_Avg';  cols{6} = 'SWE_K_Err';
    WX = load_fix(tc, 'ovr.dat', cols, {ts, base{:}, swe, zeros(n, 1)}, ...
                  struct('wx_swe_cols', {{'SWE_K_Avg', 'SWE_K_Err'}})); %#ok<CCAT>
    verifyEqual(tc, WX.swe_mm, swe);
end

function test_row_alignment_after_bad_ts(tc)
    % An empty-timestamp row (the loader's NaT-drop path) drops from every
    % column together — SWE values stay bound to their own timestamps
    % (distinguishable ramp). Note truly malformed timestamp TEXT aborts the
    % whole load (datetime + InputFormat errors → catch → empty WX), so the
    % empty string is the representative droppable row.
    n = 20;
    [ts, base] = regular_series(tc, n);
    swe = 500 + (1:n)';                        % 1 mm/row: distinguishable,
    tstr = cellstr(string(ts));                % far below the spike threshold
    tstr{7} = '';
    path = fullfile(tc.TestData.dir, 'align.dat');
    fid = fopen(path, 'w');
    fprintf(fid, '"TOA5","stn","logger","sn","os","prog","sig","table"\n');
    fprintf(fid, 'TIMESTAMP,%s\n', strjoin(full_cols(), ','));
    fprintf(fid, 'TS,u,u,u,u,u,u\nSmp,Avg,Avg,Avg,Avg,Avg,Avg\n');
    for i = 1:n
        fprintf(fid, '"%s",%.6g,%.6g,%.6g,%.6g,%.6g,0\n', tstr{i}, ...
                base{1}(i), base{2}(i), base{3}(i), base{4}(i), swe(i));
    end
    fclose(fid);
    WX = tc.TestData.M.load_snodar(struct('wx_dat', path));
    verifyEqual(tc, height(WX), n - 1);
    keep = [1:6 8:n]';
    verifyEqual(tc, WX.timestamp, ts(keep));
    verifyEqual(tc, WX.swe_mm, swe(keep));
end


% ------------------------------------------------------------- wx_right_axis

function test_wx_right_axis_matrix(tc)
    % Depth-only keeps today's meters/red contract; any SWE display flips
    % the shared ruler to mm (depth joins via dep_factor 1000) with the
    % unit-aware ylim padding (0.1 m vs 100 mm).
    U = tc.TestData.U;
    dep = [1; 3.8; NaN];  swe = [200; 1400; NaN];   % swe now in mm
    R = U.wx_right_axis(true, false, dep, swe);
    verifyTrue(tc, R.active);
    verifyEqual(tc, R.label, 'Snow depth (m)');
    verifyEqual(tc, R.color, [0.8 0 0]);          % today's depth-only red
    verifyEqual(tc, R.dep_factor, 1);
    verifyEqual(tc, R.pad, 0.1);
    verifyEqual(tc, R.ymax, 3.8);
    R = U.wx_right_axis(false, true, dep, swe);
    verifyEqual(tc, R.label, 'SWE [mm]');
    verifyEqual(tc, R.color, [0.2 0.2 0.2]);
    verifyEqual(tc, R.dep_factor, 1000);
    verifyEqual(tc, R.pad, 100);
    verifyEqual(tc, R.ymax, 1400);
    R = U.wx_right_axis(true, true, dep, swe);
    verifyEqual(tc, R.label, 'Snow depth / SWE [mm]');
    verifyEqual(tc, R.ymax, 3800);                % depth in mm wins the max
    R = U.wx_right_axis(false, false, dep, swe);
    verifyFalse(tc, R.active);
    verifyTrue(tc, isnan(R.ymax));
    R = U.wx_right_axis(false, true, dep, zeros(3, 1));
    verifyEqual(tc, R.ymax, 0);                   % all-zero SWE: the 100 mm
    verifyEqual(tc, R.pad, 100);                  % pad keeps a usable ruler
    R = U.wx_right_axis(true, false, [NaN; NaN], swe);
    verifyTrue(tc, isnan(R.ymax), 'all-NaN shown series gives NaN ymax');
end


% -------------------------------------------- theoretical phase-from-SWE

function test_swe_per_fringe_values(tc)
    % Calibration anchor 606 mm @ (260 MHz, 43 deg); scales as 1/f and
    % cos(theta); Brundage spot-check ~364 mm @ (370 MHz, 51.2 deg).
    U = tc.TestData.U;
    verifyEqual(tc, U.swe_per_fringe_mm(260e6, 43), 606, 'AbsTol', 1e-9);
    verifyEqual(tc, U.swe_per_fringe_mm(520e6, 43), 303, 'AbsTol', 1e-9);
    r = U.swe_per_fringe_mm(260e6, 0) / 606;
    verifyEqual(tc, r, 1 / cosd(43), 'AbsTol', 1e-12);
    verifyEqual(tc, U.swe_per_fringe_mm(370e6, 51.2), ...
                606 * (260 / 370) * cosd(51.2) / cosd(43), 'AbsTol', 1e-9);
    verifyEqual(tc, round(U.swe_per_fringe_mm(370e6, 51.2)), 365);
end

function test_swe_per_fringe_guards(tc)
    % Invalid input -> NaN (fail closed), never an error: nonpositive/
    % nonfinite/nonscalar/complex f; negative, >= 90, or nonfinite theta.
    U = tc.TestData.U;
    bad = {{0, 43}, {-260e6, 43}, {NaN, 43}, {Inf, 43}, {[260e6 260e6], 43}, ...
           {260e6 + 1i, 43}, {'f', 43}, {260e6, -5}, {260e6, 90}, ...
           {260e6, 120}, {260e6, NaN}, {260e6, [10 20]}};
    for k = 1:numel(bad)
        verifyTrue(tc, isnan(U.swe_per_fringe_mm(bad{k}{1}, bad{k}{2})), ...
                   sprintf('case %d', k));
    end
    verifyTrue(tc, isa(U.swe_per_fringe_mm(int32(260e6), 43), 'double'));
end

function test_theory_overlay_first_shown(tc)
    % 'first' mode: the curve passes through the first finite displayed
    % phase, with slope 360/fringe per mm of SWE (paper-positive), wrapped.
    U = tc.TestData.U;
    d = datetime(2026, 1, 1);
    wt = d + minutes(15 * (0:99)');
    sw = linspace(0, 200, 100)';               % SWE ramp 0 -> 200 mm
    ct = [d + minutes(10); d + days(1)];
    cp = [40; NaN];                            % NaN rows must be skipped
    O = U.theory_overlay(ct, cp, wt, sw, 'first', 400);
    verifyTrue(tc, O.ok);
    verifyEqual(tc, O.anchor_note, '');
    % Anchor = nearest SWE sample to the 00:10 capture (the 00:15 sample,
    % row 2): the curve passes through phase_ref exactly at its anchor row.
    verifyEqual(tc, O.phi_deg(2), 40, 'AbsTol', 1e-9);   % at its own anchor
    verifyEqual(tc, O.phi_deg(end), ...
                U.wrap_deg(40 + 360 * (sw(end) - sw(2)) / 400), 'AbsTol', 1e-9);
end

function test_theory_overlay_wrap_and_multifringe(tc)
    % A multi-fringe season wraps (sawtooth, all values in (-180, 180]).
    U = tc.TestData.U;
    d = datetime(2026, 1, 1);
    wt = d + minutes(15 * (0:199)');
    sw = linspace(0, 1400, 200)';              % > 3 fringes at 400 mm
    O = U.theory_overlay(d, 0, wt, sw, 'first', 400);
    verifyTrue(tc, O.ok);
    verifyTrue(tc, all(O.phi_deg > -180 - 1e-9 & O.phi_deg <= 180 + 1e-9));
    verifyGreaterThan(tc, sum(abs(diff(O.phi_deg)) > 180), 2, ...
                      'expect >= 3 wrap jumps across 3.5 fringes');
end

function test_theory_overlay_swe0_and_fallback(tc)
    % 'swe0': anchors at the first >= 4-consecutive |SWE| <= 10 mm run —
    % isolated lows and negatives beyond +-10 don't qualify; without any
    % qualifying run the record-start fallback is taken AND flagged.
    U = tc.TestData.U;
    d = datetime(2026, 1, 1);
    wt = d + minutes(15 * (0:59)');
    sw = 500 * ones(60, 1);
    sw(10) = 0;                                % isolated low: must NOT anchor
    sw(30:35) = 5;                             % the qualifying run
    ct = d + minutes(15 * 30);  cp = -20;      % displayed phase near the run
    O = U.theory_overlay(ct, cp, wt, sw, 'swe0', 400);
    verifyTrue(tc, O.ok);
    verifyEqual(tc, O.anchor_note, '');
    i30 = 31;                                  % row of the run start
    verifyEqual(tc, O.phi_deg(i30), -20, 'AbsTol', 1e-9);
    % No qualifying run: fallback anchors at the record start, flagged.
    sw2 = 500 * ones(60, 1);  sw2(10) = 0;
    O2 = U.theory_overlay(ct, cp, wt, sw2, 'swe0', 400);
    verifyTrue(tc, O2.ok);
    verifyEqual(tc, O2.anchor_note, ', record-start anchor');
end

function test_theory_overlay_gap_handling(tc)
    % Finding-1 contract: O.t keeps the FULL chronology and invalid-SWE
    % rows return NaN phase (the drawn line breaks at QC gaps); the
    % snow-free run requires 4 consecutive VALID rows spanning <= 2 h — a
    % NaN row or a timestamp gap splits it (fallback fires, flagged).
    U = tc.TestData.U;
    d = datetime(2026, 1, 1);
    % NaN inside the low run: [0 NaN 0 0 0] must NOT count as 4-support.
    wt = d + minutes(15 * (0:4)');
    sw = [0; NaN; 0; 0; 0];
    O = U.theory_overlay(d, 10, wt, sw, 'swe0', 400);
    verifyTrue(tc, O.ok);
    verifyEqual(tc, O.anchor_note, ', record-start anchor');
    verifyEqual(tc, numel(O.phi_deg), 5, 'full chronology kept');
    verifyTrue(tc, isnan(O.phi_deg(2)), 'invalid row stays a NaN break');
    % Four low samples one day apart: consecutive rows but a 3-day span —
    % not one hour of support.
    wt2 = d + days(0:3)';
    O2 = U.theory_overlay(d, 10, wt2, zeros(4, 1), 'swe0', 400);
    verifyTrue(tc, O2.ok);
    verifyEqual(tc, O2.anchor_note, ', record-start anchor');
end

function test_theory_overlay_short_records(tc)
    % Finding-2 contract: 0-3 finite samples and mismatched lengths follow
    % the fail-closed/fallback paths — never a MATLAB size error.
    U = tc.TestData.U;
    d = datetime(2026, 1, 1);
    for n = 1:3
        wt = d + minutes(15 * (0:n-1)');
        O = U.theory_overlay(d, 10, wt, zeros(n, 1), 'swe0', 400);
        verifyTrue(tc, O.ok, sprintf('n=%d', n));       % fallback anchor
        verifyEqual(tc, O.anchor_note, ', record-start anchor');
    end
    O = U.theory_overlay(d, 10, datetime.empty(0, 1), [], 'swe0', 400);
    verifyFalse(tc, O.ok);
    O = U.theory_overlay(d, 10, d + minutes([0 15])', 0, 'swe0', 400);
    verifyFalse(tc, O.ok);                              % length mismatch
    verifyEqual(tc, O.why, 'mismatched input lengths');
    O = U.theory_overlay([d; d + hours(1)], 10, d, 0, 'first', 400);
    verifyFalse(tc, O.ok);                              % cand mismatch too
end

function test_theory_overlay_wrap_boundary_and_negative(tc)
    % Exact wrap convention [-180, 180): a point landing on +180 maps to
    % -180; negative dSWE slopes the curve the other way.
    U = tc.TestData.U;
    d = datetime(2026, 1, 1);
    wt = d + minutes(15 * (0:1)');
    O = U.theory_overlay(d, 0, wt, [0; 200], 'first', 400);   % +180 exactly
    verifyTrue(tc, O.ok);
    verifyEqual(tc, O.phi_deg(2), -180, 'AbsTol', 1e-9);
    O = U.theory_overlay(d, 0, wt, [100; 50], 'first', 400);  % melt: -45 deg
    verifyEqual(tc, O.phi_deg(2), -45, 'AbsTol', 1e-9);
end

function test_wx_right_axis_negative_only(tc)
    % Finding-3 contract: a negative-only shown series clamps ymax to 0 so
    % the render's [0, ymax*1.1 + pad] limit stays increasing ([0, pad]).
    U = tc.TestData.U;
    R = U.wx_right_axis(false, true, [], [-500; -300]);
    verifyEqual(tc, R.ymax, 0);
    hi = R.ymax * 1.1 + R.pad;
    verifyGreaterThan(tc, hi, 0);
    R = U.wx_right_axis(true, false, [-2; -1], []);
    verifyEqual(tc, R.ymax, 0, 'depth-only clamps too');
end

function test_fringe_pick(tc)
    % Side-panel override contract: positive finite numbers win; empty,
    % non-numeric, zero, negative, and NaN fall back to the auto rate.
    U = tc.TestData.U;
    [mm, man] = U.fringe_pick('392', 365);
    verifyEqual(tc, mm, 392);  verifyTrue(tc, man);
    [mm, man] = U.fringe_pick('  406.5 ', 365);
    verifyEqual(tc, mm, 406.5);  verifyTrue(tc, man);
    for bad = {'', '(auto)', 'abc', '0', '-5', 'NaN', 'Inf'}
        [mm, man] = U.fringe_pick(bad{1}, 365);
        verifyEqual(tc, mm, 365, sprintf('input "%s"', bad{1}));
        verifyFalse(tc, man);
    end
    [mm, ~] = U.fringe_pick('100', NaN);   % override still wins over NaN auto
    verifyEqual(tc, mm, 100);
end

function test_theory_overlay_guards(tc)
    % Availability contract: separation limits, missing data, bad fringe ->
    % ok = false with a reason; unknown mode is a caller-bug error.
    U = tc.TestData.U;
    d = datetime(2026, 1, 1);
    wt = d + minutes(15 * (0:19)');  sw = 300 * ones(20, 1);
    ok_ct = d;  ok_cp = 10;
    O = U.theory_overlay(ok_ct + days(30), ok_cp, wt, sw, 'first', 400);
    verifyFalse(tc, O.ok);                     % first capture > 2 h from SWE
    O = U.theory_overlay(ok_ct + days(30), ok_cp, wt, sw, 'swe0', 400);
    verifyFalse(tc, O.ok);                     % anchor phase > 7 days away
    O = U.theory_overlay(ok_ct, ok_cp, wt, nan(20, 1), 'first', 400);
    verifyFalse(tc, O.ok);
    O = U.theory_overlay(ok_ct, NaN, wt, sw, 'first', 400);
    verifyFalse(tc, O.ok);
    for fr = {NaN, 0, -400, Inf}
        O = U.theory_overlay(ok_ct, ok_cp, wt, sw, 'first', fr{1});
        verifyFalse(tc, O.ok, sprintf('fringe %g', fr{1}));
    end
    verifyError(tc, @() U.theory_overlay(ok_ct, ok_cp, wt, sw, 'nope', 400), ...
                'soop_viewer_util:theory_overlay:mode');
end


% ------------------------------------------------------- SNR display cutoff

function test_snrcut_predicate(tc)
    % Exactly the producer predicate: isfinite(snr_db) & snr_db >= cut,
    % row order preserved; NaN and BOTH infinities drop.
    U = tc.TestData.U;
    T = table((1:6)', [12; NaN; Inf; -Inf; 10; 9.9], ...
              'VariableNames', {'row', 'snr_db'});
    [Tf, ok] = U.snrcut_apply(T, 10);
    verifyTrue(tc, ok);
    verifyEqual(tc, Tf.row, [1; 5]);              % order kept, 10 >= 10 kept
    [Tf, ok] = U.snrcut_apply(T, -100);           % low cut still drops nonfinite
    verifyTrue(tc, ok);
    verifyEqual(tc, Tf.row, [1; 5; 6]);
end

function test_snrcut_unusable_and_invalid(tc)
    % Unusable tables and invalid cutoffs are controlled no-ops (ok=false,
    % input unchanged) — never an operator error.
    U = tc.TestData.U;
    good = table(1, 12, 'VariableNames', {'row', 'snr_db'});
    for bad = {[], table(1, 'VariableNames', {'row'}), ...
               table(1, "hi", 'VariableNames', {'row', 'snr_db'})}
        verifyFalse(tc, U.snrcut_usable(bad{1}));
        [out, ok] = U.snrcut_apply(bad{1}, 10);
        verifyFalse(tc, ok);
        verifyEqual(tc, out, bad{1});
    end
    verifyTrue(tc, U.snrcut_usable(good));
    for badcut = {NaN, Inf, [5 10], 'a'}
        [out, ok] = U.snrcut_apply(good, badcut{1});
        verifyFalse(tc, ok);
        verifyEqual(tc, out, good);
    end
end

function test_snrcut_start_validation(tc)
    % Spinner starting value: real finite numeric scalar cfg.snr_threshold,
    % else the pipeline default 10 (missing field, NaN, Inf, vector, char).
    U = tc.TestData.U;
    verifyEqual(tc, U.snrcut_start(struct()), 10);
    verifyEqual(tc, U.snrcut_start(struct('snr_threshold', 14)), 14);
    verifyEqual(tc, U.snrcut_start(struct('snr_threshold', int8(7))), 7);
    for bad = {NaN, Inf, [5 10], 'x', []}
        verifyEqual(tc, U.snrcut_start(struct('snr_threshold', bad{1})), 10);
    end
end

function test_snrcut_before_daily_pick(tc)
    % Composition pinning the render's order (cutoff BEFORE the daily
    % nearest pick): a day whose nearest capture fails the cutoff selects
    % the farther PASSING capture; a day with no passing capture vanishes.
    U = tc.TestData.U;
    d1 = datetime(2026, 1, 10);  d2 = datetime(2026, 1, 11);
    t   = [d1 + hours(6) + minutes(10);    % day 1 nearest, snr 5 (fails)
           d1 + hours(6) + minutes(40);    % day 1 farther, snr 15 (passes)
           d2 + hours(6) + minutes(5)];    % day 2 only, snr 3 (fails)
    T = table(t, [5; 15; 3], 'VariableNames', {'timestamp', 'snr_db'});
    [Tf, ok] = U.snrcut_apply(T, 10);
    verifyTrue(tc, ok);
    [ix, tday] = U.tod_daily_idx(Tf.timestamp, hours(6), hours(1));
    verifyEqual(tc, Tf.timestamp(ix), d1 + hours(6) + minutes(40));
    verifyEqual(tc, tday, d1);                    % day 2 dropped entirely
end


% --------------------------------------------- per-site wx column plumbing

function test_wx_temp_blank_entry_loader(tc)
    % load_snodar applies the SAME per-entry blank fallback as
    % wx_temp_labels: a blank first entry loads the default AirTC_Avg
    % header, so the checkbox label always names the loaded column.
    n = 20;
    [ts, base] = regular_series(tc, n);
    WX = load_fix(tc, 'blank.dat', full_cols(), ...
                  {ts, base{:}, 400 * ones(n, 1), zeros(n, 1)}, ...
                  struct('wx_temp_cols', {{'  ', 'Temp_C_Avg'}})); %#ok<CCAT>
    verifyEqual(tc, WX.airtc_c, -5 * ones(n, 1), ...
        'blank entry must fall back to the default header, not miss');
end

function test_wx_depth_cols_override(tc)
    % Renamed distance/depth headers load via cfg.wx_depth_cols; both depth
    % headers are REQUIRED — a missing one returns an empty WX (documented
    % all-or-nothing contract; every overlay unavailable).
    n = 20;
    [ts, base] = regular_series(tc, n);
    cols = full_cols();  cols{1} = 'Dist_K_Avg';  cols{2} = 'Depth_K_Avg';
    WX = load_fix(tc, 'dovr.dat', cols, ...
                  {ts, base{:}, 400 * ones(n, 1), zeros(n, 1)}, ...
                  struct('wx_depth_cols', {{'Dist_K_Avg', 'Depth_K_Avg'}})); %#ok<CCAT>
    verifyEqual(tc, height(WX), n);
    verifyEqual(tc, WX.depth_m, ones(n, 1));
    % Same file WITHOUT the override: default headers absent -> empty WX.
    WX2 = load_fix(tc, 'dovr.dat', cols, ...
                   {ts, base{:}, 400 * ones(n, 1), zeros(n, 1)}); %#ok<CCAT>
    verifyTrue(tc, isempty(WX2));
end

function test_wx_temp_labels_policy(tc)
    % Defaults, per-site override, blank entries keep defaults, and the
    % MIDDLE truncation (first 6 + ellipsis + last 6, 13 display chars)
    % that preserves the distinguishing suffixes station schemes put at
    % the end. Second output = full names for the checkbox tooltips.
    U = tc.TestData.U;
    verifyEqual(tc, U.wx_temp_labels(struct()), {'AirTC_Avg', 'Temp_C_Avg'});
    L = U.wx_temp_labels(struct('wx_temp_cols', {{'T_Air', 'T_Snow'}}));
    verifyEqual(tc, L, {'T_Air', 'T_Snow'});
    L = U.wx_temp_labels(struct('wx_temp_cols', {{'  ', 'T_Snow'}}));
    verifyEqual(tc, L{1}, 'AirTC_Avg');
    [L, full] = U.wx_temp_labels(struct('wx_temp_cols', ...
        {{'Temperature_Air_2m_Avg', 'Temperature_Snow_Srf_Avg'}}));
    verifyEqual(tc, L{1}, ['Temper' char(8230) '2m_Avg']);
    verifyEqual(tc, L{2}, ['Temper' char(8230) 'rf_Avg']);
    verifyFalse(tc, strcmp(L{1}, L{2}), ...
        'shared-prefix headers must stay distinguishable after truncation');
    verifyEqual(tc, full, {'Temperature_Air_2m_Avg', 'Temperature_Snow_Srf_Avg'});
    [L, full] = U.wx_temp_labels(struct());     % full mirrors defaults too
    verifyEqual(tc, full, L);
end

function test_snrcut_spinner_construction(tc)
    % The production Limits expression must accept every validated start —
    % including NEGATIVE thresholds the pipeline allows (a start outside
    % Limits errors uispinner construction and kills the whole viewer).
    U = tc.TestData.U;
    fig = uifigure('Visible', 'off');
    cleanup = onCleanup(@() delete(fig));
    for thr = {-5, 0, 10, 75.5}
        snr0 = U.snrcut_start(struct('snr_threshold', thr{1}));
        sp = uispinner(fig, 'Limits', [min(0, floor(snr0)) max(60, ceil(snr0))], ...
                       'Step', 1, 'Value', snr0, 'ValueDisplayFormat', '%g');
        verifyEqual(tc, sp.Value, snr0, sprintf('start %g', thr{1}));
        delete(sp);
    end
end

function test_snrcut_empty_state_predicate(tc)
    % The TOD empty-state hint compares the FULLY SELECTED populations:
    % a passing-but-off-time capture keeps the ±window subset nonempty, yet
    % the unfiltered selection (not the window) is what proves the cutoff
    % removed the day's would-be pick. Mirrors the render's exact calls.
    U = tc.TestData.U;
    d = datetime(2026, 1, 10);
    t   = [d + hours(2);                      % passes SNR, outside ±1 h TOD
           d + hours(6) + minutes(10)];       % TOD-eligible, fails cutoff
    T = table(t, [15; 5], 'VariableNames', {'timestamp', 'snr_db'});
    t0 = d;  t1 = d + days(1);  W = hours(1);  tgt = hours(6);
    sel = @(T) subset_sel(U, T, t0, t1, tgt, W);
    verifyFalse(tc, isempty(sel(T)), 'unfiltered selection picks 06:10');
    [Tf, ok] = U.snrcut_apply(T, 10);
    verifyTrue(tc, ok);
    win = Tf(Tf.timestamp >= t0 - W & Tf.timestamp < t1 + W, :);
    verifyFalse(tc, isempty(win), 'window still holds the off-time row');
    verifyTrue(tc, isempty(sel(Tf)), 'filtered selection is empty');
    % => hint must fire (unfiltered sel nonempty), though the window is not
    % empty — the render now keys the hint on exactly this comparison.
end

function TC = subset_sel(U, T, t0, t1, tgt, W)
% The render's TOD selection, verbatim: ±window subset → daily pick →
% target-day range mask.
    Tw = T(T.timestamp >= t0 - W & T.timestamp < t1 + W, :);
    [ix, tday] = U.tod_daily_idx(Tw.timestamp, tgt, W);
    TC = Tw(ix(tday >= t0 & tday < t1), :);
end

function test_site_configs_parse(tc)
    % Both shipped site configs parse and carry the weather column keys; the
    % BrundageSoOp.m guard expression maps null -> unset (loader defaults).
    root = fileparts(which('soop_setup_paths'));
    for f = {'site_config.json', 'site_config_CSSL.json'}
        site = jsondecode(fileread(fullfile(root, f{1})));
        verifyTrue(tc, isfield(site.weather, 'wx_depth_cols'), f{1});
        verifyTrue(tc, isfield(site.weather, 'wx_swe_cols'), f{1});
        wired = isfield(site.weather, 'wx_swe_cols') && ...
                ~isempty(site.weather.wx_swe_cols);
        if strcmp(f{1}, 'site_config.json')
            verifyTrue(tc, wired);
            verifyEqual(tc, numel(site.weather.wx_swe_cols), 2, f{1});
            verifyEqual(tc, numel(site.weather.wx_depth_cols), 2, f{1});
        else
            verifyFalse(tc, wired, 'CSSL nulls must map to loader defaults');
        end
    end
end


% --------------------------------- candidates family / hour color / latch

function test_is_cand_kind(tc)
    U = tc.TestData.U;
    for k = {'L2: Sensor data', 'L2: Candidates — MUOS-1 (38093)', ...
             'L2: Candidates — MUOS-5 (41622)'}
        verifyTrue(tc, U.is_cand_kind(k{1}), k{1});
        verifyTrue(tc, U.plot_uses_domain(k{1}), k{1});
    end
    for k = {'L2: Diurnal Phase — raw (no correction)', 'Raw: Time domain', ...
             'L2: Candidate', ''}
        verifyFalse(tc, U.is_cand_kind(k{1}));
    end
end

function test_catalog_sensor_data_entry(tc)
    % Exactly one renamed entry, the old name gone, PLOT_MATH row attached.
    cfg = struct('freq_hz', 370e6, 'fs', 20e6, 'num_segs', 2, 'Ti', 0.9, ...
                 'peak_lag', -0.575, 'T_load_K', 290);
    [PI, ~] = soop_viewer_catalog(cfg);
    names = {PI.name};
    verifyEqual(tc, sum(strcmp(names, 'L2: Sensor data')), 1);
    verifyFalse(tc, any(contains(names, 'raw (no correction)') & ...
                        startsWith(names, 'L2: Candidates')));
    i = find(strcmp(names, 'L2: Sensor data'), 1);
    verifyTrue(tc, PI(i).uses_agg);
    verifyTrue(tc, strlength(PI(i).math) > 0, 'PLOT_MATH row must attach');
end

function test_hour_bins(tc)
    U = tc.TestData.U;
    d = datetime(2026, 1, 5);
    t = [d + hours(6); d + hours(6) + minutes(29); d + hours(6) + minutes(31); ...
         d + hours(23) + minutes(40); d + hours(0) + minutes(10); NaT];
    h = U.hour_bins(t);
    verifyEqual(tc, h(1:5), [6; 6; 7; 0; 0]);   % :31 rounds up, 23:40 wraps
    verifyTrue(tc, isnan(h(6)));
    verifyEqual(tc, size(U.hour_bins(t')), size(t'), 'shape follows input');
end

function test_fringe_latch_state_machine(tc)
    % Provenance-tracked field latch: auto populates/updates the display
    % but passes the UNROUNDED value; manual text is never clobbered and
    % wins even over NaN auto; invalid manual falls back to the auto VALUE
    % without flipping provenance; NaN auto blanks an auto-mode field.
    U = tc.TestData.U;
    A = U.fringe_latch('', [], 364.71);          % first render, no UserData
    verifyEqual(tc, A.text, '365');
    verifyEqual(tc, A.mm, 364.71);               % display rounds, physics not
    A2 = U.fringe_latch(A.text, A.ud, 331.2);    % auto changes across ranges
    verifyEqual(tc, A2.text, '331');
    verifyEqual(tc, A2.mm, 331.2);
    ud_m = A2.ud;  ud_m.is_auto = false;         % user typed (edit callback)
    A3 = U.fringe_latch('392', ud_m, 331.2);
    verifyEqual(tc, A3.text, '392');
    verifyEqual(tc, A3.mm, 392);
    A4 = U.fringe_latch('331', A3.ud, 305.0);    % manual == old auto text:
    verifyEqual(tc, A4.text, '331');             % still manual, not clobbered
    verifyEqual(tc, A4.mm, 331);
    A5 = U.fringe_latch('abc', A4.ud, 305.0);    % invalid manual -> auto VALUE
    verifyEqual(tc, A5.text, 'abc');
    verifyEqual(tc, A5.mm, 305.0);
    verifyFalse(tc, A5.ud.is_auto, 'provenance must not silently flip');
    ud_a = A5.ud;  ud_a.is_auto = true;          % user cleared the field
    A6 = U.fringe_latch('', ud_a, 305.0);
    verifyEqual(tc, A6.text, '305');
    A7 = U.fringe_latch(A6.text, A6.ud, NaN);    % geometry unavailable
    verifyEqual(tc, A7.text, '');                % blank, placeholder shows
    verifyTrue(tc, isnan(A7.mm));
    ud_m2 = A7.ud;  ud_m2.is_auto = false;
    A8 = U.fringe_latch('400', ud_m2, NaN);      % manual wins over NaN auto
    verifyEqual(tc, A8.mm, 400);
end


% -------------------------------------------------- graphics assumptions

function test_right_ruler_visibility(tc)
    % The 2d fix contract: in yyaxis mode the right ruler can be hidden and
    % restored via YAxis(2).Visible without disturbing the left side.
    fig = figure('Visible', 'off');
    cleanup = onCleanup(@() close(fig));
    ax = axes(fig);
    yyaxis(ax, 'left');
    plot(ax, 1:5, 1:5, '.');
    ax.YAxis(2).Visible = 'off';
    verifyEqual(tc, char(ax.YAxis(2).Visible), 'off');
    verifyEqual(tc, char(ax.YAxis(1).Visible), 'on');
    ax.YAxis(2).Visible = 'on';
    verifyEqual(tc, char(ax.YAxis(2).Visible), 'on');
end

function test_hour_scatter_graphics(tc)
    % Render contract for hour coloring: scatter with numeric CData on a
    % yyaxis-left axes + per-axes cyclic colormap + clim + a south-outside
    % colorbar with centered ticks coexist with a datetime x-axis.
    fig = figure('Visible', 'off');
    cleanup = onCleanup(@() close(fig));
    ax = axes(fig);
    yyaxis(ax, 'left');
    t0 = datetime(2026, 2, 1);
    t = t0 + hours(0:2:22);
    hsc = scatter(ax, t, sin(1:12), 36, mod(0:2:22, 24) + 0.5, 'filled');
    colormap(ax, hsv(24));
    clim(ax, [0 24]);
    hcb = colorbar(ax, 'southoutside');
    hcb.Ticks = (0:4:20) + 0.5;
    hcb.TickLabels = compose('%d', 0:4:20);
    verifyNumElements(tc, hcb.Ticks, 6);
    verifyEqual(tc, ax.CLim, [0 24]);
    verifyNumElements(tc, hsc.CData, 12);
    lgd = legend(hsc, {'Phase'}, 'Location', 'best');
    verifyEqual(tc, char(lgd.Location), 'best');
end

function test_linestyle_toggle(tc)
    % The phaseLine contract mutates LineStyle on BOTH handle types, both
    % directions, without disturbing markers.
    fig = figure('Visible', 'off');
    cleanup = onCleanup(@() close(fig));
    ax = axes(fig);
    hl = plot(ax, 1:5, 1:5, '.');
    verifyEqual(tc, char(hl.LineStyle), 'none');   % raw default = scatter
    hl.LineStyle = '-';
    verifyEqual(tc, char(hl.LineStyle), '-');
    verifyEqual(tc, char(hl.Marker), '.');
    hl.LineStyle = 'none';
    verifyEqual(tc, char(hl.LineStyle), 'none');
    he = errorbar(ax, 1:5, 1:5, ones(1, 5), 'o-', 'MarkerSize', 4);
    he.LineStyle = 'none';                         % unchecked: markers only
    verifyEqual(tc, char(he.LineStyle), 'none');
    he.LineStyle = '-';
    verifyEqual(tc, char(he.LineStyle), '-');
end

function test_overlay_colors_distinct(tc)
    % Policy check on the production LINE/band color constants (duplicated
    % here, not read from renderer handles — full seeded-render coverage is
    % the standing interactive deferral): every co-plotted color must be
    % pairwise separable. Depth is 'r-' = [1 0 0] (the [0.8 0 0] value is
    % the depth-only right RULER, same family by design, not a line color).
    cols = [0      0.4470 0.7410;    % phase default blue
            1.0    0      0     ;    % SNOdar depth line red ('r-')
            0.00   0.60   0.45  ;    % SWE teal
            0.17   0.63   0.17  ;    % AirTC green
            0.49   0.18   0.56  ;    % Temp_C purple
            1.0    0.55   0.10  ;    % wet-snow band orange
            0.35   0.35   0.35 ];    % theoretical-overlay gray
    for i = 1:size(cols, 1)
        for j = i+1:size(cols, 1)
            verifyGreaterThan(tc, norm(cols(i, :) - cols(j, :)), 0.25, ...
                sprintf('colors %d and %d too close', i, j));
        end
    end
end

function test_r1_replica_budget(tc)
    % Row-1 pixel budget at the 1500 px default width: a replica grid with
    % the same widths/spacing/padding and the five real checkbox texts must
    % lay out all 15 children on one row with the last right edge inside the
    % interior. Pins the layout arithmetic headlessly; DPI/font-scaling
    % variations remain a user-run check.
    fig = uifigure('Visible', 'off', 'Position', [80 80 1500 720]);
    cleanup = onCleanup(@() delete(fig));
    gl = uigridlayout(fig, [4 1]);
    gl.RowHeight = {38, 38, 0, '1x'};
    gl.Padding = [8 8 8 8];
    r1 = uigridlayout(gl, [1 15]);
    r1.Layout.Row = 1;
    r1.ColumnWidth = {250, 120, 36, 105, 22, 105, 80, 80, 64, 84, ...
                      'fit', 'fit', 'fit', 'fit', 'fit'};
    r1.ColumnSpacing = 5;
    r1.Padding = [0 0 0 0];
    for k = 1:10
        uilabel(r1, 'Text', 'x');   % placeholders for the 10 fixed columns
    end
    cbs = gobjects(1, 5);
    % Worst-case per-site temperature labels: long headers pass through the
    % production truncation policy (wx_temp_labels, 12 chars + ellipsis), so
    % this pins the budget at the widest labels the layout can ever see.
    wl = tc.TestData.U.wx_temp_labels(struct('wx_temp_cols', ...
        {{'Temperature_Air_2m_Avg', 'Temperature_Snow_Srf_Avg'}}));
    texts = {'Snow depth', 'SWE', wl{1}, wl{2}, 'AboveFreezing'};
    for k = 1:5
        cbs(k) = uicheckbox(r1, 'Text', texts{k});
    end
    drawnow;
    for k = 1:5
        verifyEqual(tc, cbs(k).Layout.Row, 1);
    end
    last = cbs(5).Position;
    interior = 1500 - 2 * 8;                    % outer grid padding only
    verifyLessThanOrEqual(tc, last(1) + last(3), interior, ...
        sprintf('AboveFreezing right edge %.0f px exceeds %d px interior', ...
                last(1) + last(3), interior));
end

% -------------------------------------------------- style-scale controls

function test_style_factors(tc)
    % Validation matrix for the Line x / Pt x factor helper: real finite
    % positive scalars pass through as double, everything else -> x1.
    U = tc.TestData.U;
    F = U.style_factors(2, 0.5);
    verifyEqual(tc, fieldnames(F), {'lw'; 'pt'});
    verifyEqual(tc, F.lw, 2);
    verifyEqual(tc, F.pt, 0.5);
    F = U.style_factors(int32(3), single(2));   % double-conversion contract
    verifyClass(tc, F.lw, 'double');  verifyEqual(tc, F.lw, 3);
    verifyClass(tc, F.pt, 'double');  verifyEqual(tc, F.pt, 2);
    bad = {NaN, Inf, -Inf, 0, -1.5, 2 + 1i, [], [1 2], 'x', {2}, true};
    for k = 1:numel(bad)
        F = U.style_factors(bad{k}, bad{k});
        verifyEqual(tc, F.lw, 1, sprintf('lw fallback, bad input #%d', k));
        verifyEqual(tc, F.pt, 1, sprintf('pt fallback, bad input #%d', k));
    end
end

function test_style_apply(tc)
    % Production application path on real handles: LineWidth x lw on line
    % handles, MarkerSize x pt on point handles, SizeData x pt^2 on scatter
    % (area units); a handle listed as both line and points gets both; x1
    % is a no-op; deleted/placeholder handles are skipped without error.
    U = tc.TestData.U;
    fig = figure('Visible', 'off');
    cleanup = onCleanup(@() close(fig));
    ax = axes(fig);  hold(ax, 'on');
    hd = plot(ax, 1:5, 1:5, '.', 'MarkerSize', 6, 'LineWidth', 0.5);
    he = errorbar(ax, 1:5, 1:5, ones(1, 5), 'o-', 'MarkerSize', 4, ...
                  'CapSize', 3, 'LineWidth', 0.5);
    hs = scatter(ax, 1:5, 1:5, 36, 'filled');
    hy = yline(ax, 0, ':', 'LineWidth', 0.5);
    U.style_apply(U.style_factors(1, 1), [hd he hy], [hd he], hs);
    verifyEqual(tc, hd.MarkerSize, 6);   verifyEqual(tc, hd.LineWidth, 0.5);
    verifyEqual(tc, he.MarkerSize, 4);   verifyEqual(tc, he.LineWidth, 0.5);
    verifyEqual(tc, hy.LineWidth, 0.5);  verifyEqual(tc, hs.SizeData, 36);
    U.style_apply(U.style_factors(2, 3), [hd he hy], [hd he], hs);
    verifyEqual(tc, hd.LineWidth, 1.0);  verifyEqual(tc, hd.MarkerSize, 18);
    verifyEqual(tc, he.LineWidth, 1.0);  verifyEqual(tc, he.MarkerSize, 12);
    verifyEqual(tc, hy.LineWidth, 1.0);
    verifyEqual(tc, hs.SizeData, 36 * 9);      % apparent diameter x3
    % TOD-bump ordering contract: bump BEFORE scaling => (4 + 2) * 3
    he2 = errorbar(ax, 1:5, 2:6, ones(1, 5), 'o-', 'MarkerSize', 4, ...
                   'CapSize', 3, 'LineWidth', 0.5);
    he2.MarkerSize = he2.MarkerSize + 2;
    U.style_apply(U.style_factors(1, 3), gobjects(0), he2, gobjects(0));
    verifyEqual(tc, he2.MarkerSize, 18);
    % Deleted + placeholder entries skipped; valid entries still scale
    hjunk = plot(ax, 1:3, 1:3, '-', 'LineWidth', 1);
    delete(hjunk);
    arr = gobjects(1, 3);  arr(1) = hy;  arr(2) = hjunk;
    U.style_apply(U.style_factors(2, 1), arr, gobjects(0), gobjects(0));
    verifyEqual(tc, hy.LineWidth, 2.0);
end

function test_style_layout_and_gating(tc)
    % Real-layout contract (no data load): build the actual viewer layout
    % headlessly with a minimal cfg, then check the style spinners'
    % construction, the row's placement directly under the legend row, the
    % side-panel grid geometry, the initial hidden state, the production
    % family gating (CB.set_family_rows), and value persistence across
    % visibility flips.
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
    cleanup = onCleanup(@() delete(V.fig));

    verifyEqual(tc, V.sp_linew.Value, 1);
    verifyEqual(tc, V.sp_ptsz.Value, 1);
    verifyEqual(tc, V.sp_linew.Limits, [0.25 5]);
    verifyEqual(tc, V.sp_ptsz.Limits, [0.25 5]);
    verifyEqual(tc, V.sp_linew.Step, 0.25);
    verifyEqual(tc, V.sp_ptsz.Step, 0.25);

    % Placement: directly under the legend row; grid has 19 x 28 px control
    % rows before the two 56 px sub-grid rows.
    g = V.style_row.Parent;
    verifyEqual(tc, V.style_row.Layout.Row, ...
                V.dd_legend.Parent.Layout.Row + 1);
    verifyNumElements(tc, g.RowHeight, 29);
    verifyEqual(tc, [g.RowHeight{1:19}], repmat(28, 1, 19));
    verifyEqual(tc, [g.RowHeight{20:21}], [56 56]);

    % Hidden at build; the production family gate shows/hides it with the
    % other candidates rows; spinner values persist across the flip.
    verifyFalse(tc, logical(V.style_row.Visible));
    V.CB.set_family_rows(V, true);
    verifyTrue(tc, logical(V.style_row.Visible));
    verifyTrue(tc, logical(V.hour_row.Visible));
    verifyTrue(tc, logical(V.cb_swe.Visible));
    V.sp_linew.Value = 2.5;  V.sp_ptsz.Value = 0.5;
    V.CB.set_family_rows(V, false);
    verifyFalse(tc, logical(V.style_row.Visible));
    V.CB.set_family_rows(V, true);
    verifyEqual(tc, V.sp_linew.Value, 2.5);
    verifyEqual(tc, V.sp_ptsz.Value, 0.5);
end

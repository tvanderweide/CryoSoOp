function tests = snodar_soil_test
% Tests for the SoilVUE soil-moisture path: load_snodar's optional-column
% contract (every sensor independent, a missing header NaN-fills only its own
% column), the configured-order column resolution, and the pure soil_geometry /
% soil_usable / soil_color helpers.
% Run: matlab -batch "soop_setup_paths; addpath('tests'); runtests('snodar_soil_test')"
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


% ------------------------------------------------------------------ fixtures

function path = write_wx(tc, name, cols, ts, vals)
% Minimal Campbell TOA5 with caller-chosen columns. cols is a cellstr of header
% names (TIMESTAMP prepended automatically); vals is a cell array of numeric
% columns aligned with cols, written %.6g with NaN as an unquoted NAN.
    path = fullfile(tc.TestData.dir, name);
    fid = fopen(path, 'w');
    fprintf(fid, '"TOA5","stn","logger","sn","os","prog","sig","table"\n');
    fprintf(fid, 'TIMESTAMP,%s\n', strjoin(cols, ','));
    fprintf(fid, 'TS%s\n',  repmat(',u', 1, numel(cols)));
    fprintf(fid, 'Smp%s\n', repmat(',Avg', 1, numel(cols)));
    for i = 1:numel(ts)
        fprintf(fid, '"%s"', char(ts(i)));
        for c = 1:numel(vals)
            v = vals{c}(i);
            if isnan(v)
                fprintf(fid, ',NAN');
            else
                fprintf(fid, ',%.6g', v);
            end
        end
        fprintf(fid, '\n');
    end
    fclose(fid);
end

function ts = stamps(tc, n)
    ts = tc.TestData.t0 + minutes(15 * (0:n-1)');
    ts.Format = 'yyyy-MM-dd HH:mm:ss';
end

function cfg = soil_cfg()
% Brundage rod geometry: rod positions in cm, surface at rod 55 cm, so the
% three buried segments label as 5 / 20 / 45 cm below ground.
    cfg = struct('wx_soil_vwc_cols', 'SoilVUE_VWC_%dcm_Avg', ...
                 'wx_soil_rod_cm', [60 75 100], ...
                 'wx_soil_surface_rod_cm', 55);
end

function WX = load_fix(tc, name, cols, vals, extra_cfg)
    n   = numel(vals{1});
    ts  = stamps(tc, n);
    cfg = struct('wx_dat', write_wx(tc, name, cols, ts, vals));
    if nargin >= 5
        for f = fieldnames(extra_cfg)'
            cfg.(f{1}) = extra_cfg.(f{1});
        end
    end
    WX = tc.TestData.M.load_snodar(cfg);
end


% -------------------------------------------------------------- loader: soil

function test_soil_columns_load_in_configured_order(tc)
    % Headers written in an order that does NOT match the configured rod order;
    % soil_vwc columns must follow the CONFIGURED order, since that order is
    % what carries the depth labels.
    cols = {'SnoDAR_distance_Avg', 'SnoDAR_snow_depth_Avg', ...
            'SoilVUE_VWC_100cm_Avg', 'SoilVUE_VWC_60cm_Avg', 'SoilVUE_VWC_75cm_Avg'};
    n    = 4;
    vals = {2*ones(n,1), ones(n,1), 0.30*ones(n,1), 0.10*ones(n,1), 0.20*ones(n,1)};
    WX   = load_fix(tc, 'soil_order.dat', cols, vals, soil_cfg());

    verifyTrue(tc, ismember('soil_vwc', WX.Properties.VariableNames));
    verifyEqual(tc, size(WX.soil_vwc), [n 3]);
    verifyEqual(tc, WX.soil_vwc(1, :), [0.10 0.20 0.30], 'AbsTol', 1e-9);
end

function test_missing_soil_column_keeps_its_slot(tc)
    % A configured rod whose header the logger does not carry stays an all-NaN
    % column in its own position instead of shifting its neighbours left.
    cols = {'SnoDAR_distance_Avg', 'SnoDAR_snow_depth_Avg', ...
            'SoilVUE_VWC_60cm_Avg', 'SoilVUE_VWC_100cm_Avg'};
    n    = 3;
    vals = {2*ones(n,1), ones(n,1), 0.10*ones(n,1), 0.30*ones(n,1)};
    WX   = load_fix(tc, 'soil_gap.dat', cols, vals, soil_cfg());

    verifyEqual(tc, size(WX.soil_vwc), [n 3]);
    verifyEqual(tc, WX.soil_vwc(:, 1), 0.10*ones(n,1), 'AbsTol', 1e-9);
    verifyTrue(tc, all(isnan(WX.soil_vwc(:, 2))));    % rod 75 cm absent
    verifyEqual(tc, WX.soil_vwc(:, 3), 0.30*ones(n,1), 'AbsTol', 1e-9);
end

function test_no_soil_config_yields_empty_soil_column(tc)
    % Unconfigured sensor: soil_vwc exists but is n-by-0, which every consumer
    % reads as "no soil data". Rod geometry is site-specific and never guessed.
    cols = {'SnoDAR_distance_Avg', 'SnoDAR_snow_depth_Avg', 'SoilVUE_VWC_60cm_Avg'};
    n    = 3;
    vals = {2*ones(n,1), ones(n,1), 0.10*ones(n,1)};
    WX   = load_fix(tc, 'soil_unconfigured.dat', cols, vals);

    verifyEqual(tc, size(WX.soil_vwc), [n 0]);
end

function test_soil_explicit_column_list(tc)
    % An explicit ordered header list is accepted in place of the printf
    % pattern; rod positions then only set the depth labels.
    cols = {'SnoDAR_distance_Avg', 'SnoDAR_snow_depth_Avg', 'VWC_A', 'VWC_B'};
    n    = 2;
    vals = {2*ones(n,1), ones(n,1), 0.11*ones(n,1), 0.22*ones(n,1)};
    cfg  = struct('wx_soil_vwc_cols', {{'VWC_A', 'VWC_B'}}, ...
                  'wx_soil_rod_cm', [60 75], 'wx_soil_surface_rod_cm', 55);
    WX   = load_fix(tc, 'soil_explicit.dat', cols, vals, cfg);

    verifyEqual(tc, size(WX.soil_vwc), [n 2]);
    verifyEqual(tc, WX.soil_vwc(1, :), [0.11 0.22], 'AbsTol', 1e-9);
end

function test_soil_zero_values_preserved(tc)
    % Rod segments in air or snow sit below the sensor's calibrated permittivity
    % range and return exactly 0.000 m^3/m^3. That is a real reading, not
    % missing data, and must survive the loader unchanged.
    cols = {'SnoDAR_distance_Avg', 'SnoDAR_snow_depth_Avg', ...
            'SoilVUE_VWC_60cm_Avg', 'SoilVUE_VWC_75cm_Avg', 'SoilVUE_VWC_100cm_Avg'};
    n    = 2;
    vals = {2*ones(n,1), ones(n,1), zeros(n,1), 0.12*ones(n,1), NaN(n,1)};
    WX   = load_fix(tc, 'soil_zeros.dat', cols, vals, soil_cfg());

    verifyEqual(tc, WX.soil_vwc(:, 1), zeros(n,1));
    verifyTrue(tc, all(isfinite(WX.soil_vwc(:, 1))));
    verifyTrue(tc, all(isnan(WX.soil_vwc(:, 3))));    % NAN stays NaN
end

function test_soil_rows_align_with_timestamp_drop(tc)
    % Rows with unparseable timestamps are dropped from every column together,
    % so soil_vwc stays aligned with timestamp.
    cols = {'SnoDAR_distance_Avg', 'SnoDAR_snow_depth_Avg', 'SoilVUE_VWC_60cm_Avg'};
    n    = 5;
    ts   = stamps(tc, n);
    vals = {2*ones(n,1), ones(n,1), (1:n)'/100};
    path = write_wx(tc, 'soil_badts.dat', cols, ts, vals);

    txt = strsplit(fileread(path), newline);
    txt{5 + 2} = ['"not-a-time"' extractAfter(txt{5 + 2}, '"')];  % 4 header/data lines before row 3
    fid = fopen(path, 'w');  fprintf(fid, '%s', strjoin(txt, newline));  fclose(fid);

    cfg = soil_cfg();  cfg.wx_dat = path;
    WX  = tc.TestData.M.load_snodar(cfg);

    verifyEqual(tc, height(WX), n - 1);
    verifyEqual(tc, size(WX.soil_vwc, 1), height(WX));
    verifyEqual(tc, WX.soil_vwc(:, 1), [1 2 4 5]'/100, 'AbsTol', 1e-9);
end


% ------------------------------------------- loader: optional-column contract

function test_missing_depth_column_does_not_block_other_sensors(tc)
    % A missing snow-depth header NaN-fills depth_m and warns, but every other
    % sensor still loads — one absent field never drops the whole table.
    cols = {'SnoDAR_distance_Avg', 'AirTC_Avg', 'SS_SWE_Avg', 'SoilVUE_VWC_60cm_Avg'};
    n    = 3;
    vals = {2*ones(n,1), -5*ones(n,1), 100*ones(n,1), 0.10*ones(n,1)};
    cfg  = soil_cfg();  cfg.wx_soil_rod_cm = 60;

    WX = verifyWarning(tc, @() load_fix(tc, 'no_depth.dat', cols, vals, cfg), ...
                       'BrundageSoOp:snodar');

    verifyEqual(tc, height(WX), n);
    verifyTrue(tc, all(isnan(WX.depth_m)));
    verifyEqual(tc, WX.airtc_c, -5*ones(n,1), 'AbsTol', 1e-9);
    verifyEqual(tc, WX.soil_vwc(:, 1), 0.10*ones(n,1), 'AbsTol', 1e-9);
end

function test_missing_distance_column_keeps_depth_series(tc)
    % distance feeds only the drift flag. Without it the flag is unavailable,
    % but the depth series passes through unflagged rather than being wiped.
    cols = {'SnoDAR_snow_depth_Avg', 'AirTC_Avg'};
    n    = 3;
    vals = {[1.0 1.1 1.2]', -5*ones(n,1)};

    WX = verifyWarning(tc, @() load_fix(tc, 'no_dist.dat', cols, vals), ...
                       'BrundageSoOp:snodar');

    verifyEqual(tc, height(WX), n);
    verifyEqual(tc, WX.depth_m, [1.0 1.1 1.2]', 'AbsTol', 1e-9);
end


% ------------------------------------------------------- pure: soil_geometry

function test_soil_geometry_depths_below_ground(tc)
    % Rod position minus surface rod position — THE conversion the labels use.
    G = tc.TestData.U.soil_geometry(soil_cfg());
    verifyTrue(tc, G.ok);
    verifyEqual(tc, G.rod_cm, [60 75 100]);
    verifyEqual(tc, G.depth_cm, [5 20 45], 'AbsTol', 1e-9);
    verifyEqual(tc, G.labels, {'5 cm', '20 cm', '45 cm'});
end

function test_soil_geometry_rejects_unconfigured(tc)
    G = tc.TestData.U.soil_geometry(struct());
    verifyFalse(tc, G.ok);
    verifyGreaterThan(tc, strlength(G.why), 0);

    G2 = tc.TestData.U.soil_geometry(struct('wx_soil_rod_cm', [60 NaN]));
    verifyFalse(tc, G2.ok);
end

function test_soil_geometry_surface_defaults_to_ground(tc)
    % No surface position configured: rod positions ARE depths below ground.
    G = tc.TestData.U.soil_geometry(struct('wx_soil_rod_cm', [10 30]));
    verifyTrue(tc, G.ok);
    verifyEqual(tc, G.depth_cm, [10 30], 'AbsTol', 1e-9);
end


% --------------------------------------------------------- pure: soil_usable

function test_soil_usable_requires_matching_width(tc)
    % Column count carries the depth labels, so a width mismatch must refuse to
    % draw rather than mislabel depths.
    U = tc.TestData.U;
    cfg = soil_cfg();
    good = table(datetime(2026,1,1) + (0:2)', [0.1 0.2 0.3; 0.1 0.2 0.3; 0.1 0.2 0.3], ...
                 'VariableNames', {'timestamp', 'soil_vwc'});
    verifyTrue(tc, U.soil_usable(good, cfg));

    narrow = good;  narrow.soil_vwc = good.soil_vwc(:, 1:2);
    verifyFalse(tc, U.soil_usable(narrow, cfg));
end

function test_soil_usable_requires_finite_data(tc)
    U = tc.TestData.U;
    cfg = soil_cfg();
    allnan = table(datetime(2026,1,1) + (0:1)', NaN(2, 3), ...
                   'VariableNames', {'timestamp', 'soil_vwc'});
    verifyFalse(tc, U.soil_usable(allnan, cfg));

    % Zeros are real readings (air/snow segments below the calibrated
    % permittivity range), so an all-zero column IS drawable.
    zeroed = allnan;  zeroed.soil_vwc = zeros(2, 3);
    verifyTrue(tc, U.soil_usable(zeroed, cfg));
end

function test_soil_usable_handles_absent_inputs(tc)
    U = tc.TestData.U;
    verifyFalse(tc, U.soil_usable(table(), soil_cfg()));
    verifyFalse(tc, U.soil_usable([], soil_cfg()));

    ok = table(datetime(2026,1,1), 0.2, 'VariableNames', {'timestamp', 'soil_vwc'});
    verifyFalse(tc, U.soil_usable(ok, struct()));      % geometry unconfigured
end


% ---------------------------------------------------------- pure: soil_color

function test_soil_color_distinct_and_cyclic(tc)
    U = tc.TestData.U;
    c1 = U.soil_color(1);  c2 = U.soil_color(2);  c3 = U.soil_color(3);
    verifyEqual(tc, size(c1), [1 3]);
    verifyTrue(tc, all([c1 c2 c3] >= 0 & [c1 c2 c3] <= 1));
    verifyNotEqual(tc, c1, c2);
    verifyNotEqual(tc, c2, c3);
    verifyEqual(tc, U.soil_color(4), c1);             % cycles
    verifyEqual(tc, U.soil_color(0), c1);             % out-of-range guard
    verifyEqual(tc, U.soil_color(NaN), c1);
end


% ------------------------------------------------------- viewer: row + gating

function test_soilvwc_row_placement_and_gating(tc)
    % Real layout built headlessly: the modifier sits directly under
    % SnowTemp - Nearest, is hidden at build, and becomes selectable only on a
    % candidates plot with SnowTemp on AND a usable soil column in the loaded
    % weather table. Disabling preserves the checked value.
    V = build_layout(tc);
    cleanup = onCleanup(@() delete(V.fig));

    verifyEqual(tc, V.soilvwc_row.Layout.Row, ...
                V.snowtemp_nearest_row.Layout.Row + 1);
    verifyFalse(tc, logical(V.soilvwc_row.Visible));
    verifyFalse(tc, logical(V.cb_soilvwc.Value));
    verifyFalse(tc, logical(V.cb_soilvwc.Enable));

    % Candidates family shows the row with the other nearest-group modifiers.
    V.CB.set_family_rows(V, true, true);
    verifyTrue(tc, logical(V.soilvwc_row.Visible));
    % SnowTemp off -> not selectable even with soil data present.
    V.WX = soil_wx(tc);
    V.CB.set_family_rows(V, true, true);
    verifyFalse(tc, logical(V.cb_soilvwc.Enable));
    % SnowTemp on + usable data -> selectable.
    V.cb_snowtemp.Value = true;
    V.CB.set_family_rows(V, true, true);
    verifyTrue(tc, logical(V.cb_soilvwc.Enable));
    % Configured geometry but no soil column -> not selectable.
    V.cb_soilvwc.Value = true;
    V.WX = removevars(soil_wx(tc), 'soil_vwc');
    V.CB.set_family_rows(V, true, true);
    verifyFalse(tc, logical(V.cb_soilvwc.Enable));
    verifyTrue(tc, logical(V.cb_soilvwc.Value));   % checked value survives
    % Non-candidates plot hides the row again.
    V.CB.set_family_rows(V, true, false);
    verifyFalse(tc, logical(V.soilvwc_row.Visible));
end


% ------------------------------------------------------ viewer: overlay geometry

function test_soil_overlay_geometry(tc)
    % Graphics contract built FROM the production plan: the soil overlay is
    % transparent, shares the thermograph's left edge and height, maps [t0,t1]
    % to the same normalized x despite its wider axes, keeps its ruler and the
    % DTC colorbar from overlapping, and stays inside the panel.
    U = tc.TestData.U;
    P = U.wx_axes_plan(true, true, true, false, true);
    dtc_pos = [P.ax_pos(1) 0.13 P.ax_pos(3) 0.22];

    fig = uifigure('Visible', 'off', 'Position', [80 80 1200 620]);
    cleanup = onCleanup(@() delete(fig));
    pnl = uipanel(fig, 'Units', 'normalized', 'Position', [0 0 1 1]);
    t0 = datetime(2026, 1, 1);  t1 = t0 + days(30);

    axD = axes(pnl, 'Position', dtc_pos);
    surface(axD, [t0 t1], [-45 0 60]', zeros(3, 2), -5 * ones(3, 2), ...
            'EdgeColor', 'none');
    clim(axD, [-12 1]);
    cbD = colorbar(axD, 'eastoutside');
    cbD.Position = [dtc_pos(1) + dtc_pos(3) + P.dtc_cb_gap, dtc_pos(2), ...
                    0.015, dtc_pos(4)];
    axD.Position = dtc_pos;          % undo the colorbar's auto-shrink
    xlim(axD, [t0 t1]);

    axV = axes(pnl, 'Position', [dtc_pos(1) dtc_pos(2) P.soil_w dtc_pos(4)], ...
               'Color', 'none', 'YAxisLocation', 'right', 'XTick', [], ...
               'Box', 'off', 'HitTest', 'off', 'PickableParts', 'none');
    hold(axV, 'on');
    for k = 1:3
        plot(axV, [t0 t1], [0 0.3], '-', 'Color', U.soil_color(k));
    end
    xlim(axV, [t0, t0 + (t1 - t0) * (P.soil_w / dtc_pos(3))]);
    ylim(axV, [0 0.33]);

    % Transparent, so the thermograph beneath stays visible.
    verifyEqual(tc, axV.Color, 'none');
    verifyEqual(tc, axV.YAxisLocation, 'right');
    % Same origin and height as the thermograph it overlays.
    verifyEqual(tc, axV.Position([1 2 4]), dtc_pos([1 2 4]), 'AbsTol', 1e-12);
    verifyGreaterThan(tc, axV.Position(3), dtc_pos(3));   % ruler steps outward

    % t1 lands at the same normalized x on both axes despite the wider overlay.
    fx = @(ax, t) ax.Position(1) + ax.Position(3) * ...
         (seconds(t - ax.XLim(1)) / seconds(ax.XLim(2) - ax.XLim(1)));
    verifyEqual(tc, fx(axV, t1), fx(axD, t1), 'AbsTol', 1e-12);
    verifyEqual(tc, fx(axV, t0), fx(axD, t0), 'AbsTol', 1e-12);

    % The colorbar starts right of the soil ruler's spine and the whole strip
    % stays inside the panel.
    verifyGreaterThan(tc, cbD.Position(1), axV.Position(1) + axV.Position(3));
    verifyLessThanOrEqual(tc, cbD.Position(1) + cbD.Position(3), 1);
end


% ------------------------------------------------------------- local fixtures

function V = build_layout(tc)
% Headless viewer layout with the Brundage rod geometry configured.
    cfg = soil_cfg();
    cfg.freq_hz = 370e6;  cfg.fs = 20e6;  cfg.num_segs = 2;  cfg.Ti = 0.9;
    cfg.peak_lag = -0.575;  cfg.T_load_K = 290;
    cfg.out_dir = tc.TestData.dir;  cfg.data_dir = tc.TestData.dir;
    V = SoopViewerState();
    V.cfg = cfg;
    V.M   = BrundageSoOp_fun();
    V.npts = floor(cfg.fs * cfg.Ti);  V.n_want = V.npts * cfg.num_segs;
    V.calib_N_looks = cfg.fs * 2;
    V.Erfi = rfi_excise();
    V.L1 = table();  V.CAL = table();  V.WX = table();
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
end

function WX = soil_wx(tc)
% Weather table carrying a drawable 3-rod soil_vwc column.
    ts = stamps(tc, 4);
    WX = table(ts, [0.10; 0.12; 0.14; 0.16] * [1 1 1], ...
               'VariableNames', {'timestamp', 'soil_vwc'});
end

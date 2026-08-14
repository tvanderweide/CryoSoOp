function tests = viewer_pointcolor_test
% Tests point-coloring controls: hour-of-day coloring on L2: Satellite
% elevation and on the candidates family.
    tests = functiontests(localfunctions);
end


%% --- Control visibility and Enable gating ---------------------------------

function test_hour_row_visible_on_satellite_elevation(tc)
% The shared Color by hour row shows on the candidates family and on
% L2: Satellite elevation, and stays hidden on other L2 views.
    V = gated_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    V.dd_plot.Value = 'L2: Satellite elevation';
    V.CB.render_now(V);
    verifyTrue(tc, logical(V.hour_row.Visible));

    V.dd_plot.Value = 'L2: Satellite Azimuth';
    V.CB.render_now(V);
    verifyFalse(tc, logical(V.hour_row.Visible));
end


function test_elevation_hour_enable_ignores_daily_filter(tc)
% The daily filter subsets rows in the candidates branch only, so on the
% elevation view Color by hour stays enabled with the filter checked --
% unlike the candidates family, where the filter disables it.
    V = gated_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    V.cb_tod.Value = true;
    V.dd_agg.Value = 'Raw captures';

    V.dd_plot.Value = 'L2: Satellite elevation';
    V.CB.render_now(V);
    verifyTrue(tc, logical(V.cb_hourcolor.Enable), ...
        'daily filter must not gate hour coloring on the elevation view');

    V.dd_plot.Value = 'L2: Sensor data';
    V.CB.render_now(V);
    verifyFalse(tc, logical(V.cb_hourcolor.Enable), ...
        'daily filter still gates hour coloring on the candidates family');
end


function test_elevation_hour_enable_follows_aggregation(tc)
% Hour identity survives Raw captures and Per-run mean only.
    V = gated_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    V.dd_plot.Value = 'L2: Satellite elevation';

    for agg = {'Raw captures', 'Per-run mean'}
        V.dd_agg.Value = agg{1};
        V.CB.render_now(V);
        verifyTrue(tc, logical(V.cb_hourcolor.Enable), agg{1});
    end
    for agg = {'Daily mean', 'Range mean'}
        V.dd_agg.Value = agg{1};
        V.CB.render_now(V);
        verifyFalse(tc, logical(V.cb_hourcolor.Enable), agg{1});
    end
end


%% --- Render --------------------------------------------------------------

function test_elevation_hour_render_draws_cyclic_scatter(tc)
% Colored points replace the plain markers, on a 0-24 cyclic scale.
    V = elevation_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    V.cb_hourcolor.Value = true;
    V.dd_agg.Value = 'Raw captures';
    soop_viewer_render_l2(V, 'L2: Satellite elevation');

    hsc = findobj(V.panel, 'Type', 'scatter');
    verifyNumElements(tc, hsc, 1);
    ax = ancestor(hsc, 'axes');
    verifyEqual(tc, ax.CLim, [0 24]);
    verifyNotEmpty(tc, findobj(V.panel, 'Type', 'ColorBar'));

    % Colors are the capture hours, matching what the points plot.
    verifyEqual(tc, hsc.CData(:), V.U.hour_bins(V.L2.timestamp) + 0.5, ...
        'AbsTol', 1e-9);
    verifyEqual(tc, hsc.YData(:), V.L2.theta_deg, 'AbsTol', 1e-9);

    % The base series keeps its handle but hides its markers.
    hl = findobj(ax, 'Type', 'line');
    verifyNumElements(tc, hl, 1);
    verifyEqual(tc, hl.Marker, 'none');
end


function test_elevation_hour_colors_match_displayed_aggregate(tc)
% Under Per-run mean the colored points use the SAME aggregate as the
% drawn series, so position and color describe one group.
    V = elevation_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    V.cb_hourcolor.Value = true;
    V.dd_agg.Value = 'Per-run mean';
    soop_viewer_render_l2(V, 'L2: Satellite elevation');

    [ta, ya] = V.M.aggregate(V.L2.timestamp, V.L2.theta_deg, 'Per-run mean', 'lin');
    hsc = findobj(V.panel, 'Type', 'scatter');
    verifyEqual(tc, hsc.YData(:), ya, 'AbsTol', 1e-9);
    verifyEqual(tc, hsc.CData(:), V.U.hour_bins(ta) + 0.5, 'AbsTol', 1e-9);
end


function test_elevation_hour_unchecked_draws_no_scatter(tc)
% Unchecked leaves the original marker series untouched.
    V = elevation_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    V.cb_hourcolor.Value = false;
    soop_viewer_render_l2(V, 'L2: Satellite elevation');

    verifyEmpty(tc, findobj(V.panel, 'Type', 'scatter'));
    verifyEmpty(tc, findobj(V.panel, 'Type', 'ColorBar'));
    hl = findobj(V.panel, 'Type', 'line');
    verifyNumElements(tc, hl, 1);
    verifyEqual(tc, hl.Marker, '.');
end


function test_elevation_hour_inert_under_daily_aggregation(tc)
% A checked-but-disabled box draws nothing: the render re-checks the same
% predicate the callbacks use for Enable.
    V = elevation_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    V.cb_hourcolor.Value = true;
    V.dd_agg.Value = 'Daily mean';
    soop_viewer_render_l2(V, 'L2: Satellite elevation');

    verifyEmpty(tc, findobj(V.panel, 'Type', 'scatter'));
end


%% --- Fixtures ------------------------------------------------------------

function cfg = minimal_cfg()
    cfg = struct('freq_hz', 370e6, 'fs', 20e6, 'num_segs', 2, 'Ti', 0.9, ...
        'peak_lag', -0.575, 'T_load_K', 290, 'out_dir', tempdir, 'data_dir', tempdir);
end


function V = gated_viewer(tc) %#ok<INUSD>
% Viewer for Enable/Visible gating checks driven through render_now, which
% stringifies the date pickers for the side panel -- they must not be NaT.
    V = build_viewer(minimal_cfg());
    V.dp1.Value = datetime(2026, 1, 1);
    V.dp2.Value = datetime(2026, 1, 2);
end


function V = elevation_viewer(tc) %#ok<INUSD>
% Viewer seeded with an L2 product spanning three runs on one day, so
% Raw captures and Per-run mean give different point counts.
    V = build_viewer(minimal_cfg());
    t = datetime(2026, 1, 1) + hours([2; 2; 8; 8; 17; 17]) + seconds([0; 30; 0; 30; 0; 30]);
    V.L2 = table(t, (10:10:60)', (100:10:150)', ...
        'VariableNames', {'timestamp', 'theta_deg', 'az_deg'});
    V.dp1.Value = dateshift(t(1), 'start', 'day');
    V.dp2.Value = dateshift(t(end), 'start', 'day');
end


function V = build_viewer(cfg)
    V = SoopViewerState();
    V.cfg = cfg;  V.M = BrundageSoOp_fun();  V.Erfi = rfi_excise();
    V.npts = floor(cfg.fs * cfg.Ti);  V.n_want = V.npts * cfg.num_segs;
    V.calib_N_looks = cfg.fs * 2;
    V.L1 = table();  V.CAL = table();  V.cache = struct('key', "", 'data', []);
    V.calib_base_cache = struct('dir', "", 'T', table());
    V.calib_notch_cache = struct('dir', "", 'T', table());
    V.busy = false;  V.pending = false;  V.last_n = 0;
    V.OVF = strings(0, 1);  V.OVF_ok = false;  V.OVF_src = "";
    V.cap_folders = containers.Map('KeyType', 'char', 'ValueType', 'char');
    V.ov_title = '';  V.ov_xlabel = '';  V.ov_ylabel = '';  V.ov_plot_kind = '';
    V.U = soop_viewer_util();  V.D = soop_viewer_data();  V.CB = soop_viewer_callbacks();
    [V.PLOT_INFO, V.CAP_PATTERNS] = soop_viewer_catalog(cfg);
    soop_viewer_layout(V);
end

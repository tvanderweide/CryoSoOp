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


%% --- Color by SNR: control wiring ----------------------------------------

function test_pointcolor_modes_are_mutually_exclusive(tc)
% The two modes share one color bar, so checking either clears the other;
% unchecking one leaves the other alone.
    V = gated_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));

    V.cb_hourcolor.Value = true;
    V.CB.on_pointcolor(V, 'hour');
    verifyTrue(tc, V.cb_hourcolor.Value);
    verifyFalse(tc, V.cb_snrcolor.Value);

    V.cb_snrcolor.Value = true;
    V.CB.on_pointcolor(V, 'snr');
    verifyTrue(tc, V.cb_snrcolor.Value);
    verifyFalse(tc, V.cb_hourcolor.Value, 'checking SNR must clear hour');

    V.cb_hourcolor.Value = true;
    V.CB.on_pointcolor(V, 'hour');
    verifyFalse(tc, V.cb_snrcolor.Value, 'checking hour must clear SNR');

    V.cb_hourcolor.Value = false;      % unchecking clears nothing else
    V.CB.on_pointcolor(V, 'hour');
    verifyFalse(tc, V.cb_hourcolor.Value);
    verifyFalse(tc, V.cb_snrcolor.Value);
end


function test_snrcolor_row_matches_hour_row_visibility(tc)
% The mutually exclusive pair is shown together across the candidates
% family, including L2: Sensor data, and hidden together elsewhere.
    V = gated_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));

    V.CB.set_family_rows(V, true, true);
    verifyTrue(tc, logical(V.snrcolor_row.Visible));
    V.CB.set_family_rows(V, true, false);      % L2: Sensor data
    verifyTrue(tc, logical(V.snrcolor_row.Visible));
    V.CB.set_family_rows(V, false, false);
    verifyFalse(tc, logical(V.snrcolor_row.Visible));
end


function test_snrcolor_enable_needs_snr_column(tc)
% Disabled when the loaded candidates product predates snr_db.
    V = gated_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    t = datetime(2026, 1, 1) + hours(6);
    V.dd_plot.Value = 'L2: Sensor data';

    V.CAND = table(t, "cap1", 30, 'VariableNames', ...
        {'timestamp', 'base_name', 'phase_raw_deg'});
    V.CB.render_now(V);
    verifyFalse(tc, logical(V.cb_snrcolor.Enable));

    V.CAND = table(t, "cap1", 20, 30, 'VariableNames', ...
        {'timestamp', 'base_name', 'snr_db', 'phase_raw_deg'});
    V.CB.render_now(V);
    verifyTrue(tc, logical(V.cb_snrcolor.Enable));
end


%% --- Color by SNR: render ------------------------------------------------

function test_snrcolor_render_pins_floor_to_applied_cutoff(tc)
% Color floor is the cutoff actually applied, not the configured default,
% so "darkest = at threshold" holds in every date range.
    V = candidates_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    V.cb_snrcolor.Value = true;
    V.sp_snrcut.Value = 12;
    soop_viewer_render_l2(V, CAND_KIND);

    hsc = findobj(V.panel, 'Type', 'scatter');
    verifyNumElements(tc, hsc, 1);
    ax = ancestor(hsc, 'axes');
    verifyEqual(tc, ax.CLim(1), 12, 'floor must equal the applied cutoff');
    verifyEqual(tc, ax.CLim(2), 40, 'top follows the displayed maximum');
    verifyEqual(tc, sort(hsc.CData(:)), [12; 20; 40], 'AbsTol', 1e-9);

    cb = findobj(V.panel, 'Type', 'ColorBar');
    verifyTrue(tc, any(strcmp({cb.Label}, 'SNR [dB]') | ...
        cellfun(@(L) strcmp(L.String, 'SNR [dB]'), {cb.Label})));
end


function test_snrcolor_joint_mask_keeps_color_aligned_with_phase(tc)
% aggregate() drops non-finite y before grouping, so a row with finite SNR
% but non-finite displayed phase must not contribute a colour of its own.
    V = candidates_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    V.CAND.corr_41622(2) = NaN;        % finite SNR, non-finite phase
    V.cb_snrcolor.Value = true;
    soop_viewer_render_l2(V, CAND_KIND);

    hsc = findobj(V.panel, 'Type', 'scatter');
    verifyNumElements(tc, hsc, 1);
    verifyNumElements(tc, hsc.CData, numel(hsc.XData), ...
        'one colour per drawn point');
    verifyNumElements(tc, hsc.XData, 2, 'the non-finite phase row drops out');
    verifyEqual(tc, sort(hsc.CData(:)), [12; 40], 'AbsTol', 1e-9, ...
        'the dropped row must not contribute its SNR');
end


function test_snrcolor_per_run_mean_drops_contribution_from_both(tc)
% Per-run mean groups before averaging, so a row with finite SNR but non-finite
% phase must be excluded from BOTH the plotted group value and its colour — a
% row dropped from only one of the two would shift the group's midpoint
% timestamp relative to its colour and silently mis-colour the point.
    V = candidates_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    V.CAND.corr_41622(2) = NaN;        % finite SNR (20 dB), non-finite phase
    V.cb_snrcolor.Value = true;
    V.dd_agg.Value = 'Per-run mean';
    soop_viewer_render_l2(V, CAND_KIND);

    hsc = findobj(V.panel, 'Type', 'scatter');
    verifyNumElements(tc, hsc, 1);
    verifyNumElements(tc, hsc.CData, numel(hsc.XData), ...
        'one colour per drawn point');
    % The 20 dB row contributed to neither the phase nor the SNR aggregate.
    verifyFalse(tc, any(abs(hsc.CData(:) - 20) < 1e-9), ...
        'the dropped row must not colour any group');
end


function test_snrcolor_survives_nonfinite_transformed_phase(tc)
% The unwrapped view transforms the phase before display. A non-finite value in
% the TRANSFORMED series must drop from the coloring the same way a raw
% non-finite value does, with no error and no colour left stranded.
    V = candidates_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    V.CAND.corr_41622(2) = Inf;
    V.cb_snrcolor.Value = true;
    soop_viewer_render_l2(V, ...
        ['L2: Candidates Unwrapped ' char(8212) ' MUOS-5 (41622)']);

    hsc = findobj(V.panel, 'Type', 'scatter');
    if ~isempty(hsc)
        verifyNumElements(tc, hsc.CData, numel(hsc.XData));
        verifyTrue(tc, all(isfinite(hsc.YData)));
    end
end


function test_snrcolor_hour_wins_when_both_set(tc)
% A stale state with both checked draws the hour colormap only.
    V = candidates_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    V.cb_hourcolor.Value = true;
    V.cb_snrcolor.Value  = true;
    soop_viewer_render_l2(V, CAND_KIND);

    ax = ancestor(findobj(V.panel, 'Type', 'scatter'), 'axes');
    verifyEqual(tc, ax.CLim, [0 24], 'hour coloring must win');
end


function test_snrcolor_off_when_cutoff_not_applied(tc)
% snr_ok false (product without snr_db) means no colour floor can be
% justified, so the render draws no coloring even with the box checked.
    V = candidates_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    V.CAND = removevars(V.CAND, 'snr_db');
    V.cb_snrcolor.Value = true;
    soop_viewer_render_l2(V, CAND_KIND);

    verifyEmpty(tc, findobj(V.panel, 'Type', 'scatter'));
end


function test_snrcolor_single_point_guard(tc)
% One surviving point gives a degenerate max; CLim must stay increasing.
    V = candidates_viewer(tc);
    cleanup = onCleanup(@() delete(V.fig));
    V.cb_snrcolor.Value = true;
    V.sp_snrcut.Value = 40;            % keeps the single 40 dB capture
    soop_viewer_render_l2(V, CAND_KIND);

    ax = ancestor(findobj(V.panel, 'Type', 'scatter'), 'axes');
    verifyGreaterThan(tc, ax.CLim(2), ax.CLim(1));
    verifyEqual(tc, ax.CLim(1), 40);
end


%% --- Fixtures ------------------------------------------------------------

function k = CAND_KIND()
    k = 'L2: Candidates — MUOS-5 (41622)';
end


function V = candidates_viewer(tc) %#ok<INUSD>
% Three captures on one day with distinct SNRs spanning the default cutoff.
    V = build_viewer(minimal_cfg());
    t = datetime(2026, 1, 1) + hours([2; 9; 16]);
    V.CAND = table(t, "cap" + string((1:3)'), [12; 20; 40], (10:10:30)', ...
        'VariableNames', {'timestamp', 'base_name', 'snr_db', 'corr_41622'});
    V.dp1.Value = dateshift(t(1), 'start', 'day');
    V.dp2.Value = dateshift(t(end), 'start', 'day');
end

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

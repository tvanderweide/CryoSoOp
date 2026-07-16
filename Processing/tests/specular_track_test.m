function tests = specular_track_test
% Tests for lib/soop_specular_track.m (day selection, timezone handling, snow
% interpolation, ENU projection) plus the 'Radar Cal: specular track' catalog
% and control wiring. Synthetic elevation CSVs are written to a temp dir with
% the generator's shape: inclusive UTC grid, so the FIRST and LAST local days
% are partial — exactly the edge the completeness rule exists for.
    tests = functiontests(localfunctions);
end


% =========================================================================
% Fixtures
% =========================================================================
function setupOnce(tc)
    tc.TestData.dir = fullfile(tempdir, ...
        ['soop_spectrack_' char(java.util.UUID.randomUUID())]);
    mkdir(tc.TestData.dir);

    % Jan table (no DST): 2026-01-05 00:00Z .. 2026-01-08 00:00Z inclusive,
    % 10-min cadence. In America/Boise (UTC-7, MST) that is Jan 4 17:00 ..
    % Jan 7 17:00 local: local days Jan 5 and Jan 6 are complete, Jan 4 and
    % Jan 7 are partial.
    write_table(tc.TestData.dir, 91001, ...
                datetime(2026,1,5):minutes(10):datetime(2026,1,8));

    % March table across the US spring-forward (2026-03-08 02:00 local):
    % 2026-03-07 00:00Z .. 2026-03-10 00:00Z. Local days Mar 7/8/9 complete
    % (Mar 8 is a 23-hour local day and must still pass), Mar 6/10 partial.
    write_table(tc.TestData.dir, 91002, ...
                datetime(2026,3,7):minutes(10):datetime(2026,3,10));
end

function teardownOnce(tc)
    if isfolder(tc.TestData.dir), rmdir(tc.TestData.dir, 's'); end
end

function write_table(dirp, norad, tt)
    tt = tt(:);
    m = minutes(tt - dateshift(tt, 'start', 'day'));
    T = table(tt, 35 + 3 * sind(m / 4), 160 + 2 * cosd(m / 4), ...
              38550 + 20 * sind(m / 3), ...
              'VariableNames', {'timestamp', 'elevation_deg', 'azimuth_deg', ...
                                'range_km'});
    writetable(T, fullfile(dirp, sprintf('muos_elevation_%d.csv', norad)));
end

function cfg = base_cfg(tc)
    cfg = struct('elev_dir', tc.TestData.dir, 'tower_h_m', 6.096, ...
                 'capture_tz', 'America/Boise');
end

function WX = wx_table(t_start, t_end, depth_m)
    tt = (t_start:minutes(30):t_end)';
    WX = table(tt, repmat(depth_m, numel(tt), 1), ...
               'VariableNames', {'timestamp', 'depth_m'});
end

function inf_bounds = infs()
% Unbounded range-picker values (the viewer's range_bounds() returns infinite
% datetimes for empty pickers).
    inf_bounds = {datetime(-Inf, 'ConvertFrom', 'datenum'), ...
                  datetime( Inf, 'ConvertFrom', 'datenum')};
end


% =========================================================================
% Day selection & timezone
% =========================================================================
function test_auto_picks_last_complete_local_day(tc)
% Inclusive UTC endpoint makes the last local day partial (ends 17:00 MST);
% auto selection must skip it and land on Jan 6.
    b = infs();
    [series, meta] = soop_specular_track(base_cfg(tc), [], 91001, NaT, ...
                                         b{1}, b{2}, 'fixed h');
    verifyEqual(tc, meta.day, datetime(2026,1,6));
    verifyTrue(tc, meta.auto_day);
    verifyTrue(tc, meta.complete);
    verifyEqual(tc, numel(series), 1);
    verifyEqual(tc, series.n_valid, meta.n_rows);
end

function test_day_selection_follows_capture_tz(tc)
% Same table read as UTC: the last UTC day (Jan 7, rows 00:00..24:00 via the
% inclusive endpoint) IS complete, so the chosen day moves.
    cfg = base_cfg(tc);
    cfg.capture_tz = 'UTC';   % no conversion branch
    b = infs();
    [~, meta] = soop_specular_track(cfg, [], 91001, NaT, b{1}, b{2}, 'fixed h');
    verifyEqual(tc, meta.day, datetime(2026,1,7));
end

function test_dst_day_counts_as_complete(tc)
% 2026-03-08 is a 23-hour local day (spring forward). The duration-based
% completeness rule must accept it — and it IS the last complete local day of
% this table (Mar 9 is cut at 18:00 MDT by the UTC endpoint), so auto
% selection lands exactly on the DST day.
    b = infs();
    [~, meta] = soop_specular_track(base_cfg(tc), [], 91002, ...
                                    datetime(2026,3,8), b{1}, b{2}, 'fixed h');
    verifyTrue(tc, meta.complete);
    [~, meta2] = soop_specular_track(base_cfg(tc), [], 91002, NaT, ...
                                     b{1}, b{2}, 'fixed h');
    verifyEqual(tc, meta2.day, datetime(2026,3,8));
end

function test_pinned_partial_day_renders_with_coverage(tc)
% Pinning the partial edge day still returns a track, flagged incomplete with
% honest coverage bounds (Jan 7 local coverage ends 17:00 MST).
    b = infs();
    [series, meta] = soop_specular_track(base_cfg(tc), [], 91001, ...
                                         datetime(2026,1,7), b{1}, b{2}, ...
                                         'fixed h');
    verifyFalse(tc, meta.complete);
    verifyTrue(tc, meta.day_pinned);
    verifyEqual(tc, meta.cov_end, datetime(2026,1,7,17,0,0));
    verifyGreaterThan(tc, series.n_valid, 0);
end

function test_no_complete_day_in_range_message(tc)
% Range restricted to only the partial last day: no complete day -> empty
% series and an explanatory message.
    b = infs();
    [series, meta] = soop_specular_track(base_cfg(tc), [], 91001, NaT, ...
                                         datetime(2026,1,7), b{2}, 'fixed h');
    verifyEmpty(tc, series);
    verifySubstring(tc, meta.msg, 'COMPLETE');
end

function test_missing_table_message(tc)
    b = infs();
    [series, meta] = soop_specular_track(base_cfg(tc), [], 99999, NaT, ...
                                         b{1}, b{2}, 'fixed h');
    verifyEmpty(tc, series);
    verifySubstring(tc, meta.msg, 'not found');
end


% =========================================================================
% ENU projection & geometry
% =========================================================================
function test_enu_directions_and_magnitude(tc)
% az = 0 -> due north (E = 0), az = 90 -> due east (N = 0); e = 45 -> offset
% equals h exactly. Dedicated table with constant e/az blocks.
    d = tc.TestData.dir;
    tt = (datetime(2026,2,1):minutes(10):datetime(2026,2,3))';
    el = 45 * ones(size(tt));
    az = zeros(size(tt));
    az(hour(tt) >= 12) = 90;                 % afternoon block points east
    T = table(tt, el, az, 38550 * ones(size(tt)), 'VariableNames', ...
              {'timestamp', 'elevation_deg', 'azimuth_deg', 'range_km'});
    writetable(T, fullfile(d, 'muos_elevation_91003.csv'));

    cfg = base_cfg(tc);
    cfg.capture_tz = 'UTC';
    b = infs();
    [series, meta] = soop_specular_track(cfg, [], 91003, ...
                                         datetime(2026,2,2), b{1}, b{2}, ...
                                         'fixed h');
    verifyTrue(tc, meta.complete);
    north = series.hour < 12;
    verifyEqual(tc, series.E(north), zeros(sum(north),1), 'AbsTol', 1e-9);
    verifyEqual(tc, series.N(north), ...
                cfg.tower_h_m * ones(sum(north),1), 'RelTol', 1e-12);
    east = series.hour >= 12;
    verifyEqual(tc, series.N(east), zeros(sum(east),1), 'AbsTol', 1e-9);
    verifyEqual(tc, series.E(east), ...
                cfg.tower_h_m * ones(sum(east),1), 'RelTol', 1e-12);
end

function test_el_min_table_reported(tc)
% el_min_table (extent input) is the minimum positive elevation in the table.
    b = infs();
    [~, meta] = soop_specular_track(base_cfg(tc), [], 91001, NaT, ...
                                    b{1}, b{2}, 'fixed h');
    verifyGreaterThanOrEqual(tc, meta.el_min_table, 32 - 1e-9);
    verifyLessThan(tc, meta.el_min_table, 35);
end


% =========================================================================
% Snow variants
% =========================================================================
function test_both_variants_with_partial_weather(tc)
% Weather covers only 06:00-18:00 of the chosen day: the snow series must be
% NaN outside that span (no extrapolation -> plotted line breaks), valid and
% offset-reducing inside it. 'both' returns fixed first, snow second.
    b = infs();
    WX = wx_table(datetime(2026,1,6,6,0,0), datetime(2026,1,6,18,0,0), 0.5);
    [series, meta] = soop_specular_track(base_cfg(tc), WX, 91001, NaT, ...
                                         b{1}, b{2}, 'both');
    verifyEqual(tc, meta.day, datetime(2026,1,6));
    verifyEqual(tc, {series.label}, {'fixed h', 'snow h'});
    snow = series(2);
    verifyLessThan(tc, snow.n_valid, meta.n_rows);        % NaN outside wx span
    verifyGreaterThan(tc, snow.n_valid, 0);
    in_wx = snow.hour >= 6 & snow.hour <= 18;
    verifyTrue(tc, all(isfinite(snow.E(in_wx))));
    verifyTrue(tc, all(isnan(snow.E(~in_wx))));
    % 0.5 m of snow raises the reflector -> smaller offset than fixed h.
    fixed = series(1);
    verifyTrue(tc, all(hypot(snow.E(in_wx), snow.N(in_wx)) < ...
                       hypot(fixed.E(in_wx), fixed.N(in_wx))));
end

function test_snow_invalid_block_not_bridged(tc)
% Finite weather on BOTH sides of an internal all-NaN SNOdar block (e.g.
% calibration drift rejected upstream): the snow track must stay NaN through
% the block — interpolating across it would fabricate a smooth track from
% rejected data. NaN depths must therefore survive as interpolation nodes.
    b = infs();
    WX = wx_table(datetime(2026,1,6,0,0,0), datetime(2026,1,7,0,0,0), 0.5);
    bad = WX.timestamp > datetime(2026,1,6,8,0,0) & ...
          WX.timestamp < datetime(2026,1,6,16,0,0);
    WX.depth_m(bad) = NaN;
    [series, ~] = soop_specular_track(base_cfg(tc), WX, 91001, NaT, ...
                                      b{1}, b{2}, 'snow h');
    verifyEqual(tc, numel(series), 1);
    % Strict masks: the exact 08:00/16:00 boundary epochs sit on interp nodes
    % adjacent to NaN intervals and are implementation-defined — not asserted.
    in_block  = series.hour > 8 & series.hour < 16;
    outside   = series.hour < 8 | series.hour > 16;
    verifyTrue(tc, all(isnan(series.E(in_block))));
    verifyTrue(tc, all(isfinite(series.E(outside))));
end

function test_snow_missing_drops_variant_keeps_fixed(tc)
% No weather at all: 'both' degrades to fixed-only with snow_msg set.
    b = infs();
    [series, meta] = soop_specular_track(base_cfg(tc), [], 91001, NaT, ...
                                         b{1}, b{2}, 'both');
    verifyEqual(tc, {series.label}, {'fixed h'});
    verifySubstring(tc, meta.snow_msg, 'snow h unavailable');
end

function test_snow_only_all_invalid_is_empty_with_msg(tc)
% Depth exceeding the tower height makes every snow epoch invalid; in
% snow-only mode that leaves nothing to draw.
    b = infs();
    WX = wx_table(datetime(2026,1,5), datetime(2026,1,8), 7.0);  % > tower_h_m
    [series, meta] = soop_specular_track(base_cfg(tc), WX, 91001, NaT, ...
                                         b{1}, b{2}, 'snow h');
    verifyEmpty(tc, series);
    verifySubstring(tc, meta.msg, 'snow h unavailable');
end


% =========================================================================
% Catalog & control wiring
% =========================================================================
function test_catalog_entry_and_order(tc)
    cfg = struct('wx_dat', '', 'rfi_bands', [], 'rfi_bands_nl', zeros(0,2), ...
                 'rfi_bands_l', zeros(0,2), 'freq_hz', 370e6, 'fs', 20e6, ...
                 'rfi_env_khz', 500, 'data_dir', tempdir, ...
                 'chain_phase_ref_deg', -81.4, 'T_load_K', 303, ...
                 'num_segs', 2, 'Ti', 0.9, 'peak_lag', -0.575, ...
                 'elev_dir', tc.TestData.dir, 'sigma0_win_hours', 24);
    PLOT_INFO = soop_viewer_catalog(cfg);
    names = {PLOT_INFO.name};
    it = find(strcmp(names, 'Radar Cal: specular track'));
    verifyNotEmpty(tc, it);
    im = find(strcmp(names, 'Radar Cal: footprint map'));
    verifyEqual(tc, it, im + 1);            % directly after the footprint map
    e = PLOT_INFO(it);
    verifyFalse(tc, e.uses_agg);
    verifyFalse(tc, e.uses_cap);
    verifyTrue(tc, strlength(e.math) > 0);
    verifySubstring(tc, char(e.expl), 'COMPLETE');   % cleared-date semantics
end

function test_dataset_selector_greyed_for_track(tc)
    U = soop_viewer_util();
    verifyFalse(tc, U.plot_uses_method('Radar Cal: specular track'));
    verifyFalse(tc, U.plot_uses_method('Radar Cal: footprint map'));
    verifyTrue(tc, U.plot_uses_method('Radar Cal: sigma0 time series'));
end

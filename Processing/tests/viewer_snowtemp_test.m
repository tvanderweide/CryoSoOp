function tests = viewer_snowtemp_test
% Tests DTC thermograph shaping and the SnowTemp top-row control.
    tests = functiontests(localfunctions);
end


function test_dtc_field_masks_air_and_orders_top_to_bottom(tc)
% Four top-to-bottom sensors span 30 cm; only the 25 cm snowpack is colored.
    U = soop_viewer_util();
    t = datetime(2026, 1, 1) + minutes(15 * (0:1));
    depth_m = [0.25; 0.20];
    dtc = [-8 -6 -3 0; -7 -5 -2 0];
    cfg = struct('wx_dtc_sensor_spacing_cm', 10, ...
                 'wx_dtc_bottom_height_cm', 0, ...
                 'wx_dtc_order', 'top_to_bottom');
    G = U.dtc_thermograph(t, depth_m, dtc, cfg);
    verifyTrue(tc, G.ok);
    verifyEqual(tc, G.height_cm(end), 25);
    verifyEqual(tc, G.temp_c(1, 1), 0, 'bottom sensor is groundward');
    verifyTrue(tc, isfinite(G.temp_c(end, 1)), ...
        'field is colored up to this timestamp''s snow surface');
    verifyTrue(tc, all(isnan(G.temp_c(G.height_cm > 20, 2))), ...
        'each timestamp uses its own snow surface');
end


function test_dtc_field_reaches_the_snow_surface(tc)
% The snow surface at 25 cm falls between sensors, so the sensor above it
% brackets the interpolation and the colored field runs right up to the
% surface instead of stopping at the topmost buried sensor.
    U = soop_viewer_util();
    t = datetime(2026, 1, 1);
    cfg = struct('wx_dtc_sensor_spacing_cm', 10, ...
                 'wx_dtc_bottom_height_cm', 0, ...
                 'wx_dtc_order', 'top_to_bottom');
    % Sensors at 30/20/10/0 cm; surface at 25 cm sits between the top two.
    G = U.dtc_thermograph(t, 0.25, [-8 -4 -2 0], cfg);
    verifyTrue(tc, G.ok);
    top = G.height_cm(find(isfinite(G.temp_c(:, 1)), 1, 'last'));
    verifyEqual(tc, top, 25, ...
        'colored field must reach the snow surface, leaving no blank band');
    % Bracketed value at the surface is the 20->30 cm interpolation.
    verifyEqual(tc, G.temp_c(G.height_cm == 25, 1), -6, 'AbsTol', 1e-9);
    verifyTrue(tc, all(isnan(G.temp_c(G.height_cm > 25, 1))), ...
        'air above the surface stays blank');
end


function test_dtc_includes_buried_soil_sensors(tc)
% Sensors below ground carry negative heights and stay in the field; the
% ground flag tells the renderer to draw the 0 cm reference line.
    U = soop_viewer_util();
    t = datetime(2026, 1, 1);
    % Six sensors, bottom three buried: heights 30/20/10/0/-10/-20 cm.
    cfg = struct('wx_dtc_sensor_spacing_cm', 10, ...
                 'wx_dtc_bottom_height_cm', -20, ...
                 'wx_dtc_order', 'top_to_bottom');
    G = U.dtc_thermograph(t, 0.30, [-9 -6 -3 -1 0.5 1.5], cfg);
    verifyTrue(tc, G.ok);
    verifyTrue(tc, G.ground_row, 'buried sensors must set the ground flag');
    verifyEqual(tc, min(G.height_cm), -20, 'field must extend to the soil');
    verifyEqual(tc, max(G.height_cm), 30);
    verifyEqual(tc, G.sensor_h, [30 20 10 0 -10 -20], 'AbsTol', 1e-9);
    verifyEqual(tc, G.temp_c(G.height_cm == -20, 1), 1.5, 'AbsTol', 1e-9);
    verifyEqual(tc, G.temp_c(G.height_cm == 0, 1), -1, 'AbsTol', 1e-9);
    verifyTrue(tc, all(isfinite(G.temp_c(G.height_cm <= 0, 1))), ...
        'soil column must be continuous');
end


function test_dtc_sensor_count_is_flexible(tc)
% Cable length varies between sites while spacing does not: the geometry
% follows the column count of the supplied matrix, not a fixed constant.
    U = soop_viewer_util();
    t = datetime(2026, 1, 1);
    cfg = struct('wx_dtc_sensor_spacing_cm', 10, ...
                 'wx_dtc_bottom_height_cm', -10, ...
                 'wx_dtc_order', 'top_to_bottom');
    for n = [4 12 37]
        v = linspace(-10, 2, n);
        G = U.dtc_thermograph(t, 0.20, v, cfg);
        verifyTrue(tc, G.ok, sprintf('%d-sensor cable must shape', n));
        verifyNumElements(tc, G.sensor_h, n);
        verifyEqual(tc, max(G.sensor_h), (n - 2) * 10, 'AbsTol', 1e-9, ...
            sprintf('%d-sensor top height', n));
        verifyEqual(tc, min(G.sensor_h), -10, 'AbsTol', 1e-9);
    end
end


function test_dtc_bottom_to_top_order_and_invalid_geometry(tc)
% Reversed cable order flips the height mapping; bad geometry reports why.
    U = soop_viewer_util();
    t = datetime(2026, 1, 1);
    base = struct('wx_dtc_sensor_spacing_cm', 10, ...
                  'wx_dtc_bottom_height_cm', 0);
    cfg = base;  cfg.wx_dtc_order = 'bottom_to_top';
    G = U.dtc_thermograph(t, 0.30, [0 -3 -6 -9], cfg);
    verifyTrue(tc, G.ok);
    verifyEqual(tc, G.sensor_h, [0 10 20 30], 'AbsTol', 1e-9);
    verifyEqual(tc, G.temp_c(G.height_cm == 0, 1), 0, 'AbsTol', 1e-9);

    cfg = base;  cfg.wx_dtc_order = 'sideways';
    G = U.dtc_thermograph(t, 0.30, [0 -3 -6 -9], cfg);
    verifyFalse(tc, G.ok);
    verifyNotEmpty(tc, G.why);

    cfg = struct('wx_dtc_sensor_spacing_cm', -5, 'wx_dtc_bottom_height_cm', 0);
    G = U.dtc_thermograph(t, 0.30, [0 -3 -6 -9], cfg);
    verifyFalse(tc, G.ok);
end


function test_dtc_partial_nan_and_empty_input(tc)
% A dead sensor still permits interpolation from remaining snow sensors;
% all-NaN records return a message rather than an invalid field.
    U = soop_viewer_util();
    t = datetime(2026, 1, 1) + minutes(15 * (0:1));
    cfg = struct('wx_dtc_sensor_spacing_cm', 10, ...
                 'wx_dtc_bottom_height_cm', 0, ...
                 'wx_dtc_order', 'top_to_bottom');
    G = U.dtc_thermograph(t, [0.2; 0.2], [-7 NaN -2 0; NaN NaN NaN NaN], cfg);
    verifyTrue(tc, G.ok);
    verifyTrue(tc, any(isfinite(G.temp_c(:, 1))));
    verifyTrue(tc, all(isnan(G.temp_c(:, 2))), 'all-NaN time gap stays blank');
    Gempty = U.dtc_thermograph(t, [0.2; 0.2], nan(2, 4), cfg);
    verifyFalse(tc, Gempty.ok);
    verifyNotEmpty(tc, Gempty.why);
end


function test_snowtemp_checkbox_follows_abovefreezing(tc)
% The new checkbox is immediately right of AboveFreezing and only visible
% on the four MUOS Candidates views, not L2: Sensor data.
    cfg = minimal_cfg();
    V = build_viewer(cfg);
    cleanup = onCleanup(@() delete(V.fig));
    verifyEqual(tc, V.cb_snowtemp.Text, 'SnowTemp');
    verifyEqual(tc, V.cb_snowtemp.Layout.Column, V.cb_abvfrz.Layout.Column + 1);
    V.CB.set_family_rows(V, true, false);
    verifyFalse(tc, logical(V.cb_snowtemp.Visible));
    V.CB.set_family_rows(V, true, true);
    verifyTrue(tc, logical(V.cb_snowtemp.Visible));
end


function test_snowtemp_render_creates_linked_lower_axes(tc)
% A valid DTC record draws a lower thermograph with the same time limits.
    cfg = minimal_cfg();
    V = build_viewer(cfg);
    cleanup = onCleanup(@() delete(V.fig));
    t = datetime(2026, 1, 1) + minutes(15 * (0:3)');
    V.CAND = table(t, "cap" + string((1:4)'), 20 * ones(4, 1), ...
        (10:10:40)', 'VariableNames', {'timestamp', 'base_name', 'snr_db', 'corr_41622'});
    V.WX = table(t, 0.25 * ones(4, 1), repmat([-8 -6 -3 0], 4, 1), ...
        'VariableNames', {'timestamp', 'depth_m', 'dtc_c'});
    V.dp1.Value = t(1);  V.dp2.Value = t(end);
    V.cb_snowtemp.Value = true;
    soop_viewer_render_l2(V, 'L2: Candidates — MUOS-5 (41622)');
    axs = findobj(V.panel, 'Type', 'axes');
    verifyGreaterThanOrEqual(tc, numel(axs), 2);
    verifyEqual(tc, axs(1).XLim, axs(2).XLim);
    verifyNotEmpty(tc, findobj(V.panel, 'Type', 'ColorBar'));
end


% ============================================ SnowTemp: color-scale bounds

function test_dtc_clim_validates_and_falls_back(tc)
% clim() errors on a non-increasing range, so the render's own re-check must
% reject any pair it could not use rather than pass it through.
    U   = soop_viewer_util();
    def = [-12 1];

    verifyEqual(tc, U.dtc_clim(-20, 5, def), [-20 5]);
    verifyEqual(tc, U.dtc_clim(-12.5, 0.5, def), [-12.5 0.5]);   % fractional
    verifyEqual(tc, U.dtc_clim(int8(-5), 2, def), [-5 2]);       % integer type

    verifyEqual(tc, U.dtc_clim(5, -5, def), def);                % inverted
    verifyEqual(tc, U.dtc_clim(3, 3, def), def);                 % zero span
    verifyEqual(tc, U.dtc_clim(NaN, 1, def), def);
    verifyEqual(tc, U.dtc_clim(-12, Inf, def), def);
    verifyEqual(tc, U.dtc_clim([], 1, def), def);
    verifyEqual(tc, U.dtc_clim([-12 -6], 1, def), def);          % non-scalar
    verifyEqual(tc, U.dtc_clim('a', 1, def), def);
    verifyEqual(tc, U.dtc_clim(-12 + 1i, 1, def), def);          % complex
end


function test_dtc_clim_spinners_stay_ordered(tc)
% The ordering rule pushes the PARTNER of whichever spinner moved, so the edit
% the user just made survives and an inverted pair never reaches the render.
    U    = soop_viewer_util();
    span = [-40 20];
    step = 1;
    ord  = @(lo, hi, which) U.dtc_clim_order(lo, hi, which, span, step);

    % Already ordered: untouched.
    verifyEqual(tc, ord(-12, 1, 'lo'), [-12 1]);
    verifyEqual(tc, ord(-12, 1, 'hi'), [-12 1]);

    % Low pushed above high: low keeps the user's value, high gives way.
    cl = ord(6, 1, 'lo');
    verifyEqual(tc, cl(1), 6);
    verifyGreaterThan(tc, cl(2), cl(1));

    % High pulled below low: high keeps the user's value, low gives way.
    cl = ord(-12, -30, 'hi');
    verifyEqual(tc, cl(2), -30);
    verifyLessThan(tc, cl(1), cl(2));

    % Equal values are also invalid (clim needs a nonzero span).
    cl = ord(0, 0, 'lo');
    verifyLessThan(tc, cl(1), cl(2));

    % Saturating at the travel limit still leaves an ordered pair inside span:
    % the moved spinner yields when its partner has nowhere left to go.
    cl = ord(span(2), 0, 'lo');
    verifyLessThan(tc, cl(1), cl(2));
    verifyLessThanOrEqual(tc, cl(2), span(2));

    cl = ord(0, span(1), 'hi');
    verifyLessThan(tc, cl(1), cl(2));
    verifyGreaterThanOrEqual(tc, cl(1), span(1));
end


function test_dtc_clim_spinner_defaults(tc)
% The row ships at the documented defaults over the documented travel.
    cfg = minimal_cfg();
    V = build_viewer(cfg);
    cleanup = onCleanup(@() delete(V.fig));

    verifyEqual(tc, V.sp_dtc_lo.Value, V.DTC_CLIM_DEFAULT_C(1));
    verifyEqual(tc, V.sp_dtc_hi.Value, V.DTC_CLIM_DEFAULT_C(2));
    verifyEqual(tc, V.sp_dtc_lo.Limits, V.DTC_CLIM_RANGE_C);
    verifyEqual(tc, V.sp_dtc_hi.Limits, V.DTC_CLIM_RANGE_C);
end


function test_dtc_clim_row_visibility_and_gating(tc)
% Visible with the candidates family, adjustable only while the thermograph it
% scales is actually drawn.
    cfg = minimal_cfg();
    V = build_viewer(cfg);
    cleanup = onCleanup(@() delete(V.fig));

    verifyFalse(tc, logical(V.dtc_clim_row.Visible));
    V.cb_snowtemp.Value = false;
    V.CB.set_family_rows(V, true, true);
    verifyTrue(tc, logical(V.dtc_clim_row.Visible));
    verifyFalse(tc, logical(V.sp_dtc_lo.Enable));
    verifyFalse(tc, logical(V.sp_dtc_hi.Enable));

    V.cb_snowtemp.Value = true;
    V.CB.set_family_rows(V, true, true);
    verifyTrue(tc, logical(V.sp_dtc_lo.Enable));
    verifyTrue(tc, logical(V.sp_dtc_hi.Enable));

    % Off the candidates family the row hides again.
    V.CB.set_family_rows(V, true, false);
    verifyFalse(tc, logical(V.dtc_clim_row.Visible));
end


function test_dtc_clim_reaches_the_rendered_colorbar(tc)
% The spinner values must land on the thermograph axes in BOTH SnowTemp modes,
% since the continuous field and the Nearest bands share one color scale.
    % Continuous mode.
    cfg = minimal_cfg();
    V = build_viewer(cfg);
    c1 = onCleanup(@() delete(V.fig));
    t = datetime(2026, 1, 1) + minutes(15 * (0:3)');
    V.CAND = table(t, "cap" + string((1:4)'), 20 * ones(4, 1), (10:10:40)', ...
        'VariableNames', {'timestamp', 'base_name', 'snr_db', 'corr_41622'});
    V.WX = table(t, 0.25 * ones(4, 1), repmat([-8 -6 -3 0], 4, 1), ...
        'VariableNames', {'timestamp', 'depth_m', 'dtc_c'});
    V.dp1.Value = t(1);  V.dp2.Value = t(end);
    V.cb_snowtemp.Value = true;
    V.sp_dtc_lo.Value = -25;  V.sp_dtc_hi.Value = 3;
    soop_viewer_render_l2(V, 'L2: Candidates — MUOS-5 (41622)');
    verifyEqual(tc, tagged_dtc(tc, V).CLim, [-25 3], 'AbsTol', 1e-12);

    % Nearest mode shares the same scale.
    V2 = nearest_fixture();
    c2 = onCleanup(@() delete(V2.fig));
    V2.sp_dtc_lo.Value = -25;  V2.sp_dtc_hi.Value = 3;
    soop_viewer_render_l2(V2, 'L2: Candidates — MUOS-5 (41622)');
    verifyEqual(tc, tagged_dtc(tc, V2).CLim, [-25 3], 'AbsTol', 1e-12);
end


function test_dtc_clim_invalid_pair_falls_back_at_render(tc)
% If anything sets an inverted pair behind the spinners' back, the render's own
% re-check substitutes the defaults instead of letting clim() error out and
% take the whole figure down.
    V = nearest_fixture();
    cleanup = onCleanup(@() delete(V.fig));
    V.sp_dtc_lo.Value = 5;
    V.sp_dtc_hi.Value = -5;      % set directly, bypassing on_dtc_clim
    soop_viewer_render_l2(V, 'L2: Candidates — MUOS-5 (41622)');
    verifyEqual(tc, tagged_dtc(tc, V).CLim, V.DTC_CLIM_DEFAULT_C, 'AbsTol', 1e-12);
end


function axD = tagged_dtc(tc, V)
    axD = findobj(V.panel, 'Type', 'axes', 'Tag', 'soop_dtc');
    verifyNumElements(tc, axD, 1, 'tagged thermograph axes must exist');
end


function test_dtc_clim_default_places_freezing_at_the_ramp_top(tc)
% The "melting-point snow reads red" cue is a property of the DEFAULT LIMITS,
% not of dtc_colormap(), which carries no anchor at 0 C. This pins the default
% so the cue cannot drift silently; changing it is a deliberate edit here too.
    cfg = minimal_cfg();
    V = build_viewer(cfg);
    cleanup = onCleanup(@() delete(V.fig));

    def = V.DTC_CLIM_DEFAULT_C;
    verifyEqual(tc, def, [-12 1]);
    frac = (0 - def(1)) / (def(2) - def(1));    % where 0 C sits on the ramp
    verifyGreaterThan(tc, frac, 0.9);
end


% ============================================ SnowTemp - Nearest: helpers

function test_nearest_wx_idx_selection_window_and_ties(tc)
% Nearest usable observation wins; matches beyond the window report 0; equal
% distances take the earlier weather timestamp, then the earlier row.
    U = soop_viewer_util();
    t0 = datetime(2026, 1, 1, 12, 0, 0);
    t_wx = t0 + minutes([-40 -10 5 50]);
    ok4 = true(4, 1);
    idx = U.nearest_wx_idx(t0, t_wx, ok4, minutes(35));
    verifyEqual(tc, idx, 3, 'the +5 min record is nearest');

    % Window boundary is inclusive, and one minute past it is not a match.
    verifyEqual(tc, U.nearest_wx_idx(t0, t0 + minutes(35), true, minutes(35)), 1);
    verifyEqual(tc, U.nearest_wx_idx(t0, t0 + minutes(36), true, minutes(35)), 0);

    % valid mask excludes the closest row, so the next usable one wins.
    idx = U.nearest_wx_idx(t0, t_wx, [true; true; false; true], minutes(35));
    verifyEqual(tc, idx, 2, 'unusable nearest row must be skipped');

    % Tie: equidistant either side -> earlier timestamp.
    tie = t0 + minutes([-10 10]);
    verifyEqual(tc, U.nearest_wx_idx(t0, tie, true(2, 1), minutes(35)), 1);
    % Duplicate timestamps at equal distance -> earlier original row.
    dup = t0 + minutes([10 10]);
    verifyEqual(tc, U.nearest_wx_idx(t0, dup, true(2, 1), minutes(35)), 1);
end


function test_nearest_wx_idx_unsorted_nat_and_orientation(tc)
% Row order of the weather table must not change the answer, NaT rows drop
% out, and row/column inputs behave alike.
    U = soop_viewer_util();
    t0 = datetime(2026, 1, 1, 12, 0, 0);
    t_wx = t0 + minutes([50 5 -10 -40]);     % deliberately unsorted
    idx = U.nearest_wx_idx(t0, t_wx, true(4, 1), minutes(35));
    verifyEqual(tc, idx, 2, 'returns the original row index, not sorted order');

    % NaT capture yields no match; NaT weather row is ignored.
    verifyEqual(tc, U.nearest_wx_idx(NaT, t_wx, true(4, 1), minutes(35)), 0);
    t_nat = [NaT; t0 + minutes(5)];
    verifyEqual(tc, U.nearest_wx_idx(t0, t_nat, true(2, 1), minutes(35)), 2);

    % Row vector capture input still returns a column aligned with it.
    idx = U.nearest_wx_idx([t0, t0 + hours(3)], t_wx, true(4, 1), minutes(35));
    verifyEqual(tc, size(idx), [2 1]);
    verifyEqual(tc, idx, [2; 0]);

    % Empty inputs are not an error.
    verifyEmpty(tc, U.nearest_wx_idx(datetime.empty(0, 1), t_wx, true(4, 1), minutes(35)));
end


function test_nearest_wx_idx_validation(tc)
% The new public contract validates its arguments rather than failing later.
    U = soop_viewer_util();
    t0 = datetime(2026, 1, 1);
    t_wx = t0 + minutes([0 15]);
    verifyError(tc, @() U.nearest_wx_idx(t0, t_wx, [1 0], minutes(35)), ...
        'soop_viewer_util:nearest_wx_idx:valid', 'valid must be logical');
    verifyError(tc, @() U.nearest_wx_idx(t0, t_wx, true(3, 1), minutes(35)), ...
        'soop_viewer_util:nearest_wx_idx:valid', 'valid must match t_wx length');
    verifyError(tc, @() U.nearest_wx_idx(t0, t_wx, true(2, 1), 35), ...
        'soop_viewer_util:nearest_wx_idx:window');
    verifyError(tc, @() U.nearest_wx_idx(t0, t_wx, true(2, 1), minutes(-1)), ...
        'soop_viewer_util:nearest_wx_idx:window');
    verifyError(tc, @() U.nearest_wx_idx(0, t_wx, true(2, 1), minutes(35)), ...
        'soop_viewer_util:nearest_wx_idx:type');
    tz = t_wx;  tz.TimeZone = 'UTC';
    verifyError(tc, @() U.nearest_wx_idx(t0, tz, true(2, 1), minutes(35)), ...
        'soop_viewer_util:nearest_wx_idx:timezone');
end


function test_dtc_renderable_matches_shaper(tc)
% The renderable mask must agree with what dtc_thermograph can actually draw,
% so a blank profile never wins a nearest match.
    U = soop_viewer_util();
    cfg = struct('wx_dtc_sensor_spacing_cm', 10, ...
                 'wx_dtc_bottom_height_cm', 0, ...
                 'wx_dtc_order', 'top_to_bottom');
    dtc = [ -8   -6   -3    0;      % good: several nodes under 25 cm
            NaN  NaN  NaN    0;     % only one finite sensor
            -8   -6   -3    0;      % nonpositive depth
            -8   -6   -3    0 ];    % depth below the lowest sensor
    depth_m = [0.25; 0.25; 0; -1];
    ok = U.dtc_renderable(depth_m, dtc, cfg);
    verifyEqual(tc, ok, [true; false; false; false]);

    % Cross-check each row against a single-row shape of the same data.
    for k = 1:4
        G = U.dtc_thermograph(datetime(2026, 1, 1), depth_m(k), dtc(k, :), cfg);
        verifyEqual(tc, G.ok, ok(k), sprintf('row %d must agree with shaper', k));
    end
end


function test_nearest_prefers_renderable_over_closer_blank(tc)
% A closer but unrenderable observation must lose to a farther drawable one,
% for every way a profile can fail to be drawable.
    U = soop_viewer_util();
    cfg = struct('wx_dtc_sensor_spacing_cm', 10, ...
                 'wx_dtc_bottom_height_cm', 0, ...
                 'wx_dtc_order', 'top_to_bottom');
    t0 = datetime(2026, 1, 1, 12, 0, 0);
    t_wx = t0 + minutes([2 20]);
    good = [-8 -6 -3 0];
    % With the lowest sensor at 0 cm any positive depth has extent, so the
    % zero-extent case lives in test_dtc_zero_vertical_extent_fails_closed.
    bad = { [NaN NaN NaN 0], 0.25, 'single finite sensor'; ...
            good,            0,    'nonpositive depth'; ...
            good,           -1,    'negative depth'; ...
            [NaN NaN NaN NaN], 0.25, 'all sensors dead' };
    for k = 1:size(bad, 1)
        dtc = [bad{k, 1}; good];
        depth_m = [bad{k, 2}; 0.25];
        ok = U.dtc_renderable(depth_m, dtc, cfg);
        verifyEqual(tc, ok, [false; true], bad{k, 3});
        verifyEqual(tc, U.nearest_wx_idx(t0, t_wx, ok, minutes(35)), 2, bad{k, 3});
    end
end


function test_dtc_zero_vertical_extent_fails_closed(tc)
% Bottom sensor above ground with the snow surface AT that sensor leaves one
% height row and no drawable extent. It must be rejected by both the shaper and
% the renderable mask, so the renderer is never handed degenerate y-limits.
    U = soop_viewer_util();
    cfg = struct('wx_dtc_sensor_spacing_cm', 10, ...
                 'wx_dtc_bottom_height_cm', 10, ...   % lowest sensor at +10 cm
                 'wx_dtc_order', 'top_to_bottom');
    G = U.dtc_thermograph(datetime(2026, 1, 1), 0.10, [-5 -1], cfg);
    verifyFalse(tc, G.ok, 'surface at the lowest sensor has no extent');
    verifyNotEmpty(tc, G.why);
    verifyFalse(tc, U.dtc_renderable(0.10, [-5 -1], cfg), ...
        'renderable mask must agree with the shaper');
    % Just below the lowest sensor is also rejected; just above is fine.
    verifyFalse(tc, U.dtc_renderable(0.05, [-5 -1], cfg));
    verifyTrue(tc, U.dtc_renderable(0.15, [-5 -1], cfg));

    % A farther row with real extent wins the nearest match over this one.
    t0 = datetime(2026, 1, 1, 12, 0, 0);
    ok = U.dtc_renderable([0.10; 0.15], [-5 -1; -5 -1], cfg);
    verifyEqual(tc, ok, [false; true]);
    verifyEqual(tc, U.nearest_wx_idx(t0, t0 + minutes([2 20]), ok, minutes(35)), 2);
end


function test_nearest_wx_idx_two_nonempty_timezones(tc)
% Two different named zones describing the same instants are comparable, and
% the matcher still returns the original weather row.
    U = soop_viewer_util();
    t_den = datetime(2026, 1, 1, 5, 0, 0, 'TimeZone', 'America/Denver');
    t_wx = t_den + minutes([-40 5 50]);
    t_wx.TimeZone = 'UTC';                    % same instants, other zone
    idx = U.nearest_wx_idx(t_den, t_wx, true(3, 1), minutes(35));
    verifyEqual(tc, idx, 2, 'zoned comparison must match across named zones');
end


function test_band_halfwidth(tc)
% Pixel width maps through the axes width and the datetime span; unusable
% geometry falls back to a fraction of the span so a band is always visible.
    U = soop_viewer_util();
    t0 = datetime(2026, 1, 1);
    span = days(100);
    h = U.band_halfwidth(t0, t0 + span, 1000, 8);
    verifyEqual(tc, h, 0.5 * (8 / 1000) * span, 'AbsTol', milliseconds(1));
    % Halving the axes width doubles the band's time width.
    h2 = U.band_halfwidth(t0, t0 + span, 500, 8);
    verifyEqual(tc, h2, 2 * h, 'AbsTol', milliseconds(1));
    % Halving the span halves it.
    h3 = U.band_halfwidth(t0, t0 + span / 2, 1000, 8);
    verifyEqual(tc, h3, h / 2, 'AbsTol', milliseconds(1));
    % Unusable axes width -> fraction-of-span fallback, still positive.
    for bad = {0, -5, NaN, Inf, [], 'x'}
        hb = U.band_halfwidth(t0, t0 + span, bad{1}, 8);
        verifyGreaterThan(tc, seconds(hb), 0, 'fallback must be positive');
        verifyLessThan(tc, hb, span, 'fallback must stay inside the span');
    end
    % Nonpositive or invalid span -> zero, never negative.
    verifyEqual(tc, U.band_halfwidth(t0, t0, 1000, 8), seconds(0));
    verifyEqual(tc, U.band_halfwidth(t0, t0 - span, 1000, 8), seconds(0));
    % A band wider than the axes is clamped to the full span.
    verifyEqual(tc, U.band_halfwidth(t0, t0 + span, 10, 500), 0.5 * span, ...
        'AbsTol', milliseconds(1));
end


function test_snowtemp_nearest_bands_keys_capture_time(tc)
% Bands carry CAPTURE times (not observation times), come out in capture
% order, and are not deduplicated when two captures share one profile.
    U = soop_viewer_util();
    cfg = struct('wx_dtc_sensor_spacing_cm', 10, ...
                 'wx_dtc_bottom_height_cm', -10, ...
                 'wx_dtc_order', 'top_to_bottom');
    t_wx = datetime(2026, 1, 1) + hours([0 24]);
    WX = table(t_wx(:), [0.25; 0.30], [-8 -6 -3 0; -9 -7 -4 -1], ...
        'VariableNames', {'timestamp', 'depth_m', 'dtc_c'});
    % Two captures resolve to weather row 1, one to row 2; supplied unsorted.
    t_cap = datetime(2026, 1, 1) + hours([25 1 0]);
    B = U.snowtemp_nearest_bands(t_cap, [2; 1; 1], WX, cfg);
    verifyTrue(tc, B.on);
    verifyNumElements(tc, B.cols, 3, 'one band per capture, no dedup');
    verifyEqual(tc, B.t_cap(:), sort(t_cap(:)), 'emitted in capture-time order');
    verifyEqual(tc, B.cols{1}.t, datetime(2026, 1, 1), 'band sits at capture time');
    verifyTrue(tc, B.ground_row, 'buried sensors flagged through to the renderer');
    verifyEqual(tc, B.h_lo, -10);

    % Unshapeable matches are dropped rather than drawn blank.
    WX.depth_m(:) = 0;
    verifyFalse(tc, U.snowtemp_nearest_bands(t_cap, [2; 1; 1], WX, cfg).on);
    % Mismatched lengths and empty input are inert.
    verifyFalse(tc, U.snowtemp_nearest_bands(t_cap, [1; 1], WX, cfg).on);
    verifyFalse(tc, U.snowtemp_nearest_bands(datetime.empty(0, 1), [], WX, cfg).on);
end


% ============================================= SnowTemp - Nearest: UI + render

function test_snowtemp_nearest_checkbox_contract(tc)
% Placed under the AboveFreezing-Nearest group, candidate-only, and needs both
% Daily capture nearest and SnowTemp before it can be used.
    cfg = minimal_cfg();
    V = build_viewer(cfg);
    cleanup = onCleanup(@() delete(V.fig));
    verifyEqual(tc, V.cb_snowtemp_nearest.Text, 'SnowTemp - Nearest');
    verifyEqual(tc, V.snowtemp_nearest_row.Layout.Row, ...
                V.abvfrz_nearest_width_row.Layout.Row + 1, ...
                'sits below the whole AboveFreezing - Nearest group');
    verifyFalse(tc, logical(V.snowtemp_nearest_row.Visible));
    verifyFalse(tc, logical(V.cb_snowtemp_nearest.Enable));

    V.CB.set_family_rows(V, true, false);            % L2: Sensor data
    verifyFalse(tc, logical(V.snowtemp_nearest_row.Visible));
    V.CB.set_family_rows(V, true, true);             % Candidates views
    verifyTrue(tc, logical(V.snowtemp_nearest_row.Visible));
    verifyFalse(tc, logical(V.cb_snowtemp_nearest.Enable), 'daily still off');

    V.cb_tod.Value = true;
    V.CB.set_family_rows(V, true, true);
    verifyFalse(tc, logical(V.cb_snowtemp_nearest.Enable), 'SnowTemp still off');
    V.cb_snowtemp.Value = true;
    V.CB.set_family_rows(V, true, true);
    verifyTrue(tc, logical(V.cb_snowtemp_nearest.Enable), 'both prerequisites met');

    % Clearing EITHER prerequisite disables without discarding the value.
    V.cb_snowtemp_nearest.Value = true;
    V.cb_tod.Value = false;
    V.CB.set_family_rows(V, true, true);
    verifyFalse(tc, logical(V.cb_snowtemp_nearest.Enable), 'daily cleared');
    verifyTrue(tc, V.cb_snowtemp_nearest.Value, 'value must persist');

    V.cb_tod.Value = true;
    V.cb_snowtemp.Value = false;
    V.CB.set_family_rows(V, true, true);
    verifyFalse(tc, logical(V.cb_snowtemp_nearest.Enable), 'SnowTemp cleared');
    verifyTrue(tc, V.cb_snowtemp_nearest.Value, 'value must persist');

    % Tooltip states the capture-time and continuous-context contract.
    tip = V.cb_snowtemp_nearest.Tooltip;
    verifySubstring(tc, tip, 'capture');
    verifySubstring(tc, tip, num2str(SoopViewerState.SNOWTEMP_NEAREST_WINDOW_MIN));
    verifySubstring(tc, lower(tip), 'continuous');
end


function test_snowtemp_nearest_catalog_wording(tc)
% The four Candidates entries must document the chosen policy: bands at capture
% times, the inclusive source window, renderable-only selection, and that the
% restriction covers the temperature field only.
    cfg = minimal_cfg();
    [PI, ~] = soop_viewer_catalog(cfg);
    kinds = {'L2: Candidates — MUOS-1 (38093)', 'L2: Candidates — MUOS-5 (41622)', ...
             'L2: Candidates Unwrapped — MUOS-1 (38093)', ...
             'L2: Candidates Unwrapped — MUOS-5 (41622)'};
    win = num2str(SoopViewerState.SNOWTEMP_NEAREST_WINDOW_MIN);
    for k = 1:numel(kinds)
        idx = find(strcmp({PI.name}, kinds{k}), 1);
        verifyNotEmpty(tc, idx, kinds{k});
        txt = PI(idx).expl;
        verifySubstring(tc, txt, 'SnowTemp - Nearest', kinds{k});
        verifySubstring(tc, txt, 'CAPTURE time', kinds{k});
        verifySubstring(tc, txt, win, kinds{k});
        verifySubstring(tc, lower(txt), 'snow-depth', kinds{k});
    end
end


function test_snowtemp_nearest_render_draws_one_band_per_capture(tc)
% Nearest mode replaces the continuous field with one two-column surface per
% kept capture, and keeps the continuous depth and ground context lines.
    V = nearest_fixture();
    cleanup = onCleanup(@() delete(V.fig));
    soop_viewer_render_l2(V, 'L2: Candidates — MUOS-5 (41622)');
    axD = thermograph_axes(tc, V);
    srf = findobj(axD, 'Type', 'surface');
    verifyNumElements(tc, srf, 3, 'one band per matched capture');
    for k = 1:numel(srf)
        verifyEqual(tc, size(srf(k).CData, 2), 2, 'each band is two columns');
        verifyEqual(tc, srf(k).CData(:, 1), srf(k).CData(:, 2), ...
            'band columns are identical so the profile reads flat in time');
        verifyTrue(tc, all(srf(k).ZData(:) == 0), 'field drawn in the z=0 plane');
        verifyTrue(tc, all(isfinite(srf(k).XData(:))), 'band edges finite');
    end
    % Context lines survive with their CONTINUOUS data: the restriction applies
    % to the temperature field only, not to the depth record.
    ln = findobj(axD, 'Type', 'line');
    verifyNumElements(tc, ln, 1, 'depth line retained');
    verifyEqual(tc, reshape(ln.YData, [], 1), 100 * V.WX.depth_m, 'AbsTol', 1e-9, ...
        'depth line keeps every record, not just matched ones');
    gl = findobj(axD, 'Type', 'constantline');
    verifyNumElements(tc, gl, 1, 'ground line retained');
    verifyEqual(tc, gl.Value, 0, 'ground reference sits at 0 cm');
    % Bands are centered on capture times, not observation times.
    centers = sort(cellfun(@(s) mean(s.XData(:)), num2cell(srf)));
    verifyLessThan(tc, max(abs(centers(:) - sort(V.CAND.timestamp(:)))), ...
        seconds(1), 'band centers are the capture times');
end


function test_snowtemp_continuous_mode_unchanged_and_pinned(tc)
% With the modifier off the subplot is the continuous field: one surface whose
% column count follows the weather records, with the documented color limits.
    V = nearest_fixture();
    V.cb_snowtemp_nearest.Value = false;
    cleanup = onCleanup(@() delete(V.fig));
    soop_viewer_render_l2(V, 'L2: Candidates — MUOS-5 (41622)');
    axD = thermograph_axes(tc, V);
    srf = findobj(axD, 'Type', 'surface');
    verifyNumElements(tc, srf, 1, 'continuous mode draws a single surface');
    verifyEqual(tc, size(srf.CData, 2), height(V.WX), 'one column per record');
    % XData is the weather time base itself, not a band expansion.
    verifyEqual(tc, reshape(srf.XData, 1, []), ...
        reshape(V.WX.timestamp, 1, []), 'continuous XData is the record times');
    verifyEqual(tc, axD.CLim, [-12 1]);
    % The thermograph shares the phase plot's time axis.
    axs = findobj(V.panel, 'Type', 'axes');
    axMain = axs(axs ~= axD);
    verifyEqual(tc, axD.XLim, axMain(1).XLim, 'x axis shared with the main plot');
    verifyNotEmpty(tc, findobj(V.panel, 'Type', 'ColorBar'), 'colorbar present');
    % Depth line carries the range's depth record in cm.
    ln = findobj(axD, 'Type', 'line');
    verifyNumElements(tc, ln, 1);
    verifyEqual(tc, reshape(ln.YData, [], 1), 100 * V.WX.depth_m, 'AbsTol', 1e-9);
end


function test_snowtemp_nearest_empty_weather_table_reason(tc)
% A typed but EMPTY weather table has the columns and still cannot supply a
% profile — the stated reason must say so rather than blame the schema.
    V = nearest_fixture();
    cleanup = onCleanup(@() delete(V.fig));
    V.WX = V.WX([], :);                      % keeps variable names, no rows
    soop_viewer_render_l2(V, 'L2: Candidates — MUOS-5 (41622)');
    axD = thermograph_axes(tc, V);
    verifyEmpty(tc, findobj(axD, 'Type', 'surface'));
    txt = findobj(axD, 'Type', 'text');
    verifyNotEmpty(tc, txt);
    msg = strjoin({txt.String}, ' ');
    verifySubstring(tc, msg, 'empty', 'must report emptiness, not missing columns');
    verifyEmpty(tc, strfind(msg, 'no DTC or snow-depth columns'), ...
        'schema reason must not be used for an empty table');
end


function test_snowtemp_nearest_fails_closed(tc)
% Nearest mode never silently falls back to the continuous field: with no
% observation inside the window it reports why and draws no temperature field.
    V = nearest_fixture();
    cleanup = onCleanup(@() delete(V.fig));
    % Push every weather record far away from the captures.
    V.WX.timestamp = V.WX.timestamp + days(30);
    soop_viewer_render_l2(V, 'L2: Candidates — MUOS-5 (41622)');
    axD = thermograph_axes(tc, V);
    verifyEmpty(tc, findobj(axD, 'Type', 'surface'), 'no field when nothing matches');
    txt = findobj(axD, 'Type', 'text');
    verifyNotEmpty(tc, txt, 'must state a reason');
    verifySubstring(tc, strjoin({txt.String}, ' '), 'SnowTemp unavailable');

    % Dropping the DTC column reports a schema reason rather than vanishing.
    V2 = nearest_fixture();
    c2 = onCleanup(@() delete(V2.fig));
    V2.WX.dtc_c = [];
    soop_viewer_render_l2(V2, 'L2: Candidates — MUOS-5 (41622)');
    axD2 = thermograph_axes(tc, V2);
    verifyEmpty(tc, findobj(axD2, 'Type', 'surface'));
    verifyNotEmpty(tc, findobj(axD2, 'Type', 'text'));
end


function test_snowtemp_nearest_window_boundary_at_render(tc)
% The 35-minute contract holds through the renderer, not just the helper.
    win = SoopViewerState.SNOWTEMP_NEAREST_WINDOW_MIN;
    for off = [win, win + 1]
        V = nearest_fixture();
        c = onCleanup(@() delete(V.fig));
        % Offset measured from the capture times, not added to the fixture's
        % existing 5 min lead.
        V.WX.timestamp = V.CAND.timestamp + minutes(off);
        soop_viewer_render_l2(V, 'L2: Candidates — MUOS-5 (41622)');
        srf = findobj(thermograph_axes(tc, V), 'Type', 'surface');
        if off <= win
            verifyNotEmpty(tc, srf, sprintf('%d min must still match', off));
        else
            verifyEmpty(tc, srf, sprintf('%d min must not match', off));
        end
        clear c;
    end
end


function test_snowtemp_nearest_matches_outside_displayed_range(tc)
% Nearest mode matches against the FULL weather table, so a capture retained
% by the daily filter's range slack still finds its profile even when the
% range-clipped table contributes nothing.
    cfg = minimal_cfg();
    cfg.wx_dtc_sensor_spacing_cm = 10;
    cfg.wx_dtc_bottom_height_cm = -10;
    cfg.wx_dtc_order = 'top_to_bottom';
    V = build_viewer(cfg);
    cleanup = onCleanup(@() delete(V.fig));
    t_cap = datetime(2026, 1, 1, 6, 0, 0);   % daily filter's default target
    V.CAND = table(t_cap, "cap1", 20, 10, ...
        'VariableNames', {'timestamp', 'base_name', 'snr_db', 'corr_41622'});
    % The one weather record sits 20 min BEFORE the range start, so the
    % range-clipped table is empty while the full table still holds a match.
    V.WX = table(t_cap - minutes(20), 0.25, [-8 -6 -3 0], ...
        'VariableNames', {'timestamp', 'depth_m', 'dtc_c'});
    V.dp1.Value = t_cap;
    V.dp2.Value = t_cap + minutes(30);
    V.cb_snowtemp.Value = true;
    V.cb_tod.Value = true;
    V.cb_snowtemp_nearest.Value = true;
    soop_viewer_render_l2(V, 'L2: Candidates — MUOS-5 (41622)');
    axD = thermograph_axes(tc, V);
    verifyNotEmpty(tc, findobj(axD, 'Type', 'surface'), ...
        'full-table match must render even when the clipped table is empty');
end


% --------------------------------------------------------------- fixtures

function V = nearest_fixture()
% Viewer with three daily-filtered captures, each within 35 min of a
% renderable DTC profile, and the SnowTemp - Nearest modifier armed.
    cfg = minimal_cfg();
    cfg.wx_dtc_sensor_spacing_cm = 10;
    cfg.wx_dtc_bottom_height_cm = -10;
    cfg.wx_dtc_order = 'top_to_bottom';
    V = build_viewer(cfg);
    % 06:00 matches the daily filter's default target time-of-day, so all
    % three captures survive tod_daily_idx's 1 h window.
    t_cap = datetime(2026, 1, 1, 6, 0, 0) + days(0:2)';
    V.CAND = table(t_cap, "cap" + string((1:3)'), 20 * ones(3, 1), (10:10:30)', ...
        'VariableNames', {'timestamp', 'base_name', 'snr_db', 'corr_41622'});
    t_wx = t_cap + minutes(5);
    V.WX = table(t_wx, [0.25; 0.28; 0.30], ...
        [-8 -6 -3 0; -9 -7 -4 -1; -7 -5 -2 0], ...
        'VariableNames', {'timestamp', 'depth_m', 'dtc_c'});
    V.dp1.Value = min(t_cap) - hours(12);
    V.dp2.Value = max(t_cap) + hours(12);
    V.cb_snowtemp.Value = true;
    V.cb_tod.Value = true;
    V.cb_snowtemp_nearest.Value = true;
end


function axD = thermograph_axes(tc, V)
% The lower thermograph axes: the one carrying the height-above-ground label.
    axs = findobj(V.panel, 'Type', 'axes');
    axD = gobjects(0);
    for k = 1:numel(axs)
        if contains(axs(k).YLabel.String, 'Height Above Ground')
            axD = axs(k);
            break;
        end
    end
    verifyNotEmpty(tc, axD, 'thermograph axes must exist');
end


function cfg = minimal_cfg()
    cfg = struct('freq_hz', 370e6, 'fs', 20e6, 'num_segs', 2, 'Ti', 0.9, ...
        'peak_lag', -0.575, 'T_load_K', 290, 'out_dir', tempdir, 'data_dir', tempdir);
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

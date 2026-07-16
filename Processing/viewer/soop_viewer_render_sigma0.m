% soop_viewer_render_sigma0  Sigma0 CSV plot family (compute_sigma0): apparent
% sigma_0 time series, coherent reflectivity Gamma, and the per-capture geometry
% (r_2c / r_1mc / A_eff). Products are linear + dimensionless; sigma_0 / Gamma
% display in dB (10*log10). Mirrors the soop_viewer_render_l1 render contract
% (V aliases, V.U helpers, S.last_n, tiledlayout in S.panel; the caller wraps
% this in a try/catch and calls apply_overrides afterwards).
function soop_viewer_render_sigma0(V, kind)
    S = V;
    show_msg = @(varargin) V.U.show_msg(V, varargin{:});
    range_bounds = @(varargin) V.U.range_bounds(V, varargin{:});
    tcol = V.U.tcol;
    plot_series = @(varargin) V.U.plot_series(V, varargin{:});
    is_compare_mode = @(varargin) V.U.is_compare_mode(V, varargin{:});
    is_chaincal_mode = @(varargin) V.U.is_chaincal_mode(V, varargin{:});

    % Footprint map: a pure forward model (elevation table + site + tower/snow
    % height) — independent of any sigma0 product AND of the Dataset selection,
    % so it is handled before the compare/product guards below.
    if strcmp(kind, 'Radar Cal: footprint map')
        render_footprint_map(V);
        return;
    end

    % The sigma0 products are single-dataset (base OR notch): the synthetic
    % 'base vs notch' and 'notch + phase offset cal (synth)' Dataset entries
    % have no sigma0 CSV of their own, so there is nothing to overlay or derive.
    % Bail with an explicit message rather than silently rendering base only.
    if is_compare_mode() || is_chaincal_mode()
        show_msg(['The synthetic "base vs notch" and "notch + phase offset ' ...
                  'cal" Dataset selections are not supported for Radar Cal ' ...
                  'plots.' newline 'Select the base or notch dataset instead.']);
        return;
    end

    % Hybrid geometry view: the r_2c / r_1mc / A_eff geometry is a pure forward
    % model (elevation table + tower height + snow depth — nothing from the
    % sigma0 run), so when no sigma0 CSV exists yet the geometry view computes
    % it live via the same sigma0_math handles compute_sigma0 uses. Once the
    % product exists, the CSV's own provenance columns are shown instead.
    is_geom_kind = strcmp(kind, 'Radar Cal: geometry (r2c / r1mc / A_eff)');
    fwd_model = isempty(S.SIG0) && is_geom_kind;
    if isempty(S.SIG0) && ~fwd_model
        show_msg('No sigma0 CSV in this dataset — run compute_sigma0.');
        return;
    end
    [t0, t1] = range_bounds();
    if fwd_model
        T = forward_geometry(V, t0, t1);
        if isempty(T)
            show_msg(['No sigma0 CSV yet, and the forward model found no ' ...
                      'elevation-table rows in range (check cfg.elev_table).']);
            return;
        end
    else
        T = S.SIG0(tcol(S.SIG0) >= t0 & tcol(S.SIG0) < t1, :);
        if isempty(T)
            show_msg('No sigma0 rows in the selected date range.');
            return;
        end
    end
    S.last_n = height(T);
    t   = tcol(T);
    vn  = T.Properties.VariableNames;
    agg = S.dd_agg.Value;

    switch kind
        case 'Radar Cal: sigma0 time series'
            % Fixed-h and snow-corrected-h apparent sigma_0, both in dB. The
            % 'db' aggregation expects dB input and averages in linear power
            % (M.aggregate re-linearizes as 10.^(x/10)); pos_db drops NaN /
            % non-positive product rows up front so 10*log10 never hits
            % zero/negative (which would yield -Inf / complex).
            tl = tiledlayout(S.panel, 1, 1);
            ax = nexttile(tl);
            hold(ax, 'on');
            lh = gobjects(0);  leg = {};
            [tf, yf] = pos_db(t, T.sigma0_app_lin_fixed_h);
            if ~isempty(tf)
                lh(end+1) = plot_series(ax, tf, yf, agg, 'db');
                leg{end+1} = 'fixed h';
            end
            [ts, ys] = pos_db(t, T.sigma0_app_lin_snow_h);
            if ~isempty(ts)
                lh(end+1) = plot_series(ax, ts, ys, agg, 'db');
                leg{end+1} = 'snow-corrected h';
            end
            hold(ax, 'off');
            ylabel(ax, '\sigma_0 apparent (dB)');
            title(ax, 'Apparent \sigma_0 (direct-referenced)');
            if ~isempty(lh), legend(ax, lh, leg, 'Location', 'best'); end
            grid(ax, 'on');

        case 'Radar Cal: coherent reflectivity'
            % Coherent power reflectivity Gamma (|gamma|^2) in dB; a passive
            % surface cannot exceed Gamma = 1 (0 dB), marked with a dashed line.
            [tg, yg] = pos_db(t, T.gamma_lin);
            if isempty(tg)
                show_msg('No finite positive Gamma values in the selected date range.');
                return;
            end
            tl = tiledlayout(S.panel, 1, 1);
            ax = nexttile(tl);
            plot_series(ax, tg, yg, agg, 'db');
            yline(ax, 0, '--', '\Gamma = 1');
            ylabel(ax, '\Gamma (dB)');
            title(ax, 'Coherent power reflectivity \Gamma (direct-referenced)');
            grid(ax, 'on');

        case 'Radar Cal: geometry (r2c / r1mc / A_eff)'
            % Raw per-capture geometry (no aggregation): direct range r_2c and
            % reflected leg r_1mc on a shared log-scale left axis (m), Fresnel
            % footprint A_eff on the linear right axis (m^2). Each series is
            % checkbox-gated, and the h dropdown picks the reflector-height
            % variant for r_1mc / A_eff: snow-corrected (default), fixed tower
            % height, or both overlaid (fixed solid, snow dashed; a single
            % variant draws solid). The legend lists only what is drawn.
            r2_on   = S.cb_geom_r2.Value;
            r1_on   = S.cb_geom_r1.Value;
            aeff_on = S.cb_geom_aeff.Value;
            h_mode  = S.dd_geom_h.Value;             % 'snow h' | 'fixed h' | 'both'
            want_fixed = any(strcmp(h_mode, {'fixed h', 'both'}));
            want_snow  = any(strcmp(h_mode, {'snow h', 'both'}));
            fixed_style = '-';
            snow_style  = '-';
            if strcmp(h_mode, 'both'), snow_style = '--'; end
            if ~(r2_on || r1_on || aeff_on)
                show_msg('No geometry series selected — tick r_2c, r_1mc, or A_eff.');
                return;
            end
            tl = tiledlayout(S.panel, 1, 1);
            ax = nexttile(tl);
            hold(ax, 'on');
            lh = gobjects(0);  leg = {};

            % Left axis: ranges (log scale, m). r_d ~ 3.7e7, r_1 ~ 6-12 m.
            yyaxis(ax, 'left');
            drew_left = false;
            if r2_on
                h = geo_line(ax, t, T, vn, 'r_d_m', '-');
                if ~isempty(h)
                    lh(end+1) = h;  leg{end+1} = 'r_{2c} = r_d (direct)';
                    drew_left = true;
                end
            end
            if r1_on
                if want_fixed
                    h = geo_line(ax, t, T, vn, 'r1_fixed_m', fixed_style);
                    if ~isempty(h)
                        lh(end+1) = h;  leg{end+1} = 'r_{1mc} (fixed h)';
                        drew_left = true;
                    end
                end
                if want_snow
                    h = geo_line(ax, t, T, vn, 'r1_snow_m', snow_style);
                    if ~isempty(h)
                        lh(end+1) = h;  leg{end+1} = 'r_{1mc} (snow h)';
                        drew_left = true;
                    end
                end
            end
            if drew_left
                ylabel(ax, 'Range (m)');
                set(ax, 'YScale', 'log');
            else
                ax.YAxis(1).Visible = 'off';
            end

            % Right axis: Fresnel footprint area (linear, m^2).
            yyaxis(ax, 'right');
            drew_right = false;
            if aeff_on
                if want_fixed
                    h = geo_line(ax, t, T, vn, 'Aeff_fixed_m2', fixed_style);
                    if ~isempty(h)
                        lh(end+1) = h;  leg{end+1} = 'A_{eff} (fixed h)';
                        drew_right = true;
                    end
                end
                if want_snow
                    h = geo_line(ax, t, T, vn, 'Aeff_snow_m2', snow_style);
                    if ~isempty(h)
                        lh(end+1) = h;  leg{end+1} = 'A_{eff} (snow h)';
                        drew_right = true;
                    end
                end
            end
            if drew_right
                ylabel(ax, 'Footprint A_{eff} (m^2)');
            else
                % Nothing on the right ruler — hide its ticks/label so it reads clean.
                ax.YAxis(2).Visible = 'off';
            end

            yyaxis(ax, 'left');   % restore left as active for title/labels
            hold(ax, 'off');
            if isempty(lh)
                if strcmp(h_mode, 'snow h')
                    show_msg(['No finite geometry data for the selected series — ' ...
                              'the snow-corrected h needs SNOdar weather data ' ...
                              '(cfg.wx_dat). Try the fixed h selection.']);
                else
                    show_msg('No finite geometry data for the selected series in range.');
                end
                return;
            end
            xlabel(ax, 'Date');
            if fwd_model
                title(ax, ['Radar Cal geometry — FORWARD MODEL (no sigma0 ' ...
                           'product yet): ranges (log, m) + Fresnel footprint (m^2)']);
            else
                title(ax, 'Radar Cal geometry: ranges (log, m) + Fresnel footprint (m^2)');
            end
            legend(ax, lh, leg, 'Location', 'best');
            grid(ax, 'on');
    end
end


function [tt, ydb] = pos_db(t, ylin)
% Keep only finite, strictly-positive linear products, then 10*log10 -> dB.
% (10*log10 of NaN/0/negative is NaN/-Inf/complex; dropping those rows keeps
% the 'db' aggregation, which re-linearizes as 10.^(x/10), well-defined.)
    ok  = isfinite(ylin) & ylin > 0;
    tt  = t(ok);
    ydb = 10 * log10(ylin(ok));
end


function h = geo_line(ax, t, T, vn, col, style)
% Plot one geometry column as a line if it is present and has finite data;
% return the line handle (or an empty gobjects, so the caller can skip its
% legend entry). Keeps the geometry legend built only from drawn series.
    h = gobjects(0);
    if ismember(col, vn) && any(isfinite(T.(col)))
        h = plot(ax, t, T.(col), style);
    end
end


function T = forward_geometry(V, t0, t1)
% Forward-model geometry for the hybrid Radar Cal geometry view: r_2c from
% cfg.elev_table's range_km, r_1mc and the Fresnel A_eff from tower height
% (+ SNOdar snow depth when weather is loaded), on the elevation-table time
% grid. Uses the SAME sigma0_math handles as compute_sigma0, so the forward
% model and the product's provenance columns share one implementation. Returns
% an empty table when the elevation table is absent/unusable in [t0, t1).
    T   = table();
    cfg = V.cfg;
    if ~isfield(cfg, 'elev_table') || ~isfile(cfg.elev_table)
        return;
    end
    E = V.M.read_product(cfg.elev_table);
    if isempty(E) || ~all(ismember({'elevation_deg', 'range_km'}, ...
                                   E.Properties.VariableNames))
        return;
    end
    % Elevation tables are UTC; the viewer's axis is the capture timebase
    % (inverse of the stages' to_utc conversion; identity for UTC seasons).
    tt = E.timestamp;
    if isfield(cfg, 'capture_tz') && ~isempty(cfg.capture_tz) ...
            && ~strcmp(cfg.capture_tz, 'UTC')
        tt.TimeZone = 'UTC';
        tt.TimeZone = cfg.capture_tz;
        tt.TimeZone = '';
    end
    keep = tt >= t0 & tt < t1 ...
           & isfinite(E.elevation_deg) & E.elevation_deg > 0 ...
           & isfinite(E.range_km) & E.range_km > 0;
    if ~any(keep), return; end
    tt    = tt(keep);
    theta = E.elevation_deg(keep);
    r_d   = E.range_km(keep) * 1e3;

    % The season table is 1-min cadence (~3e5 rows); decimate for drawing.
    n_max = 20000;
    if numel(tt) > n_max
        step  = ceil(numel(tt) / n_max);
        tt    = tt(1:step:end);
        theta = theta(1:step:end);
        r_d   = r_d(1:step:end);
    end

    H        = sigma0_math();
    lambda_m = 299792458 / cfg.freq_hz;
    r1_f     = H.r1(cfg.tower_h_m, theta);
    Ae_f     = H.fresnel(lambda_m, cfg.tower_h_m, theta);

    % Snow-corrected variant from the already-loaded weather table; NaN when
    % weather is absent or the snow surface reaches the antenna.
    r1_s = nan(size(theta));
    Ae_s = nan(size(theta));
    WX = V.WX;
    if ~isempty(WX) && ismember('depth_m', WX.Properties.VariableNames)
        [tw, iu] = unique(WX.timestamp);
        depth = interp1(tw, WX.depth_m(iu), tt, 'linear', NaN);
        h_s   = cfg.tower_h_m - depth;
        ok    = isfinite(h_s) & h_s > 0;
        if any(ok)
            r1_s(ok) = H.r1(h_s(ok), theta(ok));
            Ae_s(ok) = H.fresnel(lambda_m, h_s(ok), theta(ok));
        end
    end

    T = table(tt, theta, r_d, r1_f, r1_s, Ae_f, Ae_s, 'VariableNames', ...
        {'timestamp', 'theta_deg', 'r_d_m', 'r1_fixed_m', 'r1_snow_m', ...
         'Aeff_fixed_m2', 'Aeff_snow_m2'});
end


function render_footprint_map(V)
% Footprint map: first-Fresnel-zone ellipse drawn over a geo-registered
% satellite basemap, with the tower location marked. Pure forward model —
% needs only a muos_elevation_<norad>.csv (satellite picked in the side-panel
% dropdown), cfg.site_lat/lon, cfg.tower_h_m, and (for the snow-h variant) the
% loaded SNOdar depth. Geometry over the selected date range is summarized at
% its MEAN elevation/azimuth (GEO drift is a few degrees at most; the title
% reports the elevation spread). Flat, horizontal reflector assumed (no DEM);
% local ENU meters are mapped to lat/lon with an equirectangular approximation
% about the site (sub-mm error at footprint scale). The Esri 'satellite'
% basemap needs internet; without it (or geoaxes), the plot falls back to
% plain local East/North axes in meters.
    S = V;  cfg = V.cfg;
    show_msg     = @(varargin) V.U.show_msg(V, varargin{:});
    range_bounds = @(varargin) V.U.range_bounds(V, varargin{:});

    if isempty(S.dd_map_sat.ItemsData) || isempty(S.dd_map_sat.Value)
        show_msg(['No muos_elevation_*.csv found in cfg.elev_dir — generate ' ...
                  'elevation tables with make_muos_elevation.py.']);
        return;
    end
    norad = S.dd_map_sat.Value;
    etab  = fullfile(cfg.elev_dir, sprintf('muos_elevation_%d.csv', norad));
    E = V.M.read_product(etab);
    if isempty(E) || ~all(ismember({'elevation_deg', 'azimuth_deg'}, ...
                                   E.Properties.VariableNames))
        show_msg(sprintf('Could not read %s (or it lacks elevation/azimuth).', etab));
        return;
    end

    % Elevation tables are UTC; the date pickers are in the capture timebase.
    tt = E.timestamp;
    if isfield(cfg, 'capture_tz') && ~isempty(cfg.capture_tz) ...
            && ~strcmp(cfg.capture_tz, 'UTC')
        tt.TimeZone = 'UTC';
        tt.TimeZone = cfg.capture_tz;
        tt.TimeZone = '';
    end
    % Epoch selection: the sidebar date picker pins the drawn footprint to one
    % DAY (that day's mean el/az and mean snow depth — the snow-corrected h
    % moves with snow depth through the season); when cleared (NaT) the mean
    % over the top date-range pickers is used instead.
    [t0, t1] = range_bounds();
    map_day = S.dp_map.Value;
    day_pinned = ~isnat(map_day);
    if day_pinned
        t0 = dateshift(datetime(map_day), 'start', 'day');
        t1 = t0 + days(1);
    end
    keep = tt >= t0 & tt < t1 & isfinite(E.elevation_deg) & isfinite(E.azimuth_deg);
    if ~any(keep)
        if day_pinned
            show_msg(sprintf(['No elevation-table rows on %s — clear the ' ...
                     'footprint date or pick a day inside the table span.'], ...
                     string(t0, 'yyyy-MM-dd')));
        else
            show_msg('No elevation-table rows in the selected date range.');
        end
        return;
    end
    el = E.elevation_deg(keep);
    az = E.azimuth_deg(keep);
    el_mean = mean(el);
    % Circular mean for azimuth (robust near the 0/360 wrap).
    az_mean = mod(atan2d(mean(sind(az)), mean(cosd(az))), 360);
    if el_mean <= 0
        show_msg('Satellite below the horizon over the selected range.');
        return;
    end
    S.last_n = sum(keep);

    % Reflector-height variants (same selector semantics as the geometry view).
    h_mode = S.dd_map_h.Value;
    hs = [];  hl = {};
    if any(strcmp(h_mode, {'fixed h', 'both'}))
        hs(end+1) = cfg.tower_h_m;  hl{end+1} = 'fixed h';
    end
    if any(strcmp(h_mode, {'snow h', 'both'}))
        h_snow = NaN;
        WX = V.WX;
        if ~isempty(WX) && ismember('depth_m', WX.Properties.VariableNames)
            wsel = WX.timestamp >= t0 & WX.timestamp < t1 & isfinite(WX.depth_m);
            if any(wsel)
                h_snow = cfg.tower_h_m - mean(WX.depth_m(wsel));
            end
        end
        if isfinite(h_snow) && h_snow > 0
            hs(end+1) = h_snow;  hl{end+1} = 'snow h';
        end
    end
    if isempty(hs)
        show_msg(['No usable reflector height — the snow-corrected h needs ' ...
                  'SNOdar weather data in range. Try the fixed h selection.']);
        return;
    end

    % Fresnel ellipse per h variant, in local ENU meters about the antenna.
    H = sigma0_math();
    lambda_m = 299792458 / cfg.freq_hz;
    thd = (0:2:360)';                                % ellipse parameter (deg)
    m_per_deg_lat = 111320;
    m_per_deg_lon = 111320 * cosd(cfg.site_lat);
    ell = struct('lat', {}, 'lon', {}, 'E', {}, 'N', {}, 'label', {});
    for hi = 1:numel(hs)
        [Aeff, a, b, R] = H.fresnel(lambda_m, hs(hi), el_mean);
        xp = a * cosd(thd);                          % along-azimuth
        yp = b * sind(thd);                          % cross-azimuth
        Ee = (R + xp) * sind(az_mean) + yp * cosd(az_mean);
        Nn = (R + xp) * cosd(az_mean) - yp * sind(az_mean);
        ell(hi).E = Ee;  ell(hi).N = Nn;
        ell(hi).lat = cfg.site_lat + Nn / m_per_deg_lat;
        ell(hi).lon = cfg.site_lon + Ee / m_per_deg_lon;
        ell(hi).label = sprintf('Fresnel zone, %s (h=%.2f m, A=%.0f m^2)', ...
                                hl{hi}, hs(hi), Aeff);
    end
    % View extent: DAY-INDEPENDENT so the window stays put as the footprint
    % date / h selection change (tower-centered; the user can still zoom).
    % Bound by the season worst case — fixed tower height (no-snow maximum h)
    % at the elevation table's minimum elevation, where the ellipse and its
    % center offset are largest — padded well out for context.
    el_all = E.elevation_deg(isfinite(E.elevation_deg) & E.elevation_deg > 0);
    [~, a_w, ~, R_w] = H.fresnel(lambda_m, cfg.tower_h_m, min(el_all));
    extent = 1.5 * (R_w + a_w);                      % m about the tower

    sat_label = sprintf('NORAD %d', norad);
    li = find(cellfun(@(v) isequal(v, norad), S.dd_map_sat.ItemsData), 1);
    if ~isempty(li), sat_label = S.dd_map_sat.Items{li}; end
    ttl = sprintf('Fresnel footprint — %s', sat_label);
    if day_pinned
        ttl = sprintf('%s — %s', ttl, string(t0, 'yyyy-MM-dd'));
    else
        ttl = sprintf('%s — range mean', ttl);
    end
    styles = {'-', '--'};
    colors = {[0.85 0.33 0.10], [0.30 0.75 0.93]};   % orange / cyan

    % Geo-registered satellite basemap; plain ENU axes as the fallback.
    gax = [];   %#ok<NASGU> % defensive: geoaxes() may throw before assigning
    try
        gax = geoaxes(S.panel);
        gax.Units = 'normalized';
        gax.Position = [0.04 0.04 0.92 0.90];
        geobasemap(gax, 'satellite');
    catch
        gax = [];
    end
    if ~isempty(gax)
        hold(gax, 'on');
        lh = gobjects(0);  leg = {};
        for hi = 1:numel(ell)
            lh(end+1) = geoplot(gax, ell(hi).lat, ell(hi).lon, styles{hi}, ...
                'Color', colors{hi}, 'LineWidth', 2);            %#ok<AGROW>
            leg{end+1} = ell(hi).label;                          %#ok<AGROW>
        end
        lh(end+1) = geoplot(gax, cfg.site_lat, cfg.site_lon, '^', ...
            'MarkerSize', 9, 'MarkerFaceColor', [0.9 0.1 0.1], ...
            'MarkerEdgeColor', 'w', 'LineWidth', 0.75);
        leg{end+1} = 'tower';
        geolimits(gax, cfg.site_lat + extent / m_per_deg_lat * [-1 1], ...
                       cfg.site_lon + extent / m_per_deg_lon * [-1 1]);
        title(gax, ttl);
        legend(gax, lh, leg, 'Location', 'northwest', 'TextColor', 'w', ...
               'Color', [0 0 0 0.35]);
        hold(gax, 'off');
    else
        % Offline / no geoaxes: local East/North meters about the tower.
        ax = axes(S.panel);
        ax.Units = 'normalized';
        ax.Position = [0.08 0.08 0.88 0.84];
        hold(ax, 'on');
        lh = gobjects(0);  leg = {};
        for hi = 1:numel(ell)
            lh(end+1) = plot(ax, ell(hi).E, ell(hi).N, styles{hi}, ...
                'Color', colors{hi}, 'LineWidth', 2);            %#ok<AGROW>
            leg{end+1} = ell(hi).label;                          %#ok<AGROW>
        end
        lh(end+1) = plot(ax, 0, 0, '^', 'MarkerSize', 9, ...
            'MarkerFaceColor', [0.9 0.1 0.1], 'MarkerEdgeColor', 'k');
        leg{end+1} = 'tower';
        axis(ax, 'equal');
        xlim(ax, extent * [-1 1]);  ylim(ax, extent * [-1 1]);
        xlabel(ax, 'East (m)');  ylabel(ax, 'North (m)');
        grid(ax, 'on');
        title(ax, [ttl '  (no basemap — geoaxes unavailable)']);
        legend(ax, lh, leg, 'Location', 'northwest');
        hold(ax, 'off');
    end
end

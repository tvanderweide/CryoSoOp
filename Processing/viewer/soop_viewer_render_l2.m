% soop_viewer_render_l2  L2 CSV plot family: satellite candidates (with optional
% weather overlay), candidate diurnal phase, and satellite elevation / azimuth.
function soop_viewer_render_l2(V, kind)
    S = V;
    cfg = V.cfg;
    M = V.M;
    show_msg = @(varargin) V.U.show_msg(V, varargin{:});
    range_bounds = @(varargin) V.U.range_bounds(V, varargin{:});
    tcol = V.U.tcol;
    domain_col1 = @(varargin) V.U.domain_col1(V, varargin{:});
    is_chaincal_mode = @(varargin) V.U.is_chaincal_mode(V, varargin{:});
    chaincal_delta = @(varargin) V.D.chaincal_delta(V, varargin{:});
    wrap_deg = V.U.wrap_deg;
    plot_series = @(varargin) V.U.plot_series(V, varargin{:});

    % --- Candidate diurnal (hour-of-day) phase, with optional detrend ---
    if startsWith(kind, 'L2: Diurnal')
        if isempty(S.CAND)
            show_msg('Needs sat_candidates_corrected.csv — run compare_sat_candidates');
            return;
        end
        [t0, t1] = range_bounds();
        T = S.CAND(tcol(S.CAND) >= t0 & tcol(S.CAND) < t1, :);
        if isempty(T)
            show_msg('No candidate rows in the selected date range.');
            return;
        end
        S.last_n = height(T);
        t  = tcol(T);
        tl = tiledlayout(S.panel, 1, 1);
        ax = nexttile(tl);
        % Candidate column (raw baseline or corr_<norad>) in the selected domain.
        m = regexp(kind, '\((\d+)\)', 'tokens', 'once');
        if isempty(m)
            c_sinc = 'phase_raw_deg';  c_fd = 'phase_raw_fd_deg';
            c_muos = 'phase_raw_fd_muos_deg';  label = 'raw (no correction)';
        else
            c_sinc = ['corr_' m{1}];  c_fd = ['corr_' m{1} '_fd'];
            c_muos = ['corr_' m{1} '_fd_muos'];
            label = regexp(kind, 'MUOS-\d+', 'match', 'once');
        end
        [col, dlab] = domain_col1(T, c_sinc, c_fd, c_muos);
        if ~ismember(col, T.Properties.VariableNames)
            show_msg(sprintf(['%s not in sat_candidates_corrected.csv — ' ...
                're-run compare_sat_candidates with that ephemeris present.'], col));
            return;
        end
        y = T.(col);
        % 'notch + phase offset cal (synth)' Dataset: chain-phase correction on
        % the corrected candidates (raw stays raw), matching the L2: Candidates
        % views. A constant offset is removed by detrend anyway, but it matters
        % when Detrend is off.
        if is_chaincal_mode() && ~isempty(m)
            [dlt, okc, why] = chaincal_delta(T);
            if ~okc, show_msg(why); return; end
            y = wrap_deg(y + dlt);
            label = [char(label) ' + phase offset cal'];
        end
        label = [char(label) ' [' char(dlab) ']'];
        % Optional detrend: subtract each day's circular mean before hour binning
        % so the seasonal wander S(day) (common to all hours within a day) is
        % stripped and only the diurnal RESIDUAL remains (mirrors L1: Diurnal).
        hr = hour(t);
        detrend_on = S.sw_detrend.Value;
        if detrend_on
            day_grp = findgroups(dateshift(t, 'start', 'day'));
            mu_day  = splitapply(@(x) M.first_out(M.circ_stats, x), y, day_grp);
            % Wrapped residual (deg): complex round-trip keeps it in ±180.
            y = rad2deg(angle(exp(1i * deg2rad(y - mu_day(day_grp)))));
        end
        [mu, sd] = deal(nan(24, 1));
        for h = 0:23
            x = y(hr == h);
            if ~isempty(x), [mu(h+1), sd(h+1)] = M.circ_stats(x); end
        end
        errorbar(ax, 0:23, mu, sd, 'o-');
        xlabel(ax, 'Hour of day (capture timestamp — Pi clock timezone)');
        xlim(ax, [-0.5 23.5]);
        if detrend_on
            ylabel(ax, 'Residual phase \pm circ. std (deg), daily mean removed');
            title(ax, ['Diurnal phase RESIDUAL — ' label ' (daily circ. mean removed)']);
        else
            ylabel(ax, 'Circular mean phase \pm circ. std (deg)');
            ylim(ax, [-180 180]);  yticks(ax, -180:90:180);
            title(ax, ['Diurnal phase pattern — ' label]);
        end
        grid(ax, 'on');
        return;
    end

    % --- Satellite candidates (phase) with optional weather overlay ---
    % Formerly split into "L2: Candidates" (phase only) and "L2: + SNOdar"
    % (phase + depth + temperature). Now unified: phase always draws; snow
    % depth and the two station temperatures each toggle via a checkbox.
    if startsWith(kind, 'L2: Candidates')
        if isempty(S.CAND)
            show_msg('Needs sat_candidates_corrected.csv — run compare_sat_candidates');
            return;
        end
        [t0, t1] = range_bounds();
        TC = S.CAND(tcol(S.CAND) >= t0 & tcol(S.CAND) < t1, :);
        if isempty(TC)
            show_msg('No candidate rows in the selected date range.');
            return;
        end
        m = regexp(kind, '\((\d+)\)', 'tokens', 'once');
        if isempty(m)
            c_sinc = 'phase_raw_deg';  c_fd = 'phase_raw_fd_deg';
            c_muos = 'phase_raw_fd_muos_deg';  phase_label = 'raw (no correction)';
        else
            c_sinc = ['corr_' m{1}];  c_fd = ['corr_' m{1} '_fd'];
            c_muos = ['corr_' m{1} '_fd_muos'];
            phase_label = regexp(kind, 'MUOS-\d+', 'match', 'once');
        end
        [phase_col, dlab] = domain_col1(TC, c_sinc, c_fd, c_muos);
        phase_label = [char(phase_label) ' [' char(dlab) ']'];
        if ~ismember(phase_col, TC.Properties.VariableNames)
            show_msg(sprintf('%s not in sat_candidates_corrected.csv.', phase_col));
            return;
        end
        y_ph = TC.(phase_col);
        % 'notch + phase offset cal (synth)' Dataset: chain-phase correction on
        % the corrected candidates; the raw baseline stays raw.
        if is_chaincal_mode() && ~isempty(m)
            [dlt, okc, why] = chaincal_delta(TC);
            if ~okc, show_msg(why); return; end
            y_ph = wrap_deg(y_ph + dlt);
            phase_label = [phase_label ' + phase offset cal'];
        end
        agg = S.dd_agg.Value;
        % Weather rows in range (depth + temperatures share this table). Each
        % overlay is gated by its checkbox AND the presence of finite data.
        if ~isempty(S.WX)
            TW = S.WX(tcol(S.WX) >= t0 & tcol(S.WX) < t1, :);
        else
            TW = table();
        end
        has_col = @(c) ~isempty(TW) && ismember(c, TW.Properties.VariableNames);
        show_dep = S.cb_depth.Value && has_col('depth_m')  && any(isfinite(TW.depth_m));
        show_air = S.cb_airtc.Value && has_col('airtc_c') && any(isfinite(TW.airtc_c));
        show_tmp = S.cb_tempc.Value && has_col('temp_c')  && any(isfinite(TW.temp_c));
        want_temp = (show_air || show_tmp) && t1 > t0;
        % Depth and temperature always plot at raw 15-min resolution; the agg
        % dropdown only applies to the phase line.
        agg_wx = 'Raw captures';

        % Fixed-position axes (not tiledlayout) so the optional temperature
        % overlay can be placed deterministically — no mid-render drawnow,
        % no reading of dynamic axes limits/position. Reserve a right margin
        % for the temperature ruler only when a temperature line is shown.
        if want_temp, axW = 0.74; else, axW = 0.86; end
        ax_pos = [0.09 0.13 axW 0.80];
        ax  = axes(S.panel, 'Position', ax_pos);
        hold(ax, 'on');   % depth + legend proxies share ax's right side
        leg = {};  lh = gobjects(0);   % legend labels + handles, built as drawn
        % Left axis: phase (wrapped circular, as collected)
        yyaxis(ax, 'left');
        lh(end+1) = plot_series(ax, tcol(TC), y_ph, agg, 'phase');
        ylabel(ax, 'Phase (deg)');
        ylim(ax, [-180 180]);  yticks(ax, -180:90:180);
        leg{end+1} = 'Phase';
        % Right axis: SNOdar depth (red), only when toggled on
        if show_dep
            yyaxis(ax, 'right');
            [ta, ya] = M.aggregate(tcol(TW), TW.depth_m, agg_wx, 'lin');
            lh(end+1) = plot(ax, ta, ya, 'r-');
            leg{end+1} = 'SNOdar depth';
            ylabel(ax, 'Snow depth (m)');
            ymax = max(ya, [], 'omitnan');
            if isfinite(ymax), ylim(ax, [0, ymax * 1.1 + 0.1]); end
            ax.YAxis(2).Color = [0.8 0 0];
            yyaxis(ax, 'left');   % restore left as active for title/labels
        end
        if t1 > t0, xlim(ax, [t0 t1]); end

        % Third y-axis: weather-station temperature (toggleable lines). The
        % overlay axes is wider than ax to the right, with its XLim stretched
        % by the same ratio so the [t0,t1] data stays time-aligned with ax
        % while the temperature ruler sits in the reserved right margin.
        if want_temp
            tmp_w = axW + 0.06;
            axT = axes(S.panel, 'Position', [ax_pos(1) ax_pos(2) tmp_w ax_pos(4)], ...
                       'Color', 'none', 'YAxisLocation', 'right', 'XTick', [], ...
                       'Box', 'off', 'HitTest', 'off', 'PickableParts', 'none');
            hold(axT, 'on');
            c_air = [0.17 0.63 0.17];  c_tmp = [0.49 0.18 0.56];
            % Real lines live on axT; the legend (parented to ax) uses
            % invisible proxy lines on ax so it never references axT.
            if show_air
                [tt, yy] = M.aggregate(tcol(TW), TW.airtc_c, agg_wx, 'lin');
                plot(axT, tt, yy, '-', 'Color', c_air, 'LineWidth', 1);
                lh(end+1) = plot(ax, [t0 t0], [NaN NaN], '-', 'Color', c_air, 'LineWidth', 1);
                leg{end+1} = 'AirTC\_Avg';
            end
            if show_tmp
                [tt, yy] = M.aggregate(tcol(TW), TW.temp_c, agg_wx, 'lin');
                plot(axT, tt, yy, '-', 'Color', c_tmp, 'LineWidth', 1);
                lh(end+1) = plot(ax, [t0 t0], [NaN NaN], '-', 'Color', c_tmp, 'LineWidth', 1);
                leg{end+1} = 'Temp\_C\_Avg';
            end
            xlim(axT, [t0, t0 + (t1 - t0) * (tmp_w / axW)]);
            yline(axT, 0, ':', 'Color', [0.3 0.3 0.3]);   % 0 degC melt-freeze threshold
            ylabel(axT, 'Temperature (\circC)');
            axT.YColor = [0.2 0.2 0.2];
        end

        title(ax, phase_label);
        legend(lh, leg, 'Location', 'best');
        grid(ax, 'on');
        xlabel(ax, 'Date');
        S.last_n = height(TC);
        return;
    end

    % --- Remaining L2 product-CSV views (satellite elevation / azimuth) ---
    if isempty(S.L2)
        show_msg(sprintf('Needs BrundageSoOp_L2.csv (run compute_L2) in %s', cfg.out_dir));
        return;
    end
    [t0, t1] = range_bounds();
    T = S.L2(tcol(S.L2) >= t0 & tcol(S.L2) < t1, :);
    if isempty(T)
        show_msg('No L2 rows in the selected date range.');
        return;
    end
    S.last_n = height(T);
    t   = tcol(T);
    agg = S.dd_agg.Value;
    tl  = tiledlayout(S.panel, 1, 1);
    ax  = nexttile(tl);

    switch kind
        case 'L2: Satellite elevation'
            plot_series(ax, t, T.theta_deg, agg, 'lin');
            ylabel(ax, 'Elevation (deg)');
            title(ax, 'Satellite elevation at capture times');
        case 'L2: Satellite Azimuth'
            if ~ismember('az_deg', T.Properties.VariableNames)
                show_msg(['Azimuth needs the az_deg column — re-run ' ...
                          'compute_L2 (adds azimuth from the ephemeris table).']);
                return;
            end
            plot_series(ax, t, T.az_deg, agg, 'lin');
            ylabel(ax, 'Azimuth (deg)');
            title(ax, 'Satellite azimuth at capture times');
    end
    grid(ax, 'on');
end

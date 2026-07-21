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
    % Candidate views always draw phase; snow depth and station temperatures
    % are optional checkbox-controlled overlays.
    if V.U.is_cand_kind(kind)
        if isempty(S.CAND)
            show_msg('Needs sat_candidates_corrected.csv — run compare_sat_candidates');
            return;
        end
        [t0, t1] = range_bounds();
        % Display SNR cutoff (side-panel spinner), applied BEFORE the daily
        % time-of-day pick with the producer's exact predicate — so raising
        % the cutoff can swap a day's representative to the nearest PASSING
        % capture (same semantics as re-running compare_sat_candidates at
        % the higher threshold). The title notes the cutoff only when it
        % differs from the validated configured start (state-based, never
        % keyed to how many rows a given range lost). snr_ok is false for
        % products without snr_db (spinner disabled in callbacks).
        snr_cut = S.sp_snrcut.Value;
        [CAND, snr_ok] = V.U.snrcut_apply(S.CAND, snr_cut);
        snr_note = '';
        if snr_ok && snr_cut ~= V.U.snrcut_start(V.cfg)
            snr_note = sprintf([' ' char(8212) ' SNR ' char(8805) ' %g dB'], snr_cut);
        end
        % Distinguish "range/window empty" from "the SNR cutoff removed the
        % pick(s)" in both branches below: the hint appears only when the
        % SAME selection re-run on the unfiltered table yields rows (no
        % numeric count — nonfinite-SNR rows drop too, not just "below").
        cut_hint = sprintf(['Captures exist there, but none with valid SNR ' ...
            char(8805) ' %g dB.'], snr_cut);
        % Optional daily time-of-day filter: one capture per target day (the
        % capture nearest that day's target instant), dropping days whose
        % nearest capture is farther than TOD_WINDOW away. The date range
        % selects target days, so the candidate subset gets ±TOD_WINDOW
        % slack — a capture just outside the picked range may serve a
        % target day inside it. Selection is row-based (same rows for all
        % three candidate figures); a kept row whose phase value is NaN
        % still counts in n but draws no point.
        tod_note = '';
        if S.cb_tod.Value
            TOD_WINDOW = hours(1);
            [tgt, okt] = V.U.parse_tod(S.ef_tod.Value);
            if ~okt
                show_msg('Enter time as H, HHMM, or HH:MM (e.g. 0600).');
                return;
            end
            in_win = @(T) T(tcol(T) >= t0 - TOD_WINDOW & ...
                            tcol(T) <  t1 + TOD_WINDOW, :);
            TCw = in_win(CAND);
            [ix, tday] = V.U.tod_daily_idx(tcol(TCw), tgt, TOD_WINDOW);
            TC = TCw(ix(tday >= t0 & tday < t1), :);
            if isempty(TC)
                msg = ['No daily captures within ' char(177) '1 h of ' ...
                       char(tgt, 'hh:mm') ' in the selected date range.'];
                % Re-run the SAME selection on the unfiltered table: only a
                % nonempty unfiltered pick proves the cutoff (not the
                % window) removed the day(s).
                if snr_ok
                    TCw0 = in_win(S.CAND);
                    [ix0, tday0] = V.U.tod_daily_idx(tcol(TCw0), tgt, TOD_WINDOW);
                    if ~isempty(TCw0(ix0(tday0 >= t0 & tday0 < t1), :))
                        msg = [msg ' ' cut_hint];
                    end
                end
                show_msg(msg);
                return;
            end
            tod_note = [' — daily @ ' char(tgt, 'hh:mm') ' ' char(177) '1 h'];
        else
            TC = CAND(tcol(CAND) >= t0 & tcol(CAND) < t1, :);
            if isempty(TC)
                msg = 'No candidate rows in the selected date range.';
                if snr_ok && ~isempty(S.CAND(tcol(S.CAND) >= t0 & tcol(S.CAND) < t1, :))
                    msg = cut_hint;
                end
                show_msg(msg);
                return;
            end
        end
        m = regexp(kind, '\((\d+)\)', 'tokens', 'once');
        if isempty(m)
            c_sinc = 'phase_raw_deg';  c_fd = 'phase_raw_fd_deg';
            c_muos = 'phase_raw_fd_muos_deg';  phase_label = 'sensor data';
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
        phase_label = [phase_label tod_note snr_note];   % '' unless filters active
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
        show_swe = S.cb_swe.Value   && has_col('swe_mm')  && any(isfinite(TW.swe_mm));
        show_air = S.cb_airtc.Value && has_col('airtc_c') && any(isfinite(TW.airtc_c));
        show_tmp = S.cb_tempc.Value && has_col('temp_c')  && any(isfinite(TW.temp_c));
        % AboveFreezing swaps the ticked temperature LINES for one orange
        % above-freezing band layer — no temperature ruler axes then.
        abvfrz = S.cb_abvfrz.Value;
        want_temp = (show_air || show_tmp) && t1 > t0 && ~abvfrz;
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
        % Style-scale accumulators (Line x / Pt x spinners): every handle
        % drawn as a line joins st_lines, phase-marker handles st_pts, and
        % hour-color dots st_dots; style_apply multiplies their base
        % styles ONCE after all drawing (both axes), before the legend.
        st_lines = gobjects(0);  st_pts = gobjects(0);  st_dots = gobjects(0);
        % Left axis: phase (wrapped circular, as collected)
        yyaxis(ax, 'left');
        h_phase = plot_series(ax, tcol(TC), y_ph, agg, 'phase');
        if S.cb_tod.Value
            % Daily-filter points read better slightly larger (works on
            % both the raw Line and the aggregated ErrorBar handle).
            h_phase.MarkerSize = h_phase.MarkerSize + 2;
        end
        % phaseLine governs the connecting line in EVERY agg mode (both
        % handle types): unchecked = markers only, checked = joined. Note a
        % joined line bridges NaN samples and long capture gaps (aggregate
        % drops nonfinite rows) and draws jump segments at ±180° wraps.
        if S.cb_phline.Value
            h_phase.LineStyle = '-';
        else
            h_phase.LineStyle = 'none';
        end
        lh(end+1) = h_phase;
        st_pts(end+1) = h_phase;    % markers scale by Pt x (incl. phaseLine)
        st_lines(end+1) = h_phase;  % the joined phaseLine scales by Line x
        % Hour-of-day coloring: the render re-checks the FULL predicate (a
        % checked-but-disabled box draws nothing). Colors derive from the
        % SAME aggregate the displayed points use (Raw captures / Per-run
        % mean keep hour identity via the group-midpoint timestamp); the
        % plot_series handle keeps its phaseLine line / error bars but
        % hides its own markers so the colored scatter reads.
        hour_on = S.cb_hourcolor.Value && ~S.cb_tod.Value && ...
                  any(strcmp(agg, {'Raw captures', 'Per-run mean'}));
        if hour_on
            [ta_h, ya_h] = M.aggregate(tcol(TC), y_ph, agg, 'phase');
            h_phase.Marker = 'none';
            hsc = scatter(ax, ta_h, ya_h, 36, V.U.hour_bins(ta_h) + 0.5, 'filled');
            colormap(ax, hsv(24));           % cyclic map for a cyclic hour
            clim(ax, [0 24]);
            hcb = colorbar(ax, 'southoutside');  % below the plot box
            hcb.Ticks = (0:4:20) + 0.5;      % bin centers — there is no hour 24
            hcb.TickLabels = compose('%d', 0:4:20);
            hcb.Label.String = 'nearest hour (capture timebase)';
            lh(end) = hsc;                   % legend binds the colored points
            st_dots(end+1) = hsc;            % dot area scales by (Pt x)^2
        end
        ylabel(ax, 'Phase (deg)');
        ylim(ax, [-180 180]);  yticks(ax, -180:90:180);
        leg{end+1} = 'Phase';
        % AboveFreezing wet-snow bands: one orange layer over the times ANY
        % ticked temperature sensor reads > 0 degC (union; a sample where
        % every ticked sensor is invalid splits the band, as do sample gaps
        % > 1.5x the station cadence — see freeze_spans). xregion spans the
        % full height of the yyaxis pair, ships since R2023a, and Layer
        % 'bottom' keeps the bands behind the data.
        if abvfrz && (show_air || show_tmp)
            cols = [];
            if show_air, cols = [cols, TW.airtc_c]; end
            if show_tmp, cols = [cols, TW.temp_c];  end
            sp = V.U.freeze_spans(tcol(TW), max(cols, [], 2, 'omitnan'));
            if ~isempty(sp)
                hr = xregion(ax, sp(:, 1), sp(:, 2), ...
                             'FaceColor', [1.0 0.55 0.10], 'FaceAlpha', 0.18, ...
                             'Layer', 'bottom');
                lh(end+1) = hr(1);
                leg{end+1} = ['Air Temp > 0' char(176) 'C'];
            end
        end
        % Right axis: SNOdar depth (red) and/or snow-scale SWE (teal). With
        % SWE shown the shared ruler is in MILLIMETERS (the papers' SWE
        % unit; depth joins as mm via R.dep_factor); depth-only keeps the
        % meters ruler. Label/color/scaling/ylim come from the pure
        % wx_right_axis helper (R.pad is unit-aware: 0.1 m vs 100 mm).
        if show_dep || show_swe
            yyaxis(ax, 'right');
            dep_pl = []; swe_pl = [];
            if show_dep, [~, dep_pl] = M.aggregate(tcol(TW), TW.depth_m, agg_wx, 'lin'); end
            if show_swe, [~, swe_pl] = M.aggregate(tcol(TW), TW.swe_mm,  agg_wx, 'lin'); end
            R = V.U.wx_right_axis(show_dep, show_swe, dep_pl, swe_pl);
            if show_dep
                [ta, ya] = M.aggregate(tcol(TW), TW.depth_m, agg_wx, 'lin');
                lh(end+1) = plot(ax, ta, ya * R.dep_factor, 'r-', ...
                                 'LineWidth', 0.5);
                st_lines(end+1) = lh(end);
                leg{end+1} = 'SNOdar depth';
            end
            if show_swe
                [ta, ya] = M.aggregate(tcol(TW), TW.swe_mm, agg_wx, 'lin');
                lh(end+1) = plot(ax, ta, ya, '-', 'Color', [0.00 0.60 0.45], ...
                                 'LineWidth', 0.5);
                st_lines(end+1) = lh(end);
                leg{end+1} = 'SWE';
            end
            ylabel(ax, R.label);
            if isfinite(R.ymax), ylim(ax, [0, R.ymax * 1.1 + R.pad]); end
            ax.YAxis(2).Color = R.color;
            yyaxis(ax, 'left');   % restore left as active for title/labels
        end
        % yyaxis mode always draws a right ruler; hide it when nothing is
        % plotted on it (depth and SWE both off) so the figure has no bare
        % 0-1 axis on the right.
        ax.YAxis(2).Visible = matlab.lang.OnOffSwitchState(show_dep || show_swe);

        % Theoretical phase-from-SWE overlay (LEFT phase axis — active again
        % here; raw 15-min curve in EVERY agg mode, never aggregated; drawn
        % only while the SWE overlay is shown). Fringe rate from the
        % confirmed satellite geometry: theta_inc = 90 - mean elevation of
        % the L2 rows matched to the displayed candidates by base_name
        % (fallback: finite L2 rows in range; none -> unavailable, drawn as
        % nothing). Anchoring/availability live in the pure theory_overlay
        % helper; the legend carries the paper-sign and record-start-anchor
        % labels.
        % Geometry-computed fringe rate and the auto/manual field latch
        % run on EVERY family render (not only when theory is checked) so
        % the mm/2pi field shows the actual auto value instead of a
        % placeholder. The latch never changes auto/manual ownership (owned
        % by on_fringe_edit) and passes the UNROUNDED auto rate to the
        % overlay — display rounding must not change the physics.
        th = NaN;
        if ~isempty(S.L2) && all(ismember({'base_name', 'theta_deg'}, ...
                                          S.L2.Properties.VariableNames))
            [tf_m, loc] = ismember(string(TC.base_name), string(S.L2.base_name));
            thv = S.L2.theta_deg(loc(tf_m));
            thv = thv(isfinite(thv));
            if isempty(thv)
                L2r = S.L2(tcol(S.L2) >= t0 & tcol(S.L2) < t1, :);
                thv = L2r.theta_deg(isfinite(L2r.theta_deg));
            end
            if ~isempty(thv), th = mean(thv, 'omitnan'); end
        end
        A = V.U.fringe_latch(S.ef_fringe.Value, S.ef_fringe.UserData, ...
                             V.U.swe_per_fringe_mm(V.cfg.freq_hz, 90 - th));
        S.ef_fringe.Value = A.text;
        S.ef_fringe.UserData = A.ud;
        fringe = A.mm;
        if S.cb_theory.Value && show_swe
            if strcmp(S.dd_thanchor.Value, 'First shown')
                anch = 'first';
            else
                anch = 'swe0';
            end
            O = V.U.theory_overlay(tcol(TC), y_ph, tcol(S.WX), S.WX.swe_mm, ...
                                   anch, fringe);
            if O.ok
                mrng = O.t >= t0 & O.t < t1;
                lh(end+1) = plot(ax, O.t(mrng), O.phi_deg(mrng), '--', ...
                                 'Color', [0.35 0.35 0.35], 'LineWidth', 1);
                st_lines(end+1) = lh(end);
                % TeX \pi; paper-sign/anchor caveats live in the help text.
                leg{end+1} = sprintf('theoretical (%.0f mm/2\\pi)', fringe);
            end
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
            % Legend names come from the same per-site source as the row-1
            % checkbox labels (wx_temp_labels); underscores TeX-escaped for
            % the legend's tex interpreter.
            wxlab = V.U.wx_temp_labels(V.cfg);
            esc = @(s) strrep(s, '_', '\_');
            % Real lines live on axT; the legend (parented to ax) uses
            % invisible proxy lines on ax so it never references axT.
            if show_air
                [tt, yy] = M.aggregate(tcol(TW), TW.airtc_c, agg_wx, 'lin');
                st_lines(end+1) = plot(axT, tt, yy, '-', 'Color', c_air, ...
                                       'LineWidth', 1);
                lh(end+1) = plot(ax, [t0 t0], [NaN NaN], '-', 'Color', c_air, 'LineWidth', 1);
                st_lines(end+1) = lh(end);   % proxy width matches the real line
                leg{end+1} = esc(wxlab{1});
            end
            if show_tmp
                [tt, yy] = M.aggregate(tcol(TW), TW.temp_c, agg_wx, 'lin');
                st_lines(end+1) = plot(axT, tt, yy, '-', 'Color', c_tmp, ...
                                       'LineWidth', 1);
                lh(end+1) = plot(ax, [t0 t0], [NaN NaN], '-', 'Color', c_tmp, 'LineWidth', 1);
                st_lines(end+1) = lh(end);   % proxy width matches the real line
                leg{end+1} = esc(wxlab{2});
            end
            xlim(axT, [t0, t0 + (t1 - t0) * (tmp_w / axW)]);
            % 0 degC melt-freeze threshold — a drawn line, so it scales too
            st_lines(end+1) = yline(axT, 0, ':', 'Color', [0.3 0.3 0.3], ...
                                    'LineWidth', 0.5);
            ylabel(axT, 'Temperature (\circC)');
            axT.YColor = [0.2 0.2 0.2];
        end

        % Line x / Pt x spinners: multiply the product base styles once,
        % across both axes (ax + axT), after the TOD marker bump and
        % before the legend binds its swatches.
        V.U.style_apply(V.U.style_factors(S.sp_linew.Value, S.sp_ptsz.Value), ...
                        st_lines, st_pts, st_dots);

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

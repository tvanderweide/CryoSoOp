function soop_viewer_render_l1(V, kind)
% L1 CSV plot family + 'Data availability' + the 'Lag:' peak-lag diagnostic.
% One public entry; render_now routes both 'Lag:*' and 'L1:*'/'Data' here.
    if startsWith(kind, 'Lag:')
        render_lag(V, kind);
    else
        render_l1(V, kind);
    end
end


function render_lag(V, ~)
    S = V;
    cfg = V.cfg;
    show_msg = @(varargin) V.U.show_msg(V, varargin{:});
    range_bounds = @(varargin) V.U.range_bounds(V, varargin{:});
    tcol = V.U.tcol;
    dataset_label = @(varargin) V.U.dataset_label(V, varargin{:});
    % Measured peak-lag index over time: Signal (meas_peak_lag, L1 CSV) plus
    % the NL / L calibration captures (nl_peak_lag / l_peak_lag, calib CSV)
    % for the active Dataset. Diagnostic only — the observable is the phase
    % at the fixed cfg.peak_lag, not this argmax.
    [t0, t1] = range_bounds();
    has_sig = ~isempty(S.L1)  && ismember('meas_peak_lag', S.L1.Properties.VariableNames);
    has_cal = ~isempty(S.CAL) && ismember('nl_peak_lag',  S.CAL.Properties.VariableNames);
    if ~has_sig && ~has_cal
        show_msg(['No measured peak-lag columns in this dataset (' ...
                  char(dataset_label()) '). Re-run compute_L1 (adds ' ...
                  'meas_peak_lag) and compute_calib (adds nl_peak_lag / ' ...
                  'l_peak_lag), then Reload.']);
        return;
    end

    % Collect the series present: {label, t, lag}.
    ser = cell(0, 3);
    if has_sig
        Ts = S.L1(tcol(S.L1) >= t0 & tcol(S.L1) < t1, :);
        ser(end+1, :) = {'Signal', tcol(Ts), Ts.meas_peak_lag};
    end
    if has_cal
        Tc = S.CAL(tcol(S.CAL) >= t0 & tcol(S.CAL) < t1, :);
        ser(end+1, :) = {'NL', tcol(Tc), Tc.nl_peak_lag};
        ser(end+1, :) = {'L',  tcol(Tc), Tc.l_peak_lag};
    end

    tl = tiledlayout(S.panel, 1, 1);
    ax = nexttile(tl);
    hold(ax, 'on');
    cmap = lines(7);
    leg  = strings(1, size(ser, 1));
    ally = [];
    ntot = 0;
    stat_lines = strings(0, 1);
    for i = 1:size(ser, 1)
        nm = ser{i, 1};  ti = ser{i, 2};  yi = double(ser{i, 3});
        ok = ~isnan(yi);  ti = ti(ok);  yi = yi(ok);
        plot(ax, ti, yi, '.', 'Color', cmap(i, :), 'MarkerSize', 9);
        n = numel(yi);  ntot = ntot + n;
        ally = [ally; yi]; %#ok<AGROW>
        if n > 0
            leg(i) = sprintf('%s (n=%d, %.0f%% @0)', nm, n, 100*mean(yi == 0));
            u  = unique(yi);
            cc = arrayfun(@(v) sum(yi == v), u);
            pr = arrayfun(@(v, c) sprintf('%+d:%d', v, c), u, cc, 'UniformOutput', false);
            stat_lines(end+1) = string(nm) + " — " + strjoin(string(pr), "  "); %#ok<AGROW>
        else
            leg(i) = sprintf('%s (no rows)', nm);
        end
    end
    S.last_n = ntot;

    grid(ax, 'on');
    ylabel(ax, 'Measured peak-lag (samples)');
    xlabel(ax, 'Capture time');
    if ~isempty(ally)
        lo = min(ally) - 1;  hi = max(ally) + 1;
        ylim(ax, [lo hi]);  yticks(ax, floor(lo):ceil(hi));
    end
    title(ax, "Measured cross-correlation peak-lag index — " + dataset_label());
    subtitle(ax, "Diagnostic only; observable phase read at fixed peak\_lag = " + ...
             sprintf('%.3f', cfg.peak_lag));
    legend(ax, leg, 'Location', 'best');

    % Per-series integer-lag counts, top-left corner of the axes.
    if ~isempty(stat_lines)
        text(ax, 0.01, 0.99, "Counts by lag:" + newline + strjoin(stat_lines, newline), ...
             'Units', 'normalized', 'VerticalAlignment', 'top', ...
             'HorizontalAlignment', 'left', 'FontName', 'monospaced', ...
             'FontSize', 9, 'BackgroundColor', [1 1 1], 'Interpreter', 'none');
    end
end


function render_l1(V, kind)
    S = V;
    cfg = V.cfg;
    M = V.M;
    show_msg = @(varargin) V.U.show_msg(V, varargin{:});
    range_bounds = @(varargin) V.U.range_bounds(V, varargin{:});
    tcol = V.U.tcol;
    plot_domain_series = @(varargin) V.U.plot_domain_series(V, varargin{:});
    domain_suffix = @(varargin) V.U.domain_suffix(V, varargin{:});
    plot_series = @(varargin) V.U.plot_series(V, varargin{:});
    domain_cols = @(varargin) V.U.domain_cols(V, varargin{:});
    domain_color = V.U.domain_color;
    if isempty(S.L1)
        show_msg(sprintf('No L1 CSV found in %s', cfg.out_dir));
        return;
    end
    [t0, t1] = range_bounds();
    T = S.L1(tcol(S.L1) >= t0 & tcol(S.L1) < t1, :);
    if isempty(T)
        show_msg('No L1 rows in the selected date range.');
        return;
    end
    S.last_n = height(T);
    t   = tcol(T);
    agg = S.dd_agg.Value;
    tl  = tiledlayout(S.panel, 1, 1);
    ax  = nexttile(tl);

    switch kind
        case 'L1: Phase time series'
            plot_domain_series(ax, t, T, 'peak_phase_deg', 'peak_phase_deg_fd', ...
                               'peak_phase_deg_fd_muos', agg, 'phase');
            ylabel(ax, 'Phase (deg)');  ylim(ax, [-180 180]);  yticks(ax, -180:90:180);
            title(ax, ['Cross-correlation phase at peak\_lag (the snow observable, wrapped)' ...
                       domain_suffix()]);
        case 'L1: SNR time series'
            plot_series(ax, t, T.snr_db, agg, 'db');
            ylabel(ax, 'SNR (dB)');  title(ax, 'Peak SNR');
        case 'L1: Amplitude time series'
            plot_domain_series(ax, t, T, 'peak_amplitude', 'peak_amplitude_fd', ...
                               'peak_amplitude_fd_muos', agg, 'lin');
            ylabel(ax, 'Amplitude (ADC units)');
            title(ax, ['Coherent reflection amplitude' domain_suffix()]);
        case 'L1: Noise floor time series'
            plot_series(ax, t, T.noise_floor, agg, 'lin');
            ylabel(ax, 'Noise floor (ADC units)');  title(ax, 'Correlation noise floor');
        case 'L1: SNR histogram'
            histogram(ax, T.snr_db, 60);
            xlabel(ax, 'SNR (dB)');  ylabel(ax, 'Count');
            title(ax, sprintf('SNR distribution, %d captures in range', height(T)));
        case 'L1: Phase vs SNR scatter'
            [cols, labs] = domain_cols(T, 'peak_phase_deg', 'peak_phase_deg_fd', ...
                                       'peak_phase_deg_fd_muos');
            hold(ax, 'on');
            hh = gobjects(numel(cols), 1);
            for ii = 1:numel(cols)
                hh(ii) = scatter(ax, T.snr_db, T.(cols{ii}), 6, 'filled', ...
                    'MarkerFaceAlpha', 0.25, 'MarkerFaceColor', domain_color(labs{ii}));
            end
            hold(ax, 'off');
            if numel(cols) > 1, legend(hh, labs, 'Location', 'best'); end
            xlabel(ax, 'SNR (dB)');  ylabel(ax, 'Phase (deg)');
            ylim(ax, [-180 180]);  yticks(ax, -180:90:180);
            title(ax, ['Phase vs SNR — does low SNR mean phase scatter?' domain_suffix()]);
        case 'L1: Diurnal phase pattern'
            hr = hour(t);
            % When Detrend is ticked, subtract each day's circular mean from its
            % captures before binning, so the seasonal wander S(day) (common to
            % all hours within a day) is removed and only the diurnal residual
            % remains. This is the clean test for a real (vs. coverage-aliased)
            % hour-of-day signal.
            detrend_on = S.sw_detrend.Value;
            if detrend_on, day_grp = findgroups(dateshift(t, 'start', 'day')); end
            [cols, labs] = domain_cols(T, 'peak_phase_deg', 'peak_phase_deg_fd', ...
                                       'peak_phase_deg_fd_muos');
            hold(ax, 'on');
            hh = gobjects(numel(cols), 1);
            for ii = 1:numel(cols)
                yc = T.(cols{ii});
                if detrend_on
                    mu_day = splitapply(@(x) M.first_out(M.circ_stats, x), yc, day_grp);
                    % Wrapped residual (deg): complex round-trip keeps it in ±180.
                    yc = rad2deg(angle(exp(1i * deg2rad(yc - mu_day(day_grp)))));
                end
                [mu, sd] = deal(nan(24, 1));
                for h = 0:23
                    x = yc(hr == h);
                    if ~isempty(x), [mu(h+1), sd(h+1)] = M.circ_stats(x); end
                end
                hh(ii) = errorbar(ax, 0:23, mu, sd, 'o-', 'Color', domain_color(labs{ii}));
            end
            hold(ax, 'off');
            if numel(cols) > 1, legend(hh, labs, 'Location', 'best'); end
            xlabel(ax, 'Hour of day (capture timestamp — Pi clock timezone)');
            xlim(ax, [-0.5 23.5]);
            if detrend_on
                ylabel(ax, 'Residual phase \pm circ. std (deg), daily mean removed');
                title(ax, ['Diurnal phase RESIDUAL (daily circ. mean removed)' domain_suffix()]);
            else
                ylabel(ax, 'Circular mean phase \pm circ. std (deg)');
                title(ax, ['Diurnal phase pattern (melt-freeze cycling)' domain_suffix()]);
            end
        case 'L1: Within-run phase scatter'
            grp = M.run_groups(t);
            t_run = splitapply(@min, t, grp);
            [cols, labs] = domain_cols(T, 'peak_phase_deg', 'peak_phase_deg_fd', ...
                                       'peak_phase_deg_fd_muos');
            hold(ax, 'on');
            hh = gobjects(numel(cols), 1);
            for ii = 1:numel(cols)
                sd_run = splitapply(@(x) M.second_out(M.circ_stats, x), T.(cols{ii}), grp);
                hh(ii) = plot(ax, t_run, sd_run, '.', 'Color', domain_color(labs{ii}));
            end
            hold(ax, 'off');
            if numel(cols) > 1, legend(hh, labs, 'Location', 'best'); end
            ylabel(ax, 'Circular std of run''s captures (deg)');
            title(ax, ['Within-run phase scatter (15 captures / 2-hourly run)' domain_suffix()]);
        case 'L1: Peak-bin vs elevation (QA)'
            if isempty(S.L2)
                show_msg('Needs BrundageSoOp_L2.csv (run compute_L2) for elevation.');
                return;
            end
            if ~all(ismember({'base_name', 'meas_peak_lag'}, ...
                    T.Properties.VariableNames))
                show_msg(['Peak-bin vs elevation needs base_name + ' ...
                          'meas_peak_lag in L1 — re-run compute_L1.']);
                return;
            end
            % Filter BOTH tables to the date range BEFORE join, then
            % inner-join on base_name. Only captures in both L1 and L2 appear.
            L2r = S.L2(tcol(S.L2) >= t0 & tcol(S.L2) < t1, :);
            if isempty(L2r) || ~all(ismember({'base_name', 'theta_deg'}, ...
                    L2r.Properties.VariableNames))
                show_msg(['Peak-bin vs elevation needs base_name + theta_deg ' ...
                          'in L2 (in range) — re-run compute_L2.']);
                return;
            end
            J = innerjoin(T(:, {'base_name', 'meas_peak_lag'}), ...
                          L2r(:, {'base_name', 'theta_deg'}), 'Keys', 'base_name');
            th = J.theta_deg;  pl = J.meas_peak_lag;
            fin = isfinite(th) & isfinite(pl);
            th = th(fin);  pl = pl(fin);
            if isempty(th)
                show_msg('No captures present in both L1 and L2 (in range).');
                return;
            end
            hold(ax, 'on');
            hs = scatter(ax, th, pl, 10, 'filled', 'MarkerFaceAlpha', 0.25);
            lh = hs;  ls = {'per capture'};
            if max(th) > min(th)            % binned median (gross trend QA)
                edges = linspace(min(th), max(th), 13);
                bc    = 0.5 * (edges(1:end-1) + edges(2:end));
                bidx  = discretize(th, edges);
                bmed  = nan(numel(bc), 1);
                for b = 1:numel(bc)
                    bmed(b) = median(pl(bidx == b), 'omitnan');
                end
                hb = plot(ax, bc, bmed, 'o-', 'Color', [0.85 0.1 0.1], ...
                          'LineWidth', 1.2, 'MarkerFaceColor', [0.85 0.1 0.1]);
                lh(end+1) = hb;  ls{end+1} = 'binned median';
            end
            yline(ax, cfg.peak_lag, '--', sprintf(['fixed fractional ' ...
                'extraction lag (%.3f; sub-sample, not comparable to ' ...
                'integer bins)'], cfg.peak_lag), 'Color', [0.3 0.3 0.3], ...
                'LabelHorizontalAlignment', 'left');
            hold(ax, 'off');
            legend(lh, ls, 'Location', 'best');
            xlabel(ax, 'Satellite elevation \theta (deg)');
            ylabel(ax, 'Measured peak-lag bin (integer argmax, samples)');
            title(ax, sprintf(['Peak-bin vs elevation QA (n=%d; integer ' ...
                'argmax — gross check, not sub-sample drift)'], numel(th)));
        case 'Data availability'
            day_key = dateshift(t, 'start', 'day');
            is_ovf  = ismember(T.base_name, S.OVF);
            [gd, days_u] = findgroups(day_key);
            n_clean = splitapply(@(x) sum(~x), is_ovf, gd);
            n_ovf   = splitapply(@(x) sum(x),  is_ovf, gd);
            hb = bar(ax, days_u, [n_clean, n_ovf], 1, 'stacked');
            hb(1).FaceColor = [0.000 0.447 0.741];   % clean
            hb(2).FaceColor = [0.850 0.100 0.100];   % overflow-flagged
            yline(ax, 180, '--', 'expected (12 runs x 15)');
            legend(ax, {'clean', 'overflow-flagged'}, 'Location', 'best');
            ylabel(ax, 'Captures per day');
            if isempty(S.OVF)
                title(ax, 'Data availability (no overflow_timestamps.txt found)');
            else
                title(ax, sprintf('Data availability — %d overflow-flagged in range', ...
                      sum(is_ovf)));
            end
    end
    grid(ax, 'on');
end

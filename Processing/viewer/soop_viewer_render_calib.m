% soop_viewer_render_calib  Calib CSV plot family (Eqs. 25-40). rc_* helpers are family-private.
function soop_viewer_render_calib(V, kind)
    S = V;
    cfg = V.cfg;
    M = V.M;
    show_msg = @(varargin) V.U.show_msg(V, varargin{:});
    range_bounds = @(varargin) V.U.range_bounds(V, varargin{:});
    tcol = V.U.tcol;
    plot_series = @(varargin) V.U.plot_series(V, varargin{:});
    looks_curve_plot = @(varargin) V.U.looks_curve_plot(V, varargin{:});
    is_compare_mode = @(varargin) V.U.is_compare_mode(V, varargin{:});
    chain_phase_col = V.D.chain_phase_col;
    phase_noise_plot = @(varargin) rc_phase_noise_plot(V, varargin{:});
    overlay_notch = @(varargin) rc_overlay_notch(V, varargin{:});
    apply_base_ylim = @(varargin) rc_apply_base_ylim(V, varargin{:});
    if isempty(S.CAL)
        show_msg(sprintf('No calib CSV found in %s', cfg.out_dir));
        return;
    end
    [t0, t1] = range_bounds();
    T = S.CAL(tcol(S.CAL) >= t0 & tcol(S.CAL) < t1, :);
    if isempty(T)
        show_msg('No calibration rows in the selected date range.');
        return;
    end

    % Exclude overflow-flagged pairs: UHD sample drops corrupt rho_DRL /
    % rho_DRNS and all downstream calibration quantities for that pair.
    if ismember('overflow_flag', T.Properties.VariableNames)
        n_ovf = sum(T.overflow_flag ~= 0);
        if n_ovf > 0
            fprintf('[viewer] Excluding %d overflow-flagged calib pairs from plots.\n', n_ovf);
        end
        T = T(T.overflow_flag == 0, :);
    else
        fprintf(['[viewer] WARNING: overflow_flag absent from calib CSV — all pairs ' ...
                 'shown. Re-run compute_calib to add overflow flags.\n']);
    end
    if isempty(T)
        show_msg('All calibration rows in range are overflow-flagged.');
        return;
    end

    S.last_n = height(T);
    t   = tcol(T);
    agg = S.dd_agg.Value;
    tl  = tiledlayout(S.panel, 1, 1);
    ax  = nexttile(tl);

    switch kind
        case 'Calib: Cross-correlation amplitudes (C_RDL, C_RDNS)'
            plot_series(ax, t, T.C_RDL_amp, agg, 'lin');
            hold(ax, 'on');
            plot_series(ax, t, T.C_RDNS_amp, agg, 'lin');
            if strcmp(S.sw_ampscale.Value, 'Linear')
                set(ax, 'YScale', 'linear');
                ylabel(ax, '|C| (ADC^2)');
            else
                set(ax, 'YScale', 'log');
                ylabel(ax, '|C| (ADC^2, log)');
            end
            legend(ax, {'C\_RDL (load only)', 'C\_RDNS (noise source)'}, ...
                   'Location', 'best');
            title(ax, 'Lag-0 cross-correlation amplitudes (Eqs. 25, 27)');
        case 'Calib: Cross-correlation phase (C_RDL, C_RDNS)'
            plot_series(ax, t, T.C_RDL_phase_deg, agg, 'phase');
            if ismember('C_RDNS_phase_deg', T.Properties.VariableNames)
                hold(ax, 'on');
                plot_series(ax, t, T.C_RDNS_phase_deg, agg, 'phase');
                legend(ax, {'C\_RDL (load only)', 'C\_RDNS (noise source)'}, ...
                       'Location', 'best');
                title(ax, 'Inter-channel phase (Eqs. 25, 27)');
            else
                legend(ax, {'C\_RDL (load only)'}, 'Location', 'best');
                title(ax, 'Inter-channel phase — C\_RDNS phase needs the v3 calib CSV');
            end
            ylabel(ax, 'Phase (deg)');  ylim(ax, [-180 180]);  yticks(ax, -180:90:180);
        case 'Calib: Chain phase (NS - L)'
            need = {'C_RDNS_amp', 'C_RDNS_phase_deg', 'C_RDL_amp', 'C_RDL_phase_deg'};
            if ~all(ismember(need, T.Properties.VariableNames))
                show_msg(['Chain phase needs C_RDNS/C_RDL amp + phase ' ...
                          'columns — re-run compute_calib (v2+ schema).']);
                return;
            end
            plot_series(ax, t, chain_phase_col(T), agg, 'phase');
            ylabel(ax, 'Chain phase (deg)');
            title(ax, ['Leak-cancelled chain phase: angle(C\_RDNS - C\_RDL) ' ...
                       '— diagnostic (applied cal uses angle(C\_RDNS) only)']);
        case 'Calib: rho_NS phase + expected noise (C_RDNS)'
            need = {'C_RDNS_phase_deg', 'rho_DRNS'};
            if ~all(ismember(need, T.Properties.VariableNames))
                show_msg(['rho_NS phase needs C_RDNS_phase_deg + rho_DRNS ' ...
                          '— re-run compute_calib (v3 schema).']);
                return;
            end
            phase_noise_plot(ax, t, T.C_RDNS_phase_deg, T.rho_DRNS, agg, ...
                'C_RDNS_phase_deg', 'rho_DRNS', 'C\_RDNS', ...
                'Noise-source inter-channel phase vs thermal floor (Eqs. 27, 40)');
        case 'Calib: rho_L phase + expected noise (C_RDL)'
            need = {'C_RDL_phase_deg', 'rho_DRL'};
            if ~all(ismember(need, T.Properties.VariableNames))
                show_msg(['rho_L phase needs C_RDL_phase_deg + rho_DRL ' ...
                          '— re-run compute_calib.']);
                return;
            end
            phase_noise_plot(ax, t, T.C_RDL_phase_deg, T.rho_DRL, agg, ...
                'C_RDL_phase_deg', 'rho_DRL', 'C\_RDL', ...
                'Load-only inter-channel phase vs thermal floor (Eqs. 25, 38)');
        case 'Calib: Phase variance vs looks (C_RDL, C_RDNS)'
            need = {'C_RDL_phase_deg', 'rho_DRL'};
            if ~all(ismember(need, T.Properties.VariableNames))
                show_msg(['Phase variance vs looks needs C_RDL_phase_deg + ' ...
                          'rho_DRL — re-run compute_calib.']);
                return;
            end
            co  = ax.ColorOrder;
            grp = M.run_groups(t);
            items(1) = struct('deg', T.C_RDL_phase_deg, 'grp', grp, ...
                'lbl', 'C\_RDL (load)', 'rho', T.rho_DRL, 'color', co(1, :));
            if all(ismember({'C_RDNS_phase_deg', 'rho_DRNS'}, ...
                    T.Properties.VariableNames))
                items(2) = struct('deg', T.C_RDNS_phase_deg, 'grp', grp, ...
                    'lbl', 'C\_RDNS (noise source)', 'rho', T.rho_DRNS, ...
                    'color', co(2, :));
            end
            if ~looks_curve_plot(ax, items, ['Calib phase variance vs looks' ...
                    ' (flat = systematic pedestal; -1/2 = thermal)'], ...
                    'Allan deviation of block-mean phase (deg)')
                show_msg(['Not enough captures per run in range for a ' ...
                          'variance-vs-looks curve (need >= 3 look counts ' ...
                          'with >= 20 pooled block pairs).']);
                return;
            end
        case 'Calib: Noise-source power (P_NS)'
            if ~ismember('P_NS', T.Properties.VariableNames)
                show_msg(['Noise-source power needs P_NS — re-run ' ...
                          'compute_calib (v3 schema).']);
                return;
            end
            plot_series(ax, t, T.P_NS, agg, 'lin');
            ylabel(ax, 'P_{NS} (W)');
            title(ax, 'Noise-source power (Eq. 31)');
        case 'Calib: Gain drift (G_De, G_Re)'
            if strcmp(S.sw_gain.Value, 'Raw')
                % Eq. 34 output as-is (absolute ADC^2/W scale).
                plot_series(ax, t, T.G_De, agg, 'lin');
                hold(ax, 'on');
                plot_series(ax, t, T.G_Re, agg, 'lin');
                ylabel(ax, 'Gain |G| (ADC^2 / W)');
                title(ax, 'Receiver gain (Eq. 34)');
            else
                % Absolute gain scale is arbitrary — show drift vs season median.
                plot_series(ax, t, T.G_De / median(T.G_De, 'omitnan'), agg, 'lin');
                hold(ax, 'on');
                plot_series(ax, t, T.G_Re / median(T.G_Re, 'omitnan'), agg, 'lin');
                yline(ax, 1, ':');
                ylabel(ax, 'Gain / season median');
                title(ax, 'Receiver gain drift (Eq. 34)');
            end
            legend(ax, {'G\_De (direct)', 'G\_Re (reflected)'}, 'Location', 'best');
        case 'Calib: Receiver noise powers (P_DN, P_RN)'
            plot_series(ax, t, T.P_DN, agg, 'lin');
            hold(ax, 'on');
            plot_series(ax, t, T.P_RN, agg, 'lin');
            legend(ax, {'P\_DN (direct)', 'P\_RN (reflected)'}, 'Location', 'best');
            ylabel(ax, 'Noise power (ADC^2)');
            title(ax, 'Receiver noise powers (Eq. 36)');
        case 'Calib: SNR, load (SNR_DL, SNR_RL)'
            need = {'SNR_DL', 'SNR_RL'};
            if ~all(ismember(need, T.Properties.VariableNames))
                show_msg(['Load SNR needs SNR_DL/SNR_RL — re-run ' ...
                          'compute_calib (v3 schema).']);
                return;
            end
            if strcmp(S.sw_snr.Value, 'dB')
                plot_series(ax, t, 10*log10(T.SNR_DL), agg, 'db');
                hold(ax, 'on');
                plot_series(ax, t, 10*log10(T.SNR_RL), agg, 'db');
                set(ax, 'YScale', 'linear');
                ylabel(ax, 'SNR (dB)');
            else
                plot_series(ax, t, T.SNR_DL, agg, 'lin');
                hold(ax, 'on');
                plot_series(ax, t, T.SNR_RL, agg, 'lin');
                set(ax, 'YScale', 'linear');
                ylabel(ax, 'SNR (\times)');
            end
            legend(ax, {'SNR\_DL (direct)', 'SNR\_RL (reflected)'}, 'Location', 'best');
            title(ax, 'Load-injection SNR (Eq. 37)');
        case 'Calib: SNR, noise source (SNR_DNS, SNR_RNS)'
            need = {'SNR_DNS', 'SNR_RNS'};
            if ~all(ismember(need, T.Properties.VariableNames))
                show_msg(['Noise-source SNR needs SNR_DNS/SNR_RNS — re-run ' ...
                          'compute_calib (v3 schema).']);
                return;
            end
            if strcmp(S.sw_snr.Value, 'dB')
                plot_series(ax, t, 10*log10(T.SNR_DNS), agg, 'db');
                hold(ax, 'on');
                plot_series(ax, t, 10*log10(T.SNR_RNS), agg, 'db');
                set(ax, 'YScale', 'linear');
                ylabel(ax, 'SNR (dB)');
            else
                plot_series(ax, t, T.SNR_DNS, agg, 'lin');
                hold(ax, 'on');
                plot_series(ax, t, T.SNR_RNS, agg, 'lin');
                set(ax, 'YScale', 'linear');
                ylabel(ax, 'SNR (\times)');
            end
            legend(ax, {'SNR\_DNS (direct)', 'SNR\_RNS (reflected)'}, 'Location', 'best');
            title(ax, 'Noise-source-injection SNR (Eq. 39)');
        case 'Calib: Cross-correlation coeffs (rho_DRL, rho_DRNS)'
            plot_series(ax, t, T.rho_DRL, agg, 'lin');
            if ismember('rho_DRNS', T.Properties.VariableNames)
                hold(ax, 'on');
                plot_series(ax, t, T.rho_DRNS, agg, 'lin');
                legend(ax, {'\rho_{DRL} (load only)', '\rho_{DRNS} (noise source)'}, ...
                       'Location', 'best');
                title(ax, 'Cross-correlation coefficients (Eqs. 38, 40)');
            else
                legend(ax, {'\rho_{DRL} (load only)'}, 'Location', 'best');
                title(ax, 'Cross-correlation coefficients — \rho_{DRNS} needs the v2 calib CSV');
            end
            ylabel(ax, '\rho');  ylim(ax, [0 1]);
        case 'Calib: Power ratio (NS / L)'
            need = {'P_DL', 'P_RL', 'P_DNS', 'P_RNS'};
            if ~all(ismember(need, T.Properties.VariableNames))
                show_msg(['Power ratio needs P_DL/P_RL/P_DNS/P_RNS — re-run ' ...
                          'compute_calib (v3 schema).']);
                return;
            end
            y_D = T.P_DNS ./ T.P_DL;     % direct   channel Y-factor
            y_R = T.P_RNS ./ T.P_RL;     % reflected channel Y-factor
            if strcmp(S.sw_units.Value, 'dB')
                plot_series(ax, t, 10*log10(y_D), agg, 'db');  hold(ax, 'on');
                plot_series(ax, t, 10*log10(y_R), agg, 'db');
                ylabel(ax, 'NS / L power ratio (dB)');
            else
                plot_series(ax, t, y_D, agg, 'lin');  hold(ax, 'on');
                plot_series(ax, t, y_R, agg, 'lin');
                set(ax, 'YScale', 'log');
                ylabel(ax, 'NS / L power ratio (\times)');
            end
            legend(ax, {'direct (P_{DNS}/P_{DL})', 'reflected (P_{RNS}/P_{RL})'}, ...
                   'Location', 'best');
            title(ax, 'Noise-source / load power ratio (Y-factor)');
            % Fixed range (not base-anchored, see below): the live
            % base-anchoring used elsewhere shifts slightly under the notch
            % filter, pushing the notch trace outside base's range and
            % hiding it. 2.6-7x covers the observed data for both Datasets.
            if strcmp(S.sw_units.Value, 'dB')
                ylim(ax, 10*log10([2.6 7]));
            else
                ylim(ax, [2.6 7]);
            end
    end
    grid(ax, 'on');
    if is_compare_mode()
        % 'base vs notch' Dataset: overlay the notch series on top of the
        % base draw and let the axis autoscale to span BOTH datasets (no
        % base-anchoring). Fixed-range views (phase/rho/power-ratio) keep the
        % ylim they set in their case above, which covers both datasets.
        overlay_notch(kind, ax, agg);
    elseif ~any(strcmp(kind, {'Calib: Power ratio (NS / L)', ...
                              'Calib: Noise-source power (P_NS)', ...
                              'Calib: rho_NS phase + expected noise (C_RDNS)', ...
                              'Calib: rho_L phase + expected noise (C_RDL)', ...
                              'Calib: Phase variance vs looks (C_RDL, C_RDNS)'}))
        % Anchor the y-axis to the BASE Dataset so notch Calib
        % plots share base's scale for direct comparison when switching
        % Datasets (phase/rho already use fixed limits, so they're untouched).
        % Same base-anchoring idea as the spectrogram colorbar and the cross-
        % correlation y-axis. Power ratio and P_NS opt out and autoscale to
        % their own dataset — the notch values fall outside base's range, so
        % anchoring to base would push the notch trace off-axis. The two
        % rho-phase views opt out too: they set their own base-anchored,
        % auto-zoomed window via set_phase_noise_ylim (phase_noise_plot). The
        % phase-variance-vs-looks view opts out as well: it sets its own
        % log-log axes (looks_curve_plot) and draws base only.
        apply_base_ylim(kind, ax, agg);
    end
end


function rc_apply_base_ylim(V, kind, ax, agg)
    M = V.M;
    base_calib_table = @(varargin) V.D.base_calib_table(V, varargin{:});
    calib_series = @(varargin) rc_calib_series(V, varargin{:});
    tcol = V.U.tcol;
    % Replace the autoscaled y-limits with limits computed from the BASE
    % (unfiltered) calib data for this view, so switching Dataset never
    % rescales the axis. No-op for fixed-axis views (calib_series returns
    % aggkind '') or when the base CSV / columns are unavailable (keeps the
    % current autoscale). Applied on the base Dataset too, so base and
    % notch land on identical limits (same padding). YScale is
    % read after drawing so log axes get multiplicative padding and stay > 0.
    Tb = base_calib_table();
    if isempty(Tb), return; end
    [series, aggkind] = calib_series(kind, Tb);
    if isempty(aggkind) || isempty(series), return; end
    is_log = strcmp(get(ax, 'YScale'), 'log');
    los = [];  his = [];
    for k = 1:numel(series)
        [~, ya, ys] = M.aggregate(tcol(Tb), series{k}, agg, aggkind);
        if isempty(ys), ys = zeros(size(ya)); end
        lo_k = ya - ys;
        if is_log
            % A log axis can't show <= 0; drop non-positive lower bounds
            % (errorbar clips them anyway) and fall back to the positive
            % aggregated points so the axis still anchors near the data.
            lo_k = [lo_k(lo_k > 0); ya(ya > 0)];
        end
        los = [los; lo_k(:)];        %#ok<AGROW> small (<=2 series)
        his = [his; ya(:) + ys(:)];  %#ok<AGROW>
    end
    lo = min(los);  hi = max(his);
    if ~(isfinite(lo) && isfinite(hi) && hi > lo), return; end
    if is_log
        if lo <= 0, return; end           % no positive data to anchor to
        f = (hi / lo) ^ 0.05;             % 5% padding in log space
        ylim(ax, [lo / f, hi * f]);
    else
        pad = 0.05 * (hi - lo);
        ylim(ax, [lo - pad, hi + pad]);
    end
end


function rc_phase_noise_plot(V, ax, t, phase, rho, agg, phase_col, rho_col, lbl, ttl)
    M = V.M;
    calib_N_looks = V.calib_N_looks;
    plot_series = @(varargin) V.U.plot_series(V, varargin{:});
    set_phase_noise_ylim = @(varargin) rc_set_phase_noise_ylim(V, varargin{:});
    % Inter-channel phase (deg) vs time with the expected thermal phase-noise
    % floor sigma_phi(rho) overlaid as a grey +/- pair about the circular
    % mean. The floor is the EXPECTED PER-CAPTURE phase scatter (not the
    % standard error of an aggregated mean), so it is directly comparable to
    % the raw point scatter and to the circular-std error bars. sigma_phi is
    % tiny (~0.01 deg); measured scatter that greatly exceeds it is the
    % intended systematic-vs-thermal diagnostic, not a plot error.
    hp       = plot_series(ax, t, phase, agg, 'phase');   % points / errorbar
    hold(ax, 'on');
    c0       = M.circ_stats(phase);                       % circular mean (deg)
    [tr, ra] = M.aggregate(t, rho, agg, 'lin');           % mean rho per bin
    sb       = M.sigma_phi_deg(ra, calib_N_looks);        % thermal floor (deg)
    hf = plot(ax, tr, c0 + sb, '--', tr, c0 - sb, '--');  % +/- floor about mean
    set(hf, 'Color', [0.5 0.5 0.5], 'Tag', 'phase_floor', ...
            'HandleVisibility', 'off');                   % excluded from overlay_notch
    legend(ax, [hp, hf(1)], {[lbl ' phase'], ...
           '\pm\sigma_\phi (thermal floor, nominal N_L)'}, 'Location', 'best');
    ylabel(ax, 'Phase (deg)');
    title(ax, sprintf('%s (\\sigma_\\phi ~ %.2g deg, nominal N_L)', ttl, ...
          median(sb, 'omitnan')));
    set_phase_noise_ylim(ax, phase_col, rho_col);
end


function rc_set_phase_noise_ylim(V, ax, phase_col, rho_col)
    M = V.M;
    calib_N_looks = V.calib_N_looks;
    base_calib_table = @(varargin) V.D.base_calib_table(V, varargin{:});
    % Base-anchored, wrap-safe auto-zoom for the Calib rho-phase views: centre
    % on the BASE circular-mean phase and size the half-window from the BASE
    % measured spread (which dominates the tiny thermal floor), so switching
    % Dataset never rescales the axis (same base-anchoring idea as
    % apply_base_ylim). No-op (keep autoscale) if the base CSV / columns are
    % unavailable. The 0.05 deg floor keeps the window sane if the spread and
    % sigma_phi are both ~0.
    Tb = base_calib_table();
    if isempty(Tb) || ~all(ismember({phase_col, rho_col}, ...
            Tb.Properties.VariableNames))
        return;
    end
    ph    = Tb.(phase_col);
    c     = M.circ_stats(ph);                          % circular mean (deg)
    sb    = M.sigma_phi_deg(Tb.(rho_col), calib_N_looks);
    resid = mod(ph - c + 180, 360) - 180;              % wrapTo180(ph - c)
    half  = max([3 * max(sb, [], 'omitnan'), ...
                 1.2 * max(abs(resid), [], 'omitnan'), 0.05]);
    if isfinite(c) && isfinite(half) && half > 0
        ylim(ax, c + [-half, half]);
    end
end


function [series, aggkind] = rc_calib_series(V, kind, Tin)
    S = V;
    % Numeric y-series each Calib view plots, for table Tin — the single
    % source of truth used to anchor the y-axis to the base Dataset. Scale
    % toggles (sw_ampscale/sw_snr/sw_units/sw_gain) are read from the shared
    % UI, so base and active datasets transform identically. aggkind ('lin'/
    % 'db') matches the M.aggregate kind used when drawing; '' flags a fixed-
    % axis view (phase, rho) needing no base anchoring. Missing columns yield
    % an empty series (anchoring skipped, like the draw-time guards).
    %
    % KEEP IN SYNC with the drawing switch in render_calib: the transforms
    % here must match what plot_series receives there.
    series = {};  aggkind = 'lin';
    vn = Tin.Properties.VariableNames;
    switch kind
        case 'Calib: Cross-correlation amplitudes (C_RDL, C_RDNS)'
            series = {Tin.C_RDL_amp, Tin.C_RDNS_amp};
        case 'Calib: Noise-source power (P_NS)'
            if ismember('P_NS', vn), series = {Tin.P_NS}; end
        case 'Calib: Gain drift (G_De, G_Re)'
            if strcmp(S.sw_gain.Value, 'Raw')
                series = {Tin.G_De, Tin.G_Re};
            else
                series = {Tin.G_De ./ median(Tin.G_De, 'omitnan'), ...
                          Tin.G_Re ./ median(Tin.G_Re, 'omitnan')};
            end
        case 'Calib: Receiver noise powers (P_DN, P_RN)'
            series = {Tin.P_DN, Tin.P_RN};
        case 'Calib: SNR, load (SNR_DL, SNR_RL)'
            if all(ismember({'SNR_DL', 'SNR_RL'}, vn))
                if strcmp(S.sw_snr.Value, 'dB')
                    series = {10*log10(Tin.SNR_DL), 10*log10(Tin.SNR_RL)};
                    aggkind = 'db';
                else
                    series = {Tin.SNR_DL, Tin.SNR_RL};
                end
            end
        case 'Calib: SNR, noise source (SNR_DNS, SNR_RNS)'
            if all(ismember({'SNR_DNS', 'SNR_RNS'}, vn))
                if strcmp(S.sw_snr.Value, 'dB')
                    series = {10*log10(Tin.SNR_DNS), 10*log10(Tin.SNR_RNS)};
                    aggkind = 'db';
                else
                    series = {Tin.SNR_DNS, Tin.SNR_RNS};
                end
            end
        case 'Calib: Power ratio (NS / L)'
            if all(ismember({'P_DL', 'P_RL', 'P_DNS', 'P_RNS'}, vn))
                yD = Tin.P_DNS ./ Tin.P_DL;
                yR = Tin.P_RNS ./ Tin.P_RL;
                if strcmp(S.sw_units.Value, 'dB')
                    series = {10*log10(yD), 10*log10(yR)};  aggkind = 'db';
                else
                    series = {yD, yR};
                end
            end
        otherwise
            aggkind = '';   % phase / rho (fixed limits) or unknown
    end
end


function [series, aggkind] = rc_calib_overlay_series(V, kind, Tin)
    calib_series = @(varargin) rc_calib_series(V, varargin{:});
    chain_phase_col = V.D.chain_phase_col;
    % Numeric y-series + aggkind for the notch overlay in the 'base vs notch'
    % Dataset. Defers to calib_series for the magnitude / SNR / power-ratio
    % views (one source of truth, kept in sync with render_calib), and adds
    % the two fixed-axis views (phase, rho) that calib_series intentionally
    % omits (it returns '' there so apply_base_ylim skips them).
    [series, aggkind] = calib_series(kind, Tin);
    if ~isempty(aggkind) && ~isempty(series), return; end
    vn = Tin.Properties.VariableNames;
    switch kind
        case 'Calib: Cross-correlation phase (C_RDL, C_RDNS)'
            series = {Tin.C_RDL_phase_deg};
            if ismember('C_RDNS_phase_deg', vn)
                series{end+1} = Tin.C_RDNS_phase_deg;
            end
            aggkind = 'phase';
        case 'Calib: Chain phase (NS - L)'
            need = {'C_RDNS_amp', 'C_RDNS_phase_deg', 'C_RDL_amp', 'C_RDL_phase_deg'};
            if all(ismember(need, vn))
                series = {chain_phase_col(Tin)};  aggkind = 'phase';
            end
        case 'Calib: Cross-correlation coeffs (rho_DRL, rho_DRNS)'
            series = {Tin.rho_DRL};
            if ismember('rho_DRNS', vn)
                series{end+1} = Tin.rho_DRNS;
            end
            aggkind = 'lin';
        case 'Calib: rho_NS phase + expected noise (C_RDNS)'
            % Overlay the notch phase only; the sigma_phi floor stays
            % base/nominal (the grey 'phase_floor' lines are excluded from
            % the base-trace match in overlay_notch).
            if ismember('C_RDNS_phase_deg', vn)
                series = {Tin.C_RDNS_phase_deg};  aggkind = 'phase';
            end
        case 'Calib: rho_L phase + expected noise (C_RDL)'
            if ismember('C_RDL_phase_deg', vn)
                series = {Tin.C_RDL_phase_deg};  aggkind = 'phase';
            end
    end
end


function rc_overlay_notch(V, kind, ax, agg)
    notch_calib_table = @(varargin) V.D.notch_calib_table(V, varargin{:});
    calib_overlay_series = @(varargin) rc_calib_overlay_series(V, varargin{:});
    tcol = V.U.tcol;
    plot_series = @(varargin) V.U.plot_series(V, varargin{:});
    % 'base vs notch' Dataset: overlay the NOTCH calib series on the already-
    % drawn BASE traces, sharing one autoscaled axis. Single-series views
    % (P_NS) use two distinct solid colours (clearest contrast); multi-series
    % views match each base series' colour with a dashed notch trace. The
    % legend gains '(base)' / '[notch]' tags. No-op if the notch products are
    % absent or the view has no overlayable series.
    Tn = notch_calib_table();
    if isempty(Tn), return; end
    [sn, ak] = calib_overlay_series(kind, Tn);
    if isempty(ak) || isempty(sn), return; end

    % Base data traces drawn so far (Line/ErrorBar only — excludes the
    % xline/yline ConstantLine objects some cases add). flipud => plot order.
    ch     = ax.Children;
    isdat  = arrayfun(@(h) (isa(h, 'matlab.graphics.chart.primitive.Line') || ...
                           isa(h, 'matlab.graphics.chart.primitive.ErrorBar')) && ...
                           ~strcmp(h.Tag, 'phase_floor'), ch);  % skip sigma_phi floor lines
    base_h = flipud(ch(isdat));
    lg = get(ax, 'Legend');
    if isempty(lg), base_names = {}; else, base_names = cellstr(lg.String); end

    tn = tcol(Tn);
    co = ax.ColorOrder;
    hold(ax, 'on');
    nb       = numel(base_h);
    one_pair = (nb == 1) && isscalar(sn);
    notch_h  = gobjects(1, numel(sn));
    for k = 1:numel(sn)
        h = plot_series(ax, tn, sn{k}, agg, ak);
        if one_pair
            % Headline single-quantity view (P_NS): a second solid colour.
            set(h, 'Color', co(min(2, size(co,1)), :));
        else
            % Match base series colour; dashed line marks the notch dataset.
            set(h, 'Color', co(mod(k-1, size(co,1)) + 1, :), 'LineStyle', '--');
            if isa(h, 'matlab.graphics.chart.primitive.ErrorBar')
                set(h, 'Marker', 's');
            end
        end
        notch_h(k) = h;
    end

    if one_pair
        legend(ax, [base_h(:); notch_h(:)], {'base', 'notch'}, 'Location', 'best');
    elseif numel(base_names) == nb && numel(notch_h) == nb
        legend(ax, [base_h(:); notch_h(:)], ...
               [base_names(:); strcat(base_names(:), {' [notch]'})], ...
               'Location', 'best');
    else
        legend(ax, [base_h(1); notch_h(1)], ...
               {'base (solid)', 'notch (dashed)'}, 'Location', 'best');
    end
end

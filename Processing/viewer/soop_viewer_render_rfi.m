function soop_viewer_render_rfi(V, kind)
% Season RFI views: the interactive band explorer ('Raw: Season RFI spectrum')
% and the notch-effect PSD ('Raw: Season PSD - notch effect').
    if startsWith(kind, 'Raw: Season PSD')
        rfi_filter_psd(V, kind);
    else
        rfi_explorer(V);
    end
end


function rfi_explorer(V)
    S = V;
    cfg = V.cfg;
    show_msg = @(varargin) V.U.show_msg(V, varargin{:});
    cfgdef = @(varargin) V.U.cfgdef(V, varargin{:});
    % Interactive RFI band explorer. Reads the season per-bin statistics from
    % the selected 'RFI set' (Signal/NL/L) season spectrum
    % (rfi_spectrum<sfx>.csv, compute_rfi_spectrum) and re-derives the proposed
    % bands LIVE from the control-row values via rfi_propose_bands, so the
    % highlighted bands update as the thresholds/gap are adjusted. The season
    % spectra are method-independent and season-wide, so they live in the
    % Static folder (cfg.input_dir), not a per-run dir. NL/L band-finding is
    % PSD-excess only (the SK gate + threshold controls are disabled), so the
    % explorer matches compute_rfi_spectrum's per-dataset gating.
    info = V.U.rfi_dataset_info(V);
    is_signal = info.use_sk;
    S.rfi_usesk.Enable = matlab.lang.OnOffSwitchState(is_signal);
    S.rfi_sk.Enable    = matlab.lang.OnOffSwitchState(is_signal);

    csvp = fullfile(S.rfi_dir, info.spectrum);
    if ~isfile(csvp)
        % Clear any bands left over from a previously-selected RFI set so a
        % subsequent Export cannot write the wrong dataset's bands under this
        % set's rfi_bands_proposed<sfx>.csv (they are only repopulated on a
        % successful load below).
        S.rfi_bands = zeros(0,2);  S.rfi_src = strings(0,1);  S.rfi_chan = strings(0,1);
        show_msg(['Needs ' info.spectrum ' in ' S.rfi_dir ...
                  ' — set run_rfi = true and run BrundageSoOp.']);
        S.lbl_rfi.Text = '— bands';
        return;
    end
    T = readtable(csvp);
    f = T.freq_hz / 1e6;

    % Live band-finder params: thresholds/gap from the controls, the rest
    % from cfg defaults. SK is forced off for NL/L (PSD-excess only).
    p = struct();
    p.excess_db     = S.rfi_excess.Value;
    p.sk_threshold  = S.rfi_sk.Value;
    p.use_sk        = is_signal && logical(S.rfi_usesk.Value);
    p.merge_khz     = S.rfi_gap.Value;
    p.env_khz       = cfgdef('rfi_env_khz', 1000);
    p.edge_guard_hz = cfgdef('rfi_edge_guard_khz', 150) * 1e3;
    p.protect_hz    = cfgdef('rfi_protect_hz', 50e3);
    p.min_width_khz = cfgdef('rfi_min_width_khz', 0.3);
    p.band_pad_khz  = cfgdef('rfi_band_pad_khz', 1);
    p.center_hz     = cfg.freq_hz;
    [bands_hz, src, chan] = rfi_propose_bands(T.freq_hz, T.psd_db_ch0, T.psd_db_ch1, ...
                                              T.sk_ch0, T.sk_ch1, p);
    S.rfi_bands = bands_hz;  S.rfi_src = src;  S.rfi_chan = chan;   % for Export
    S.lbl_rfi.Text = sprintf('%s: %d bands (%d ch0 / %d ch1 / %d both)', info.name, ...
        size(bands_hz,1), nnz(chan=="ch0"), nnz(chan=="ch1"), nnz(chan=="both"));
    bm = bands_hz / 1e6;

    % Display envelope (same movmedian width the finder uses; shared cfg.rfi_env_khz).
    df = T.freq_hz(2) - T.freq_hz(1);
    ew = rfi_env_window(p.env_khz, df);
    env0 = movmedian(T.psd_db_ch0, ew);  env1 = movmedian(T.psd_db_ch1, ew);

    % Occupancy/coherence (rfi_spectrum.csv columns) are diagnostic-only —
    % rfi_propose_bands gates on PSD-excess-above-envelope + spectral
    % kurtosis only — so they're left off this figure.
    tl  = tiledlayout(S.panel, 2, 1, 'TileSpacing', 'compact');
    ax1 = nexttile(tl); hold(ax1,'on'); grid(ax1,'on');
    h0 = plot(ax1, f, T.psd_db_ch0, 'b'); h1 = plot(ax1, f, T.psd_db_ch1, 'r');
    plot(ax1, f, env0, 'b--'); plot(ax1, f, env1, 'r--');
    ylabel(ax1,'Mean PSD (dB)');
    title(ax1, sprintf('Season RFI spectrum (%s) — %d bands (shaded by source)', ...
        info.name, size(bm,1)));
    H = rfi_shade_src(ax1, bm, src);
    legend([H h0 h1], {'psd','sk','both','ch0','ch1'}, 'Location','best');

    ax2 = nexttile(tl); hold(ax2,'on'); grid(ax2,'on');
    s0 = plot(ax2, f, T.sk_ch0, 'b'); s1 = plot(ax2, f, T.sk_ch1, 'r');
    yline(ax2, 1, 'k-');
    if p.use_sk, yline(ax2, p.sk_threshold, 'k--'); end
    ylabel(ax2,'Spectral kurtosis'); xlabel(ax2,'RF frequency (MHz)');
    rfi_shade_src(ax2, bm, src);
    legend([s0 s1], {'ch0','ch1'}, 'Location','best');
    linkaxes([ax1 ax2], 'x');
end


function H = rfi_shade_src(ax, bm, src)
    % Shade bands colored by source (psd=orange, sk=purple, both=red),
    % drawn after the data at the axis's current y-limits (so autoscaling is
    % untouched), HandleVisibility off. Returns [psd sk both] NaN-patch
    % proxies for the legend. patch() (not xregion) for r2023b on the HPC.
    cols = struct('psd',[1 0.7 0.3], 'sk',[0.6 0.4 0.8], 'both',[0.9 0.4 0.4]);
    yl = ylim(ax);
    for i = 1:size(bm,1)
        c = cols.(char(src(i)));
        patch(ax, [bm(i,1) bm(i,2) bm(i,2) bm(i,1)], [yl(1) yl(1) yl(2) yl(2)], ...
              c, 'EdgeColor','none', 'FaceAlpha',0.45, 'HandleVisibility','off');
    end
    ylim(ax, yl);
    H = [patch(ax, NaN(1,4), NaN(1,4), cols.psd,  'EdgeColor','none'), ...
         patch(ax, NaN(1,4), NaN(1,4), cols.sk,   'EdgeColor','none'), ...
         patch(ax, NaN(1,4), NaN(1,4), cols.both, 'EdgeColor','none')];
end


function rfi_filter_psd(V, ~)
    S = V;
    show_msg = @(varargin) V.U.show_msg(V, varargin{:});
    % What the notch + linear-interpolation excision does to the selected
    % 'RFI set' (Signal/NL/L) season mean PSD — computed from the unfiltered
    % rfi_spectrum<sfx>.csv + that set's curated bands (Signal -> cfg.rfi_bands,
    % NL -> cfg.rfi_bands_nl, L -> cfg.rfi_bands_l; no HPC product needed).
    % Method-independent; reads from Static (cfg.input_dir). Only the 'RFI set'
    % selector is live on this view — the threshold/gap/SK/Export controls are
    % disabled (this view shows curated bands, it does not propose them).
    info = V.U.rfi_dataset_info(V);
    csvp = fullfile(S.rfi_dir, info.spectrum);
    if ~isfile(csvp)
        show_msg(['Needs ' info.spectrum ' in ' S.rfi_dir ...
                  ' — set run_rfi = true and run BrundageSoOp.']);
        return;
    end
    bands = rfi_curated_bands(V.cfg, info.name);
    if isempty(bands)
        show_msg(['No curated ' info.curated ' bands loaded — export from the ' ...
                  'RFI explorer and load them to see the filter effect.']);
        return;
    end
    T  = readtable(csvp);
    f  = T.freq_hz;  fM = f / 1e6;

    % Notch + interpolation effect on the season PSD: flagged bands are
    % replaced by interpolation in LINEAR POWER across the band edges (a
    % closer proxy for the complex-spectrum excision than dB-domain
    % interpolation), pulling the RFI spikes down to the local floor.
    p0f = notch_psd_lin(f, T.psd_db_ch0, bands);
    p1f = notch_psd_lin(f, T.psd_db_ch1, bands);

    tl  = tiledlayout(S.panel, 2, 1, 'TileSpacing', 'compact');
    ax1 = nexttile(tl); hold(ax1,'on'); grid(ax1,'on');
    b0 = plot(ax1, fM, T.psd_db_ch0, 'Color', [0.4 0.6 1.0 0.35]);
    b1 = plot(ax1, fM, T.psd_db_ch1, 'Color', [1.0 0.5 0.3 0.35]);
    hb = band_shade(ax1, bands/1e6);
    ylabel(ax1, 'Season PSD (dB)');
    % After-traces are shown in the bottom tile only — this tile marks just
    % the proposed bands against the unfiltered season PSD.
    title(ax1, sprintf('Notch + interp bands over the unfiltered season PSD (%s)', info.name));
    legend([hb b0 b1], {'bands','ch0 before','ch1 before'}, 'Location','best');

    % Bottom tile: the filtered (after) PSD alone — those bins are replaced
    % outright, so there's no excised region left to shade in the after-trace.
    ax2 = nexttile(tl); hold(ax2,'on'); grid(ax2,'on');
    plot(ax2, fM, p0f, 'b'); plot(ax2, fM, p1f, 'r');
    ylabel(ax2, 'Season PSD (dB), filtered'); xlabel(ax2, 'RF frequency (MHz)');
    title(ax2, 'Notch Filtered w/ linear Interpolation');
    legend(ax2, {'ch0','ch1'}, 'Location','best');
    linkaxes([ax1 ax2], 'xy');
end


function bands = rfi_curated_bands(cfg, name)
    % Curated band list for an 'RFI set' (Signal/NL/L), empty if not loaded.
    switch char(name)
        case 'NL', fld = 'rfi_bands_nl';
        case 'L',  fld = 'rfi_bands_l';
        otherwise, fld = 'rfi_bands';
    end
    if isfield(cfg, fld) && ~isempty(cfg.(fld)), bands = cfg.(fld); else, bands = []; end
end


function pf = notch_psd_lin(f, p, bands)
    % Approximate the notch+interp effect on the season PSD: replace each
    % band's bins by interpolating in LINEAR POWER across the band edges
    % (un-dB -> interp -> re-dB). The real excision interpolates the complex
    % spectrum per segment, so |.|^2 lives in power, not dB — interpolating
    % in power is the closer proxy. The exact season mean would need a
    % re-run of compute_rfi_spectrum (the per-segment complex spectra are
    % not recoverable from this averaged PSD).
    pf = p;  n = numel(f);
    for i = 1:size(bands,1)
        lo = min(bands(i,1), bands(i,2));  hi = max(bands(i,1), bands(i,2));
        idx = find(f >= lo & f <= hi);
        if isempty(idx), continue; end
        a = idx(1);  b = idx(end);
        le = max(a-1, 1);  re = min(b+1, n);
        if re <= le, continue; end
        w   = (f(a:b) - f(le)) / (f(re) - f(le));
        plo = 10^(p(le)/10);  phi = 10^(p(re)/10);   % dB -> linear power
        pf(a:b) = 10*log10((1 - w) * plo + w * phi); % interp in power -> dB
    end
end


function h = band_shade(ax, bm)
    % Light single-color shading for the excision bands; returns a NaN-patch
    % proxy for one legend entry (patch() for r2023b).
    yl = ylim(ax);
    for i = 1:size(bm,1)
        patch(ax, [bm(i,1) bm(i,2) bm(i,2) bm(i,1)], [yl(1) yl(1) yl(2) yl(2)], ...
              [0.85 0.85 0.6], 'EdgeColor','none', 'FaceAlpha',0.4, 'HandleVisibility','off');
    end
    ylim(ax, yl);
    h = patch(ax, NaN(1,4), NaN(1,4), [0.85 0.85 0.6], 'EdgeColor','none');
end

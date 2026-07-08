function C = soop_viewer_callbacks()
% UI callbacks + render dispatch for BrundageSoOp_viewer.
    C.on_reload = @on_reload;
    C.on_method_change = @on_method_change;
    C.on_range_change = @on_range_change;
    C.set_range = @set_range;
    C.rebuild_caplist = @rebuild_caplist;
    C.step_cap = @step_cap;
    C.on_export = @on_export;
    C.on_set_labels = @on_set_labels;
    C.refresh = @refresh;
    C.unbusy = @unbusy;
    C.render_now = @render_now;
    C.update_info = @update_info;
    C.on_rfi_export = @on_rfi_export;
    C.on_gap_slider_changing = @on_gap_slider_changing;
    C.on_gap_slider = @on_gap_slider;
    C.on_gap_field = @on_gap_field;
end


function on_reload(V)
    S = V;
    load_csvs = @(varargin) V.D.load_csvs(V, varargin{:});
    rebuild_caplist = @(varargin) V.CB.rebuild_caplist(V, varargin{:});
    refresh = @(varargin) V.CB.refresh(V, varargin{:});
    load_csvs();
    S.cache.key = "";
    S.calib_base_cache.dir = "";   % force re-read of base calib for anchoring
    S.calib_notch_cache.dir = "";  % force re-read of notch calib for overlay
    rebuild_caplist(false);
    refresh();
end


function on_method_change(V)
    S = V;
    is_compare_mode = @(varargin) V.U.is_compare_mode(V, varargin{:});
    is_chaincal_mode = @(varargin) V.U.is_chaincal_mode(V, varargin{:});
    load_csvs = @(varargin) V.D.load_csvs(V, varargin{:});
    rebuild_caplist = @(varargin) V.CB.rebuild_caplist(V, varargin{:});
    refresh = @(varargin) V.CB.refresh(V, varargin{:});
    % Switch the active product dir to the selected RFI method's set and
    % reload. Renders show their own 'Needs ...' message if that method's
    % products are absent (e.g. you haven't generated/copied that set yet).
    % cfg.data_dir (raw captures) and the season RFI spectrum (base dir) are
    % unaffected. The synthetic 'base vs notch' entry keeps cfg.out_dir on
    % base (so every non-Calib view stays on base) and lets render_calib
    % overlay the notch series. The 'notch + chain-cal' entry pins the
    % notch dir; the chain-cal delta is applied at render time in the
    % candidate views only.
    if is_compare_mode()
        V.cfg.out_dir = S.base_out_dir;
    elseif is_chaincal_mode()
        V.cfg.out_dir = S.notch_out_dir;
    else
        V.cfg.out_dir = S.dd_method.Value;
    end
    load_csvs();
    S.cache.key = "";
    rebuild_caplist(false);
    refresh();
end


function on_range_change(V)
    rebuild_caplist = @(varargin) V.CB.rebuild_caplist(V, varargin{:});
    refresh = @(varargin) V.CB.refresh(V, varargin{:});
    rebuild_caplist(false);
    refresh();
end


function set_range(V, mode)
    S = V;
    tcol = V.U.tcol;
    rebuild_caplist = @(varargin) V.CB.rebuild_caplist(V, varargin{:});
    refresh = @(varargin) V.CB.refresh(V, varargin{:});
    % Default the pickers to the union span of both CSVs (or today).
    ts = [tcol(S.L1); tcol(S.CAL)];
    if isempty(ts), ts = datetime('today'); end
    switch mode
        case 'full', S.dp1.Value = dateshift(min(ts), 'start', 'day');
        case 'week', S.dp1.Value = dateshift(max(ts), 'start', 'day') - days(6);
    end
    S.dp2.Value = dateshift(max(ts), 'start', 'day');
    rebuild_caplist(false);
    refresh();
end


function rebuild_caplist(V, reset_sel)
    S = V;
    cfg = V.cfg;
    M = V.M;
    CAP_PATTERNS = V.CAP_PATTERNS;
    range_bounds = @(varargin) V.U.range_bounds(V, varargin{:});
    % Populate the capture dropdown from data_dir, filtered to the range.
    prev_val = '';
    if ~isempty(S.dd_cap.ItemsData), prev_val = S.dd_cap.Value; end
    S.dd_cap.ItemsData = {};   % detach before resizing Items

    if ~isfolder(cfg.data_dir)
        S.dd_cap.Items = {'(data_dir not found)'};
        S.lbl_cap.Text = sprintf('%s not reachable — plug in the drive?', cfg.data_dir);
        return;
    end
    pat = CAP_PATTERNS.(S.dd_ctype.Value);
    % Recursive glob: '**' matches zero or more folder levels, so this finds
    % both the new cryosoop per-run subfolders (<data_root>/<YYYYMMDD>/
    % <HHMMSS>/) and the old flat single-folder season in one pass. Record each
    % discovered capture's actual folder (base names are globally unique) so
    % rr_load_capture reads _ch0/_ch1 from the right place, not cfg.data_dir.
    d = dir(fullfile(cfg.data_dir, '**', pat));
    for i = 1:numel(d)
        S.cap_folders(char(erase(d(i).name, '_ch0.dat'))) = d(i).folder;
    end
    bases = string(erase({d.name}', '_ch0.dat'));
    ts = M.base_ts(bases);
    [t0, t1] = range_bounds();
    keep = ts >= t0 & ts < t1;
    bases = bases(keep);  ts = ts(keep);
    [~, order] = sort(ts);
    bases = bases(order);

    n_total = numel(bases);
    cap = 1000;
    note = '';
    if n_total > cap
        bases = bases(1:cap);
        note = sprintf(' (first %d of %d — narrow the date range)', cap, n_total);
    end
    if isempty(bases)
        S.dd_cap.Items = {'(no captures in range)'};
    else
        items = cellstr(bases);
        S.dd_cap.Items     = items;
        S.dd_cap.ItemsData = items;
        if ~reset_sel && ismember(prev_val, items)
            S.dd_cap.Value = prev_val;
        elseif reset_sel && ~isempty(prev_val) && ~startsWith(prev_val, '(')
            % Capture-type switch (NL<->L<->Signal): select the new-type
            % capture closest in time to the one that was on screen, so the
            % view stays time-aligned instead of jumping to the earliest in
            % range. Names never match across types, so the ismember branch
            % above can't handle this.
            prev_ts = M.base_ts(string(prev_val));
            [~, kmin] = min(abs(M.base_ts(string(items)) - prev_ts));
            S.dd_cap.Value = items{kmin};
        else
            S.dd_cap.Value = items{1};
        end
    end
    S.lbl_cap.Text = sprintf('%d %s captures in range%s', ...
                             n_total, S.dd_ctype.Value, note);
end


function step_cap(V, delta)
    S = V;
    refresh = @(varargin) V.CB.refresh(V, varargin{:});
    items = S.dd_cap.ItemsData;
    if isempty(items), return; end
    k = find(strcmp(S.dd_cap.Value, items), 1);
    k = min(max(k + delta, 1), numel(items));
    S.dd_cap.Value = items{k};
    refresh();
end


function on_export(V)
    S = V;
    cfg = V.cfg;
    PLOT_INFO = V.PLOT_INFO;
    plot_uses_method = V.U.plot_uses_method;
    dataset_label = @(varargin) V.U.dataset_label(V, varargin{:});
    plot_uses_domain = V.U.plot_uses_domain;
    domain_mode = @(varargin) V.U.domain_mode(V, varargin{:});
    kind = S.dd_plot.Value;
    % Slug: lowercase, every run of non-alphanumeric chars (':', ' ', '(',
    % '&', '/', em dash, ...) -> single '_', trimmed. Keeps the filename
    % filesystem-safe: "Calib: Power ratio (NS / L)" -> "calib_power_ratio_ns_l",
    % "Raw: PSD (ch0 & ch1)" -> "raw_psd_ch0_ch1".
    slug = regexprep(lower(char(kind)), '[^a-z0-9]+', '_');
    slug = regexprep(slug, '^_+|_+$', '');
    % Context: capture name for Raw: views; date range otherwise
    info = PLOT_INFO(strcmp({PLOT_INFO.name}, kind));
    if info.uses_cap && ~isempty(S.dd_cap.ItemsData) && ...
            ~startsWith(S.dd_cap.Value, '(')
        ctx = string(S.dd_cap.Value);
    else
        ctx = string(S.dp1.Value, 'yyyyMMdd') + "_" + ...
              string(S.dp2.Value, 'yyyyMMdd');
    end
    % Self-documenting dataset tag for plots where the Dataset selection
    % matters (product-CSV + live-filtered raw views), so base/notch
    % exports are distinguishable by name, not just by their L1/L1_notch
    % folder.
    ds = "";
    if plot_uses_method(kind)
        ds = string(regexprep(lower(dataset_label()), '[^a-z0-9]+', '_')) + "__";
    end
    if plot_uses_domain(kind)
        ds = ds + string(domain_mode()) + "__";   % sinc/fd/fd_muos/compare tag
    end
    % Figures save to cfg.fig_dir (one stable folder per dated run, shared
    % across base/notch — the dataset tag above distinguishes them),
    % not cfg.out_dir, which switches between L1/L1_notch as the
    % Dataset dropdown changes. Falls back to cfg.out_dir for callers that
    % launch the viewer with an older cfg lacking fig_dir.
    if isfield(cfg, 'fig_dir') && ~isempty(cfg.fig_dir)
        fig_dir = cfg.fig_dir;
    else
        fig_dir = cfg.out_dir;
    end
    if ~isfolder(fig_dir), mkdir(fig_dir); end
    fname = fullfile(fig_dir, ...
            string(datetime('now', 'Format', 'yyyyMMdd_HHmmss')) + ...
            "__" + slug + "__" + ds + ctx + ".png");
    exportgraphics(S.panel, fname, 'Resolution', 300);
    S.lbl_cap.Text = "Saved " + fname;
end


function on_set_labels(V)
    S = V;
    refresh = @(varargin) V.CB.refresh(V, varargin{:});
    % Capture the three label fields as overrides for the current plot, then
    % re-render: the render restores all auto labels, after which
    % apply_overrides re-applies whichever fields are non-empty — so
    % clearing one field cleanly restores just that one auto label.
    S.ov_title     = S.ef_title.Value;
    S.ov_xlabel    = S.ef_xlabel.Value;
    S.ov_ylabel    = S.ef_ylabel.Value;
    S.ov_plot_kind = S.dd_plot.Value;
    refresh();
end


function refresh(V)
    S = V;
    render_now = @(varargin) V.CB.render_now(V, varargin{:});
    unbusy = @(varargin) V.CB.unbusy(V, varargin{:});
    % Re-entrancy guard. Building a plot creates a uiprogressdlg, whose
    % internal drawnow lets a queued Prev/Next/dropdown callback interrupt
    % the in-progress render. Without this, the interrupting (newer)
    % selection renders first and then the original (older) render resumes
    % and overwrites it — so the displayed capture lags the control. Here
    % we coalesce: a refresh that arrives mid-render only flags 'pending',
    % and the active render re-runs once on exit against the latest state.
    % This covers every control and plot type, not just Prev/Next on the
    % cross-correlation view.
    if S.busy
        S.pending = true;
        return;
    end
    S.busy = true;
    restore = onCleanup(@() unbusy());   % clears the flag even on error
    render_now();
    while S.pending
        S.pending = false;
        render_now();
    end
end


function unbusy(V)
    S = V;
    S.busy = false;
end


function render_now(V)
    S = V;
    gl = V.gl;
    PLOT_INFO = V.PLOT_INFO;
    update_info = @(varargin) V.CB.update_info(V, varargin{:});
    apply_overrides = @(varargin) V.U.apply_overrides(V, varargin{:});
    show_msg = @(varargin) V.U.show_msg(V, varargin{:});
    plot_uses_method = V.U.plot_uses_method;
    plot_uses_domain = V.U.plot_uses_domain;
    kind = S.dd_plot.Value;
    info = PLOT_INFO(strcmp({PLOT_INFO.name}, kind));

    % Reset per-plot label-text overrides when the plot type changes (a
    % title/x/y label is plot-specific). Font sizes and legend placement
    % are global style and intentionally persist.
    if ~strcmp(kind, S.ov_plot_kind)
        S.ov_title = '';  S.ov_xlabel = '';  S.ov_ylabel = '';
        S.ov_plot_kind = kind;
        S.ef_title.Value = '';  S.ef_xlabel.Value = '';  S.ef_ylabel.Value = '';
    end

    % Grey out controls that don't affect this plot (Enable, not Visible,
    % so the layout never reflows). Date pickers stay live for every plot
    % — they also filter the raw capture list.
    S.dd_agg.Enable = matlab.lang.OnOffSwitchState(info.uses_agg);
    set([S.dd_ctype, S.dd_cap, S.btn_prev, S.btn_next], ...
        'Enable', matlab.lang.OnOffSwitchState(info.uses_cap));

    % Dataset (RFI method) selector affects product-CSV plots (it switches
    % cfg.out_dir) AND the live-filtered raw views (PSD, Spectrogram), where
    % the selected method is applied to the displayed capture per
    % welch_psd_filtered / spectro_filtered. The other 'Raw:' views read raw
    % captures / the base-dir season spectrum and ignore the method, so
    % disable it there.
    S.dd_method.Enable = matlab.lang.OnOffSwitchState(plot_uses_method(kind));

    % Phase domain (sinc / fd / freq_muos / compare) applies to the phase &
    % amplitude product-CSV plots; greyed out elsewhere.
    S.dd_domain.Enable = matlab.lang.OnOffSwitchState(plot_uses_domain(kind));

    % Units switch is only meaningful for the NS/L power-ratio view.
    is_yfactor = strcmp(kind, 'Calib: Power ratio (NS / L)');
    S.units_row.Visible = matlab.lang.OnOffSwitchState(is_yfactor);

    % Gain Norm/Raw switch is only meaningful for the gain-drift view.
    is_gain = strcmp(kind, 'Calib: Gain drift (G_De, G_Re)');
    S.gain_row.Visible = matlab.lang.OnOffSwitchState(is_gain);

    % SNR Linear/dB switch applies to the two SNR views (Eq. 37 / Eq. 39).
    is_snr = strcmp(kind, 'Calib: SNR, load (SNR_DL, SNR_RL)') || ...
             strcmp(kind, 'Calib: SNR, noise source (SNR_DNS, SNR_RNS)');
    S.snr_row.Visible = matlab.lang.OnOffSwitchState(is_snr);

    % Log/Linear y-scale switch applies only to the calib cross-correlation
    % amplitude view.
    is_ampscale = strcmp(kind, 'Calib: Cross-correlation amplitudes (C_RDL, C_RDNS)');
    S.ampscale_row.Visible = matlab.lang.OnOffSwitchState(is_ampscale);

    % Detrend checkbox applies to the L1 and L2 diurnal phase plots.
    is_diurnal = strcmp(kind, 'L1: Diurnal phase pattern') || ...
                 startsWith(kind, 'L2: Diurnal');
    S.detrend_row.Visible = matlab.lang.OnOffSwitchState(is_diurnal);

    % Weather-overlay toggles (snow depth + the two temperatures) apply only to
    % the L2: Candidates views, which now carry the optional overlay.
    is_cand = startsWith(kind, 'L2: Candidates');
    set([S.cb_depth, S.cb_airtc, S.cb_tempc], ...
        'Visible', matlab.lang.OnOffSwitchState(is_cand));

    % Expand the RFI explorer control row only for the season RFI plot.
    is_rfi = strcmp(kind, 'Raw: Season RFI spectrum');
    rh = gl.RowHeight;  rh{3} = is_rfi * 40;  gl.RowHeight = rh;
    S.rfi_row.Visible = matlab.lang.OnOffSwitchState(is_rfi);

    S.last_n = 0;
    delete(S.panel.Children);
    try
        if info.uses_cap
            soop_viewer_render_raw(V, kind);
        elseif strcmp(kind, 'Raw: Season RFI spectrum')
            soop_viewer_render_rfi(V, kind);
        elseif startsWith(kind, 'Raw: Season PSD —')
            soop_viewer_render_rfi(V, kind);
        elseif startsWith(kind, 'Lag:')
            soop_viewer_render_l1(V, kind);
        elseif startsWith(kind, 'Calib:')
            soop_viewer_render_calib(V, kind);
        elseif startsWith(kind, 'L2:')
            soop_viewer_render_l2(V, kind);
        else   % 'L1: *' and 'Data availability' read the L1 CSV
            soop_viewer_render_l1(V, kind);
        end
    catch ME
        show_msg(ME.message);
    end
    update_info(info);
    apply_overrides();
end


function update_info(V, info)
    S = V;
    src_desc = V.U.src_desc;
    open_fun = V.U.open_fun;
    % Live settings block — re-built on every refresh, so it cannot go
    % stale, and Export PNG captures it alongside the plot.
    agg_txt = S.dd_agg.Value;
    if ~info.uses_agg, agg_txt = 'n/a for this plot'; end
    lines = "Plot: " + info.name;
    lines(end+1) = "Aggregation: " + agg_txt;
    lines(end+1) = "Date range: " + string(S.dp1.Value) + " to " + string(S.dp2.Value);
    if info.uses_cap
        lines(end+1) = "Capture: " + string(S.dd_cap.Value) + ...
                       " (" + string(S.dd_ctype.Value) + ")";
    else
        lines(end+1) = "Rows in range: " + S.last_n;
    end
    lines(end+1) = "L1 CSV: "    + src_desc(S.L1);
    lines(end+1) = "Calib CSV: " + src_desc(S.CAL);
    lines(end+1) = "L2 CSV: "    + src_desc(S.L2);
    S.lbl_settings.Value = char(join(lines, newline));
    S.lbl_expl.Value     = info.expl;

    % Math formula + clickable link(s) to the BrundageSoOp_fun function(s).
    S.lbl_math.Value = char(info.math);
    delete(S.src_box.Children);
    fns = info.fcn(strlength(info.fcn) > 0);
    if isempty(fns)
        S.src_box.RowHeight = {22};
        uilabel(S.src_box, 'Text', '(inline — no shared function)', ...
                'FontAngle', 'italic');
    else
        S.src_box.RowHeight = repmat({22}, numel(fns), 1);
        for kf = 1:numel(fns)
            nm = fns(kf);
            uihyperlink(S.src_box, 'Text', char(nm), 'URL', '', ...
                'HyperlinkClickedFcn', @(~,~) open_fun(nm));
        end
    end
end


function on_rfi_export(V)
    S = V;
    % Write the currently-highlighted bands to rfi_bands_proposed.csv and
    % print a paste-ready cfg.rfi_bands snippet to the console.
    if isempty(S.rfi_bands)
        uialert(S.fig, 'No bands at the current thresholds.', 'RFI export');
        return;
    end
    bands = S.rfi_bands;  src = S.rfi_src;  chan = S.rfi_chan;
    Bt = table(bands(:,1), bands(:,2), src, chan, ...
               'VariableNames', {'f_lo_hz','f_hi_hz','source','channel'});
    outp = fullfile(S.rfi_dir, 'rfi_bands_proposed.csv');
    writetable(Bt, outp);
    fprintf('\n%% --- %d RFI bands -> %s ---\n', size(bands,1), outp);
    fprintf('cfg.rfi_bands = [ ...\n');
    for i = 1:size(bands,1)
        fprintf('    %.0f %.0f; ...   %% %s, %s\n', bands(i,1), bands(i,2), src(i), chan(i));
    end
    fprintf('];\n');
    uialert(S.fig, sprintf(['Exported %d bands to rfi_bands_proposed.csv. ' ...
            'A cfg.rfi_bands snippet was printed to the console.'], size(bands,1)), ...
            'RFI bands exported', 'Icon', 'success');
end


function on_gap_slider_changing(V, e)
    S = V;
    % Live during drag: update the numeric readout only (no re-derive).
    S.rfi_gap_ef.Value = round(e.Value);
end


function on_gap_slider(V)
    S = V;
    refresh = @(varargin) V.CB.refresh(V, varargin{:});
    % Committed drag: snap slider + field to the rounded integer, re-derive.
    v = round(S.rfi_gap.Value);
    S.rfi_gap.Value = v;  S.rfi_gap_ef.Value = v;  refresh();
end


function on_gap_field(V)
    S = V;
    refresh = @(varargin) V.CB.refresh(V, varargin{:});
    % Typed entry: validate, clamp to [0 200], sync the slider, re-derive.
    v = S.rfi_gap_ef.Value;
    if isempty(v) || ~isfinite(v), v = S.rfi_gap.Value; end
    v = min(max(round(v), 0), 200);
    S.rfi_gap_ef.Value = v;  S.rfi_gap.Value = v;  refresh();
end

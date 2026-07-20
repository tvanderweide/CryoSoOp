function U = soop_viewer_util()
% UI/label/formatting helpers for BrundageSoOp_viewer. Returns a struct of
% handles (same idiom as rfi_excise/BrundageSoOp_fun); each takes V first
% (except pure helpers style_legend/wrap_deg/domain_color/plot_uses_*/tcol/
% parse_tod/tod_daily_idx/phoff_measure/phoff_prep/phoff_title/src_desc/
% open_fun).
    U.range_bounds = @range_bounds;
    U.apply_overrides = @apply_overrides;
    U.style_legend = @style_legend;
    U.show_msg = @show_msg;
    U.looks_curve_plot = @looks_curve_plot;
    U.is_compare_mode = @is_compare_mode;
    U.is_chaincal_mode = @is_chaincal_mode;
    U.wrap_deg = @wrap_deg;
    U.cfgdef = @cfgdef;
    U.dropdown_method = @dropdown_method;
    U.dataset_label = @dataset_label;
    U.dataset_suffix = @dataset_suffix;
    U.domain_mode = @domain_mode;
    U.plot_uses_domain = @plot_uses_domain;
    U.domain_suffix = @domain_suffix;
    U.domain_color = @domain_color;
    U.domain_cols = @domain_cols;
    U.domain_col1 = @domain_col1;
    U.plot_domain_series = @plot_domain_series;
    U.raw_cap_title = @raw_cap_title;
    U.plot_uses_method = @plot_uses_method;
    U.prep_excis = @prep_excis;
    U.rfi_dataset_info = @rfi_dataset_info;
    U.plot_series = @plot_series;
    U.tcol = @tcol;
    U.parse_tod = @parse_tod;
    U.tod_daily_idx = @tod_daily_idx;
    U.phoff_measure = @phoff_measure;
    U.phoff_prep = @phoff_prep;
    U.phoff_title = @phoff_title;
    U.src_desc = @src_desc;
    U.open_fun = @open_fun;
end


function [t0, t1] = range_bounds(V)
    S = V;
    t0 = S.dp1.Value;  t1 = S.dp2.Value + days(1);   % inclusive end day
    if isnat(t0), t0 = datetime(-inf, 'ConvertFrom', 'datenum'); end
    if isnat(t1), t1 = datetime( inf, 'ConvertFrom', 'datenum'); end
end


function apply_overrides(V)
    S = V;
    dataset_suffix = @(varargin) V.U.dataset_suffix(V, varargin{:});
    style_legend = V.U.style_legend;
    % Re-applies sidebar styling after a render (or on a live style change).
    % Text overrides target the primary (top) axes and only for the plot
    % they were set on; font sizes and legend settings apply to every
    % axes/legend in the panel and persist across plots. The Radar Cal map
    % views draw in geographic axes (Type 'geoaxes', not 'axes'), collected
    % separately here so they get styled too.
    axs  = findobj(S.panel, 'Type', 'axes');
    gaxs = findobj(S.panel, 'Type', 'geoaxes');
    if isempty(axs) && isempty(gaxs), return; end

    % Label-text overrides (primary axes, current plot only). TeX
    % interpreter so SNR_L / SNR_{RNS} subscripts, ^ superscripts, and
    % \rho-style Greek render (matches the built-in labels). A literal
    % underscore must be escaped as \_.
    has_title_override = strcmp(S.dd_plot.Value, S.ov_plot_kind) && ~isempty(S.ov_title);
    if strcmp(S.dd_plot.Value, S.ov_plot_kind)
        if ~isempty(axs)   % first-created = top tile / sole axes
            axp = axs(end);
        else
            axp = gaxs(end);
        end
        % Raw: Spectrogram carries its descriptive title at the figure
        % (tiledlayout) level — its two axes hold only static per-channel
        % labels ('CH0 (Direct)' / 'CH1 (Reflected)'). Route the Title
        % override to the figure title so it never clobbers those subplot
        % labels. Every other plot keeps the title on its top/sole axes.
        if has_title_override
            if strcmp(S.dd_plot.Value, 'Raw: Spectrogram')
                tls = findobj(S.panel, 'Type', 'tiledlayout');
                if ~isempty(tls), title(tls(1), S.ov_title, 'Interpreter', 'tex'); end
            else
                title(axp, S.ov_title, 'Interpreter', 'tex');
            end
        end
        if isa(axp, 'matlab.graphics.axis.GeographicAxes')
            % Geographic axes have lat/lon edge labels instead of X/Y
            % labels — route the sidebar X label to longitude (horizontal
            % axis) and Y label to latitude (vertical axis).
            if ~isempty(S.ov_xlabel)
                axp.LongitudeLabel.String      = S.ov_xlabel;
                axp.LongitudeLabel.Interpreter = 'tex';
            end
            if ~isempty(S.ov_ylabel)
                axp.LatitudeLabel.String      = S.ov_ylabel;
                axp.LatitudeLabel.Interpreter = 'tex';
            end
        else
            if ~isempty(S.ov_xlabel), xlabel(axp, S.ov_xlabel, 'Interpreter', 'tex'); end
            if ~isempty(S.ov_ylabel), ylabel(axp, S.ov_ylabel, 'Interpreter', 'tex'); end
        end
    end

    % Tag product-CSV plots (Calib/L1/L2/Data availability) with the active
    % Dataset so base/notch are distinguishable on screen and in
    % exports. The live-filtered raw views already name the filter in their
    % own title, so they are excluded. The tag is a compact ' w/ Notch'
    % suffix (base adds nothing), matching the raw-view
    % convention (raw_cap_title) and minimizing title clutter. Idempotent:
    % strip any prior tag — current suffix or the legacy '— dataset: …' form
    % — before re-appending, so the standalone style-change calls above
    % (font/legend) don't stack it. Title stays char here (raw multi-line
    % titles excluded). Skipped entirely when a sidebar title override is
    % active for this plot — that field is meant to be the WHOLE title.
    % Also skipped for the map views (plot_uses_method false): they are
    % forward models with no base/notch dataset, so the tag would mislead.
    pk = S.dd_plot.Value;
    if ~isempty(axs) && plot_uses_method(pk) && ~startsWith(pk, 'Raw:') && ~has_title_override
        axp = axs(end);
        t0  = char(axp.Title.String);
        t0  = regexprep(t0, '\s*—\s*dataset:.*$', '');
        t0  = regexprep(t0, '(\s*—\s*base vs notch)+\s*$', '');
        t0  = regexprep(t0, '\s+w/\s+Notch\s*$', '');
        axp.Title.String = [t0 dataset_suffix()];
    end

    % Font sizes (all axes). The axes FontSize drives the tick labels; set
    % it first, then pin Title / X / Y label sizes explicitly so those stay
    % independent of the tick size (once set, their FontSizeMode is manual).
    fst = S.sp_fs_title.Value;  fsl = S.sp_fs_label.Value;
    fsa = S.sp_fs_tick.Value;
    for k = 1:numel(axs)
        axs(k).FontSize        = fsa;
        axs(k).Title.FontSize  = fst;
        axs(k).XLabel.FontSize = fsl;
        axs(k).YLabel.FontSize = fsl;
    end
    for k = 1:numel(gaxs)
        gaxs(k).FontSize                 = fsa;
        gaxs(k).Title.FontSize           = fst;
        gaxs(k).LatitudeLabel.FontSize   = fsl;
        gaxs(k).LongitudeLabel.FontSize  = fsl;
    end
    % Raw: Spectrogram's descriptive title is the figure (tiledlayout) title,
    % not an axes title (the axes hold static CH0/CH1 labels) — so the Title
    % font-size knob must drive the tiledlayout title for it to take effect.
    % The CH0/CH1 subplot labels are kept 6 pt smaller than the main title,
    % so they read as secondary headings (overrides the loop's fst above).
    if strcmp(S.dd_plot.Value, 'Raw: Spectrogram')
        tls = findobj(S.panel, 'Type', 'tiledlayout');
        if ~isempty(tls), tls(1).Title.FontSize = fst; end
        for k = 1:numel(axs)
            axs(k).Title.FontSize = max(1, fst - 6);
        end
    end

    % Legend font size + placement + icon scaling (all legends; 'none' hides).
    lgs = findobj(S.panel, 'Type', 'legend');
    loc = S.dd_legend.Value;
    fsleg = S.sp_fs_legend.Value;
    for k = 1:numel(lgs)
        style_legend(lgs(k), fsleg, loc);
    end
end


function style_legend(lg, fsleg, loc)
    % Set a legend's font size, placement, and — the point of this helper —
    % its ICON size. Legend FontSize scales only the text, and a legend's
    % marker glyph is tied to each plotted line's MarkerSize, so marker-only
    % (scatter '.') views show tiny dots no matter the FontSize/ItemTokenSize.
    % Rebuild the legend from invisible proxy lines (NaN data) that copy each
    % entry's colour/marker/linestyle but carry a marker scaled to the legend
    % font: the icon grows with the text without enlarging the plotted data.
    % Idempotent — proxies are tagged 'legendproxy' and cleared each call, so
    % repeated style changes (and the re-entrant overlay legend) don't stack.
    src = lg.PlotChildren;
    if isempty(src), lg.FontSize = fsleg; return; end
    ax = ancestor(src(1), 'axes');
    % The icon-rebuild below assumes line-like entries (Line/ErrorBar, which
    % carry Color/LineStyle/Marker/MarkerFaceColor). Keep the simple text/box
    % scaling — and skip the rebuild — for: dual-axis (yyaxis) views (e.g. L2
    % SNOdar overlays), where rebuilding from one side's proxies drops the
    % other's entries; and Bar/Scatter/Patch legends (Data availability, the
    % compare Phase-vs-SNR scatter) whose entries lack those line properties.
    line_like = all(arrayfun(@(h) isprop(h,'Color') && isprop(h,'LineStyle') ...
        && isprop(h,'Marker') && isprop(h,'MarkerFaceColor'), src));
    if isempty(ax) || numel(ax.YAxis) > 1 || ~line_like
        lg.FontSize = fsleg;
        lg.ItemTokenSize = round([30 18] * fsleg / 10);
        if strcmp(loc, 'none'), lg.Visible = 'off';
        else, lg.Visible = 'on';  lg.Location = loc;
        end
        return;
    end
    strs = cellstr(lg.String);
    interp = lg.Interpreter;
    n = min(numel(src), numel(strs));

    % Snapshot each entry's style BEFORE deleting prior proxies (src may be
    % last call's proxies, which the delete below would invalidate).
    col = cell(1,n); ls = cell(1,n); lw = zeros(1,n);
    mk  = cell(1,n); mfc = cell(1,n);
    for j = 1:n
        col{j} = src(j).Color;       ls{j}  = src(j).LineStyle;
        lw(j)  = src(j).LineWidth;   mk{j}  = src(j).Marker;
        mfc{j} = src(j).MarkerFaceColor;
    end

    delete(findobj(ax, 'Tag', 'legendproxy'));
    was_held = ishold(ax);
    hold(ax, 'on');
    proxies = gobjects(1, n);
    for j = 1:n
        if strcmp(mk{j}, '.')          % point marker renders small for its size
            msz = max(6, round(fsleg * 1.6));
        else
            msz = max(4, round(fsleg * 0.9));
        end
        proxies(j) = plot(ax, NaN, NaN, 'Tag', 'legendproxy', ...
            'Color', col{j}, 'LineStyle', ls{j}, 'LineWidth', lw(j), ...
            'Marker', mk{j}, 'MarkerSize', msz, 'MarkerFaceColor', mfc{j}, ...
            'HandleVisibility', 'off');
    end
    if ~was_held, hold(ax, 'off'); end

    lg2 = legend(ax, proxies, strs(1:n), 'Interpreter', interp);
    lg2.FontSize = fsleg;
    lg2.ItemTokenSize = round([30 18] * fsleg / 10);   % stretch line sample + row too
    if strcmp(loc, 'none')
        lg2.Visible = 'off';
    else
        lg2.Visible = 'on';
        lg2.Location = loc;
    end
end


function show_msg(V, msg)
    S = V;
    delete(S.panel.Children);
    tl = tiledlayout(S.panel, 1, 1);
    ax = nexttile(tl);
    text(ax, 0.5, 0.5, msg, 'HorizontalAlignment', 'center', 'Interpreter', 'none');
    axis(ax, 'off');
end


function ok = looks_curve_plot(V, ax, items, ttl, ylab)
    M = V.M;
    calib_N_looks = V.calib_N_looks;
    % Plot the non-overlapping ("static") Allan deviation of within-run
    % block-mean phase vs look count k (log-log) for one or more series.
    % Each series gets a dashed -1/2 reference anchored at its smallest
    % retained k (adev(k_min)*sqrt(k_min./k)); if a coherence column is
    % provided, also a dotted absolute thermal floor
    % median(sigma_phi(rho, calib_N_looks))./sqrt(k). The legend shows one
    % reference / floor entry (the first series'); the other series' lines
    % are drawn but hidden from the legend. items is a struct array with
    % fields: deg (phase, deg), grp (run-group ids), lbl (legend label),
    % rho (coherence magnitude for the absolute floor, or [] for none),
    % color (RGB row). Returns false (nothing drawn) if no series yields the
    % required >= 3 valid k points; the caller then shows a message.
    MIN_PAIRS = 20;     % min pooled adjacent block-pairs per k
    MIN_K     = 3;      % min valid k points to draw a curve
    hold(ax, 'on');
    leg_h = gobjects(0);  leg_s = {};
    ref_done = false;  flr_done = false;  ok = false;
    for ii = 1:numel(items)
        it = items(ii);
        [k, adev, ~] = M.looks_curve(it.deg, it.grp, MIN_PAIRS);
        if numel(k) < MIN_K, continue; end
        ok  = true;
        col = it.color;
        hm  = plot(ax, k, adev, 'o-', 'Color', col, 'MarkerFaceColor', col, ...
                   'MarkerSize', 4, 'LineWidth', 1.2);
        leg_h(end+1) = hm;  leg_s{end+1} = it.lbl;             %#ok<AGROW>
        % -1/2 reference anchored at the smallest retained k
        ref = adev(1) .* sqrt(k(1)) ./ sqrt(k);
        hr  = plot(ax, k, ref, '--', 'Color', col, 'HandleVisibility', 'off');
        if ~ref_done
            set(hr, 'HandleVisibility', 'on');
            leg_h(end+1) = hr;                                 %#ok<AGROW>
            leg_s{end+1} = 'reference \propto 1/\surdk (-1/2 slope)'; %#ok<AGROW>
            ref_done = true;
        end
        % absolute sigma_phi thermal floor (calib only; rho supplied)
        if ~isempty(it.rho)
            s1  = median(M.sigma_phi_deg(it.rho, calib_N_looks), 'omitnan');
            flr = s1 ./ sqrt(k);
            hfl = plot(ax, k, flr, ':', 'Color', col, 'LineWidth', 1.2, ...
                       'HandleVisibility', 'off');
            if ~flr_done && isfinite(s1)
                set(hfl, 'HandleVisibility', 'on');
                leg_h(end+1) = hfl;                            %#ok<AGROW>
                leg_s{end+1} = '\sigma_\phi floor (nominal N_L)'; %#ok<AGROW>
                flr_done = true;
            end
        end
    end
    if ~ok
        hold(ax, 'off');
        return;
    end
    set(ax, 'XScale', 'log', 'YScale', 'log');
    xlabel(ax, 'looks averaged k (captures)');
    ylabel(ax, ylab);
    legend(ax, leg_h, leg_s, 'Location', 'best');
    title(ax, ttl);
    hold(ax, 'off');
end


function tf = is_compare_mode(V)
    S = V;
    COMPARE_DATASET = V.COMPARE_DATASET;
    % True when the 'base vs notch' Dataset entry is selected.
    tf = strcmp(string(S.dd_method.Value), string(COMPARE_DATASET));
end


function tf = is_chaincal_mode(V)
    S = V;
    CHAINCAL_DATASET = V.CHAINCAL_DATASET;
    % True when the 'notch + chain-cal' Dataset entry is selected.
    tf = strcmp(string(S.dd_method.Value), string(CHAINCAL_DATASET));
end


function y = wrap_deg(y)
    % Wrap degrees to (-180, 180].
    y = mod(y + 180, 360) - 180;
end


function v = cfgdef(V, name, def)
    cfg = V.cfg;
    % cfg field with a fallback (the viewer may receive a minimal cfg).
    if isfield(cfg, name) && ~isempty(cfg.(name)), v = cfg.(name); else, v = def; end
end


function m = dropdown_method(V)
    S = V;
    % Map the Dataset dropdown (ItemsData in the fixed order base/notch/
    % notch+chain-cal/compare) to an rfi_excise method name. Used by the
    % live-filtered raw views (PSD, Spectrogram). 'notch + chain-cal'
    % behaves as notch (the chain-cal delta only exists in product CSVs).
    methods3 = {'none', 'notch_interp', 'notch_interp'};
    mi = find(strcmp(S.dd_method.ItemsData, S.dd_method.Value), 1);
    if isempty(mi) || mi > numel(methods3), mi = 1; end   % 'base vs notch' -> base raw
    m = methods3{mi};
end


function lbl = dataset_label(V)
    S = V;
    % Friendly Dataset label for titles/filenames ('base (none)' / 'notch')
    % — the dropdown Item text parallel to its ItemsData.
    mi = find(strcmp(S.dd_method.ItemsData, S.dd_method.Value), 1);
    if isempty(mi), mi = 1; end
    lbl = S.dd_method.Items{mi};
end


function s = dataset_suffix(V)
    is_compare_mode = @(varargin) V.U.is_compare_mode(V, varargin{:});
    dropdown_method = @(varargin) V.U.dropdown_method(V, varargin{:});
    dataset_label = @(varargin) V.U.dataset_label(V, varargin{:});
    % Compact Dataset suffix for product-CSV plot titles: '' for base/none,
    % ' w/ Notch' for the RFI-filtered set. Mirrors the
    % raw-view 'w/ Notch' convention (raw_cap_title) and replaces the verbose
    % '   —   dataset: notch' tag.
    if is_compare_mode()
        s = ' — base vs notch';
    elseif strcmp(dropdown_method(), 'none')
        s = '';
    else
        lbl = char(dataset_label());          % 'notch'
        s = [' w/ ' upper(lbl(1)) lbl(2:end)];
    end
end


function dm = domain_mode(V)
    S = V;
    % Active Phase-domain selection: 'fd' | 'fd_muos' | 'sinc' | 'compare'.
    if ~isempty(S.dd_domain) && ~isempty(S.dd_domain.Value)
        dm = char(S.dd_domain.Value);
    else
        dm = 'sinc';
    end
end


function tf = plot_uses_domain(kind)
    % True for the phase/amplitude product-CSV plots the Phase-domain
    % selector affects (it swaps the L1/L2 column read or overlays variants).
    domain_plots = { ...
        'L1: Phase time series', 'L1: Amplitude time series', ...
        'L1: Phase vs SNR scatter', 'L1: Diurnal phase pattern', ...
        'L1: Within-run phase scatter'};
    tf = any(strcmp(kind, domain_plots)) || startsWith(kind, 'L2: Candidates') ...
         || startsWith(kind, 'L2: Diurnal');
end


function s = domain_suffix(V)
    domain_mode = @(varargin) V.U.domain_mode(V, varargin{:});
    % Compact Phase-domain tag for titles (parallel to dataset_suffix).
    switch domain_mode()
        case 'fd',      s = ' [fd]';
        case 'fd_muos', s = ' [freq\_muos]';
        case 'sinc',    s = ' [sinc]';
        otherwise,      s = ' [fd vs sinc]';
    end
end


function c = domain_color(lab)
    % Consistent colors for the sinc / fd / freq_muos overlay series.
    switch lab
        case 'fd',         c = [0.850 0.325 0.098];   % orange
        case 'freq\_muos', c = [0.466 0.674 0.188];   % green
        otherwise,         c = [0.000 0.447 0.741];   % blue (sinc)
    end
end


function [cols, labs] = domain_cols(V, T, c_sinc, c_fd, c_muos)
    domain_mode = @(varargin) V.U.domain_mode(V, varargin{:});
    % Resolve which phase column(s) to plot for the current Phase-domain
    % selection. Returns parallel cellstr `cols` (present in T) and `labs`
    % (legend labels). fd / fd_muos fall back to the sinc column if absent
    % (old CSV not yet reprocessed); 'compare' overlays every available one.
    vn = T.Properties.VariableNames;
    switch domain_mode()
        case 'sinc'
            cols = {c_sinc};  labs = {'sinc'};
        case 'fd'
            if ismember(c_fd, vn), cols = {c_fd};   labs = {'fd'};
            else,                  cols = {c_sinc}; labs = {'sinc (no fd)'};  end
        case 'fd_muos'
            if ismember(c_muos, vn), cols = {c_muos}; labs = {'freq\_muos'};
            else,                    cols = {c_sinc}; labs = {'sinc (no fd)'};  end
        otherwise   % compare
            cols = {c_sinc};  labs = {'sinc'};
            if ismember(c_fd, vn),   cols{end+1} = c_fd;   labs{end+1} = 'fd';         end
            if ismember(c_muos, vn), cols{end+1} = c_muos; labs{end+1} = 'freq\_muos'; end
    end
end


function [col, lab] = domain_col1(V, T, c_sinc, c_fd, c_muos)
    domain_mode = @(varargin) V.U.domain_mode(V, varargin{:});
    % Single-column resolver for panels that overlay other series (Candidate
    % / SNOdar): one phase column for the current mode. 'fd'/'compare' ->
    % full-band fd (fall back to sinc if absent).
    vn = T.Properties.VariableNames;
    switch domain_mode()
        case 'sinc'
            col = c_sinc;  lab = 'sinc';
        case 'fd_muos'
            if ismember(c_muos, vn), col = c_muos; lab = 'freq\_muos';
            else,                    col = c_sinc; lab = 'sinc';  end
        otherwise   % 'fd' or 'compare'
            if ismember(c_fd, vn), col = c_fd; lab = 'fd';
            else,                  col = c_sinc; lab = 'sinc';  end
    end
end


function leg_done = plot_domain_series(V, ax, t, T, c_sinc, c_fd, c_muos, agg, ptype)
    plot_series = @(varargin) V.U.plot_series(V, varargin{:});
    domain_cols = @(varargin) V.U.domain_cols(V, varargin{:});
    domain_color = V.U.domain_color;
    % Plot the phase/amplitude column(s) for the current Phase-domain
    % selection on ax, colored + legended when more than one is shown.
    [cols, labs] = domain_cols(T, c_sinc, c_fd, c_muos);
    hold(ax, 'on');
    hh = gobjects(numel(cols), 1);
    for ii = 1:numel(cols)
        hh(ii) = plot_series(ax, t, T.(cols{ii}), agg, ptype);
        hh(ii).Color = domain_color(labs{ii});
    end
    hold(ax, 'off');
    leg_done = numel(cols) > 1;
    if leg_done, legend(hh, labs, 'Location', 'best'); end
end


function ttl = raw_cap_title(V, base, D)
    dataset_label = @(varargin) V.U.dataset_label(V, varargin{:});
    % Title for a capture-based raw view: just '<base>' for the base/none
    % dataset, or '<base> w/ Notch' when an RFI
    % filter dataset is active. Replaces the older verbose
    % 'filter: notch_interp (cfg.rfi_bands applied per segment)' form.
    if isfield(D, 'method') && ~strcmp(D.method, 'none')
        lbl = char(dataset_label());          % 'notch'
        ttl = string(base) + " w/ " + [upper(lbl(1)) lbl(2:end)];
    else
        ttl = string(base);
    end
end


function tf = plot_uses_method(kind)
    % True when the Dataset selection affects this plot: every product-CSV
    % plot (it switches cfg.out_dir) plus the live-filtered raw views. The
    % Radar Cal footprint map and specular track are pure forward models (no
    % product read), and the two season RFI views read the base-dir
    % rfi_spectrum products with their own 'RFI set' selector — the Dataset
    % selector is greyed out for all four.
    raw_filterable = {'Raw: PSD (ch0 & ch1)', 'Raw: Spectrogram', ...
                      'Raw: Cross-correlation profile', ...
                      'Raw: Cross-correlation Comparison', ...
                      'Raw: Time domain', 'Raw: FFT Amplitude'};
    tf = (~startsWith(kind, 'Raw:') || any(strcmp(kind, raw_filterable))) ...
         && ~any(strcmp(kind, {'Radar Cal: footprint map', ...
                               'Radar Cal: specular track', ...
                               'RFI: Season spectrum', ...
                               'RFI: Season PSD — notch effect'}));
end


function excis = prep_excis(V, seg_len, method)
    cfg = V.cfg;
    % Build the rfi_excise operator for this FFT length and the SELECTED
    % method only (independent of the session's cfg.rfi_methods). Building
    % just the one operator matters at the 18M-pt xcorr FFT, where each
    % operator is tens of MB. Only called for non-'none' methods.
    %
    % Per-dataset bands: the live notch/filter of a raw capture uses the same
    % band set the pipeline would apply to that capture type (Signal ->
    % cfg.rfi_bands, NL -> cfg.rfi_bands_nl, L -> cfg.rfi_bands_l, missing ->
    % empty = pass-through), so the viewer's "w/ Notch" preview matches the
    % _notch products. Only affects live raw filtering; product-CSV views read
    % already-written output dirs and are unchanged.
    bands = rfi_dataset_bands(cfg, char(V.dd_ctype.Value));
    cfgp = cfg;
    cfgp.rfi_methods = {method};
    excis = rfi_prepare_bands(cfgp, bands, seg_len);
end


function bands = rfi_dataset_bands(cfg, ctype)
    % Band list for a capture type (Signal/NL/L) with an empty fallback.
    switch ctype
        case 'NL', fld = 'rfi_bands_nl';
        case 'L',  fld = 'rfi_bands_l';
        otherwise, fld = 'rfi_bands';
    end
    if isfield(cfg, fld) && ~isempty(cfg.(fld)), bands = cfg.(fld); else, bands = zeros(0,2); end
end


function info = rfi_dataset_info(V, name)
    % Resolve the season-RFI 'RFI set' selector (Signal/NL/L) to the files it
    % drives, so rfi_explorer, rfi_filter_psd, and on_rfi_export cannot drift.
    %   .name      display/selector name
    %   .sfx       CSV/PNG/proposed-file suffix ('' / '_NL' / '_L')
    %   .spectrum  season spectrum CSV basename (rfi_spectrum<sfx>.csv)
    %   .proposed  export target basename (rfi_bands_proposed<sfx>.csv)
    %   .curated   curated band CSV this set feeds (rfi_bands[...].csv)
    %   .use_sk    whether the SK gate applies (Signal only)
    if nargin < 2 || isempty(name)
        if isprop(V, 'rfi_dataset') && ~isempty(V.rfi_dataset)
            name = char(V.rfi_dataset.Value);
        else
            name = 'Signal';
        end
    end
    switch char(name)
        case 'NL', sfx = '_NL'; curated = 'rfi_bands_NL.csv';
        case 'L',  sfx = '_L';  curated = 'rfi_bands_L.csv';
        otherwise, name = 'Signal'; sfx = ''; curated = 'rfi_bands.csv';
    end
    info = struct('name', name, 'sfx', sfx, ...
                  'spectrum', ['rfi_spectrum' sfx '.csv'], ...
                  'proposed', ['rfi_bands_proposed' sfx '.csv'], ...
                  'curated', curated, ...
                  'use_sk', strcmp(name, 'Signal'));
end


function h = plot_series(V, ax, t, y, agg_mode, kind)
    M = V.M;
    [ta, ya, ys] = M.aggregate(t, y, agg_mode, kind);
    if isempty(ys)
        h = plot(ax, ta, ya, '.');
    else
        h = errorbar(ax, ta, ya, ys, 'o-', 'MarkerSize', 4, 'CapSize', 3);
    end
    xlabel(ax, 'Date');
end


function t = tcol(T)
    if isempty(T), t = datetime.empty(0, 1); else, t = T.timestamp; end
end


function s = src_desc(T)
% One-line source description for the side panel.
    if isempty(T)
        s = "not found";
    else
        s = height(T) + " rows, " + string(min(T.timestamp), 'yyyy-MM-dd') + ...
            " to " + string(max(T.timestamp), 'yyyy-MM-dd');
    end
end


function open_fun(name)
% Open BrundageSoOp_fun.m in the MATLAB editor and scroll to the requested
% local function. Called by the side-panel Source links.
    file = which('BrundageSoOp_fun');
    if isempty(file)
        edit BrundageSoOp_fun;   % not on path yet — open by name
        return;
    end
    % Locate the function's definition line in the file on disk.
    lines = regexp(fileread(file), '\r\n|\n|\r', 'split');
    idx   = find(~cellfun(@isempty, regexp(lines, ...
                ['^\s*function\b.*\<' char(name) '\>\s*\('], 'once')), 1);
    if isempty(idx)
        matlab.desktop.editor.openDocument(file);   % fallback: open at top
    else
        % openAndGoToLine both scrolls the view and highlights the line
        % (setting Document.Selection alone moves the cursor but not the view).
        matlab.desktop.editor.openAndGoToLine(file, idx);
    end
end


function [dur, ok] = parse_tod(str)
% Parse a time-of-day string into a duration. Accepted grammar (anchored,
% surrounding whitespace ignored): H, HH, HMM, HHMM, H:MM, or HH:MM with
% hour 0-23 and minute 0-59; anything else -> ok = false. Pure helper
% (no V) so the L2 daily filter's input handling is testable headlessly.
    dur = duration(NaN, 0, 0);
    ok  = false;
    s   = strtrim(char(str));
    tok = regexp(s, '^(\d{1,2}):(\d{2})$', 'tokens', 'once');     % H:MM / HH:MM
    if isempty(tok)
        tok = regexp(s, '^(\d{1,2})(\d{2})$', 'tokens', 'once');  % HMM / HHMM
    end
    if isempty(tok)
        tok = regexp(s, '^(\d{1,2})$', 'tokens', 'once');         % H / HH
        if ~isempty(tok), tok{2} = '00'; end
    end
    if isempty(tok), return; end
    hh = str2double(tok{1});
    mm = str2double(tok{2});
    if hh > 23 || mm > 59, return; end
    dur = hours(hh) + minutes(mm);
    ok  = true;
end


function [idx, tday] = tod_daily_idx(t, target, win)
% One capture per target day: the capture nearest each day's nominal target
% instant (day + target), kept only when that distance is <= win. Days are
% target-centered (each capture is assigned to the nearest nominal instant,
% not grouped by calendar date), so a near-midnight target binds
% post-midnight captures to the correct day. t must be unzoned (naive
% wall-clock) datetimes — the capture timebase read_product produces; for
% zoned datetimes timeofday/dateshift diverge from the displayed clock on
% DST days, so zoned input errors. Ties at equal distance keep the earliest
% original row. Returns ascending original indices idx and, aligned with
% them, the nominal target days tday (day-start datetimes).
    if ~isempty(t.TimeZone)
        error('soop_viewer_util:tod_daily_idx:zoned', ...
              'tod_daily_idx requires unzoned (wall-clock) datetimes.');
    end
    t    = t(:);
    orig = (1:numel(t))';
    keep = ~isnat(t);
    t    = t(keep);
    orig = orig(keep);
    if isempty(t)
        idx  = zeros(0, 1);
        tday = NaT(0, 1);
        return;
    end
    % Nearest nominal target day: minimizing |t - (day + target)| over
    % calendar days is rounding (t - target) to the nearest day boundary.
    d_near = dateshift((t - target) + hours(12), 'start', 'day');
    dist   = abs(t - (d_near + target));
    % Sort by (day, distance, original index); the first row per day is its
    % nearest capture, with equal distances resolved to the earliest row.
    srt   = sortrows(table(d_near, dist, orig));
    first = [true; srt.d_near(2:end) ~= srt.d_near(1:end-1)];
    sel   = first & srt.dist <= win;
    [idx, ord] = sort(srt.orig(sel));
    tday  = srt.d_near(sel);
    tday  = tday(ord);
end


function [phi, rho] = phoff_measure(ch0, ch1)
% Inter-channel phase offset at lag 0 in the pipeline's D.*conj(R) order
% (schema v5+, same expression as compute_calib's C_RDNS): phi =
% angle(mean(ch0 .* conj(ch1))) over the finite sample pairs, in radians.
% rho is the normalized lag-0 coherence |C| / sqrt(<|D|^2><|R|^2>) in
% [0,1]. Fail-closed: phi = rho = NaN when there are no finite pairs, a
% channel has zero power, or the correlation is zero/non-finite — a zero
% cross-correlation has undefined phase and must not read as a valid 0.
    phi = NaN;
    rho = NaN;
    ch0 = ch0(:);
    ch1 = ch1(:);
    n   = min(numel(ch0), numel(ch1));
    ch0 = ch0(1:n);
    ch1 = ch1(1:n);
    ok  = isfinite(ch0) & isfinite(ch1);
    if ~any(ok), return; end
    C  = mean(ch0(ok) .* conj(ch1(ok)));
    p0 = mean(abs(ch0(ok)).^2);
    p1 = mean(abs(ch1(ok)).^2);
    if ~isfinite(C) || C == 0 || p0 == 0 || p1 == 0, return; end
    phi = angle(C);
    rho = abs(C) / sqrt(p0 * p1);
end


function D = phoff_prep(ch0, ch1, fs, slice_half)
% Display data for 'Raw: Phase Offset': phi/rho measured over the whole
% loaded window (phoff_measure), plus a contiguous un-decimated slice of
% both channels' REAL component about the window midpoint (center sample
% c = floor((N+1)/2), slice clamped to the record). Both switch states are
% precomputed — r1_off (as recorded) and r1_on (rotated by exp(1i*phi) so
% the correlated components align) — so the render cache stays valid when
% the Phase cal switch toggles; ymax is their union, keeping the y-scale
% stable across toggles. When phi is NaN (no usable correlation) r1_on
% falls back to r1_off so a rotation can never inject NaNs.
    ch0 = ch0(:);
    ch1 = ch1(:);
    n   = min(numel(ch0), numel(ch1));
    ch0 = ch0(1:n);
    ch1 = ch1(1:n);
    [D.phi, D.rho] = phoff_measure(ch0, ch1);
    D.n = n;
    if n == 0
        D.t_us   = zeros(0, 1);
        D.r0     = zeros(0, 1);
        D.r1_off = zeros(0, 1);
        D.r1_on  = zeros(0, 1);
        D.ymax   = 0;
        return;
    end
    c   = floor((n + 1) / 2);
    idx = (max(1, c - slice_half) : min(n, c + slice_half))';
    D.t_us   = (idx - c) / fs * 1e6;
    D.r0     = real(ch0(idx));
    D.r1_off = real(ch1(idx));
    if isfinite(D.phi)
        D.r1_on = real(ch1(idx) .* exp(1i * D.phi));
    else
        D.r1_on = D.r1_off;
    end
    D.ymax = max(abs([D.r0; D.r1_off; D.r1_on]));
end


function tstr = phoff_title(base, phi, rho, sw_on)
% Title for 'Raw: Phase Offset' (pure so the three states are testable).
% Rule (user spec 2026-07-20): the phi/rho numbers appear ONLY while the
% correction is applied — their presence is the on-indicator, so there is
% no 'correction ON/OFF' text. Switch on with no usable correlation says
% so explicitly (never a silent no-op).
    dash = char(8212);
    if sw_on && isfinite(phi)
        tstr = sprintf('%s %s phase offset %.1f%s (rho %.2f)', ...
                       base, dash, rad2deg(phi), char(176), rho);
    elseif sw_on
        tstr = sprintf('%s %s phase offset n/a (no usable correlation)', ...
                       base, dash);
    else
        tstr = char(base);
    end
end

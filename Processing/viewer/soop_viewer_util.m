function U = soop_viewer_util()
% UI/label/formatting helpers for BrundageSoOp_viewer. Returns a struct of
% handles (same idiom as rfi_excise/BrundageSoOp_fun); each takes V first
% (except pure helpers style_legend/wrap_deg/domain_color/plot_uses_*/tcol/
% parse_tod/tod_daily_idx/nearest_above_freezing/phoff_measure/phoff_prep/
% phoff_title/freeze_spans/
% wx_axis_cfg/wx_axes_plan/snrcut_usable/snrcut_apply/snrcut_start/wx_temp_labels/
% swe_per_fringe_mm/fringe_pick/fringe_latch/theory_overlay/unwrap_deg/
% is_cand_kind/hour_bins/style_factors/style_apply/src_desc/open_fun).
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
    U.nearest_above_freezing = @nearest_above_freezing;
    U.phoff_measure = @phoff_measure;
    U.phoff_prep = @phoff_prep;
    U.phoff_title = @phoff_title;
    U.freeze_spans = @freeze_spans;
    U.wx_axis_cfg = @wx_axis_cfg;
    U.wx_axes_plan = @wx_axes_plan;
    U.snrcut_usable = @snrcut_usable;
    U.snrcut_apply = @snrcut_apply;
    U.snrcut_start = @snrcut_start;
    U.ovf_load = @ovf_load;
    U.ovf_mask = @ovf_mask;
    U.ovf_usable = @ovf_usable;
    U.wx_temp_labels = @wx_temp_labels;
    U.dtc_thermograph = @dtc_thermograph;
    U.dtc_renderable = @dtc_renderable;
    U.soil_geometry = @soil_geometry;
    U.soil_usable = @soil_usable;
    U.soil_color = @soil_color;
    U.soil_linestyle = @soil_linestyle;
    U.dtc_clim = @dtc_clim;
    U.dtc_clim_order = @dtc_clim_order;
    U.nearest_wx_idx = @nearest_wx_idx;
    U.band_halfwidth = @band_halfwidth;
    U.snowtemp_nearest_bands = @snowtemp_nearest_bands;
    U.swe_per_fringe_mm = @swe_per_fringe_mm;
    U.fringe_pick = @fringe_pick;
    U.fringe_latch = @fringe_latch;
    U.theory_overlay = @theory_overlay;
    U.unwrap_deg = @unwrap_deg;
    U.is_cand_kind = @is_cand_kind;
    U.hour_bins = @hour_bins;
    U.style_factors = @style_factors;
    U.style_apply = @style_apply;
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
    % strip any supported prior tag before re-appending, so style-change calls
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
    % Wrap degrees to [-180, 180): mod-based, so exactly +180 maps to -180.
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
    tf = any(strcmp(kind, domain_plots)) || is_cand_kind(kind) ...
         || startsWith(kind, 'L2: Diurnal');
end


function tf = is_cand_kind(kind)
% The satellite-candidates figure family: the MUOS candidate views (wrapped
% and unwrapped) plus 'L2: Sensor data'. One predicate keeps render
% dispatch, side-panel control visibility, and the Phase-domain gating from
% ever disagreeing.
    tf = startsWith(kind, 'L2: Candidates') || strcmp(kind, 'L2: Sensor data');
end


function h = hour_bins(t)
% Nearest hour of day (0..23) per timestamp, for the hour-coloring scatter:
% rounds the clock time to the closest whole hour, wrapping 23:31-23:59 to
% hour 0. NaT -> NaN. Shape follows the input.
    h = mod(round(hour(t) + minute(t) / 60 + second(t) / 3600), 24);
    h(isnat(t)) = NaN;
end


function F = style_factors(v_lw, v_pt)
% Validated Line x / Pt x scale factors for the candidates-family style
% spinners. Each input must be a real, finite, positive numeric scalar;
% anything else falls back to x1 so a render never errors on a bad value.
% Pure helper (no V) — headlessly testable.
    F = struct('lw', sane(v_lw), 'pt', sane(v_pt));
    function s = sane(v)
        if isnumeric(v) && isscalar(v) && isreal(v) && isfinite(v) && v > 0
            s = double(v);
        else
            s = 1;
        end
    end
end


function style_apply(F, lines_h, pts_h, dots_h)
% Apply validated style factors (style_factors) to the candidates-family
% handles by MULTIPLYING their product-owned base styles: LineWidth x F.lw
% on lines_h, MarkerSize x F.pt on pts_h, and SizeData x F.pt^2 on dots_h
% (scatter sizes are areas in points^2, so the apparent dot diameter
% scales linearly with F.pt like the markers). A handle may appear in more
% than one list (the phase Line/ErrorBar carries both a line and markers).
% Invalid/deleted entries are skipped so a partial render never errors.
    for h = reshape(lines_h(isgraphics(lines_h)), 1, [])
        h.LineWidth = h.LineWidth * F.lw;
    end
    for h = reshape(pts_h(isgraphics(pts_h)), 1, [])
        h.MarkerSize = h.MarkerSize * F.pt;
    end
    for h = reshape(dots_h(isgraphics(dots_h)), 1, [])
        h.SizeData = h.SizeData * F.pt^2;
    end
end


function A = fringe_latch(txt, ud, auto_mm)
% Auto/manual state machine for the theoretical mm-per-fringe field.
% Inputs: the field's current text, its UserData ownership struct (may be
% empty on first use), and the geometry-computed auto rate (may be NaN when
% geometry is unavailable). Returns struct A:
%   .text — what the field should display (programmatic write; never flips
%           ownership): the auto rate formatted %.0f while is_auto, blank
%           while is_auto with NaN auto, the user's text verbatim otherwise
%   .ud   — updated ownership state {is_auto, last_auto_text, last_auto_mm}
%   .mm   — the ACTIVE rate for the overlay: the UNROUNDED auto value while
%           is_auto (display rounding must not change the physics), else
%           fringe_pick(text, auto) so invalid manual text falls back to
%           the auto VALUE without silently changing ownership
% is_auto itself is owned by the edit callback (user typed nonempty →
% manual; cleared → auto); this latch only refreshes display/value.
    if ~(isstruct(ud) && isfield(ud, 'is_auto'))
        ud = struct('is_auto', true, 'last_auto_text', '', 'last_auto_mm', NaN);
    end
    ud.last_auto_mm = auto_mm;
    if ud.is_auto
        if isfinite(auto_mm) && auto_mm > 0
            ud.last_auto_text = sprintf('%.0f', auto_mm);
        else
            ud.last_auto_text = '';
        end
        A = struct('text', ud.last_auto_text, 'ud', ud, 'mm', auto_mm);
    else
        A = struct('text', txt, 'ud', ud, 'mm', fringe_pick(txt, auto_mm));
    end
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
    % when those columns are absent; 'compare' overlays every available one.
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
    % dataset, or '<base> w/ Notch' when an RFI filter dataset is active.
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
    % Product-owned base style, set explicitly (values equal the MATLAB
    % defaults, so nothing changes appearance): the candidates family's
    % Line x / Pt x spinners scale FROM these via style_apply, and pinning
    % them here keeps that scaling release-stable.
    if isempty(ys)
        h = plot(ax, ta, ya, '.', 'MarkerSize', 6, 'LineWidth', 0.5);
    else
        h = errorbar(ax, ta, ya, ys, 'o-', 'MarkerSize', 4, 'CapSize', 3, ...
                     'LineWidth', 0.5);
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


function [warm, wx_idx] = nearest_above_freezing(t_capture, t_wx, temp_c, win, threshold_c)
% Match each collection to its nearest finite air-temperature observation.
% A match is usable when its absolute time offset is <= win; warm is true
% only when that nearest observation is strictly > threshold_c. Equal-time
% distances choose the earlier weather timestamp, then the earlier input row.
% Outputs are columns aligned with t_capture; unmatched wx_idx values are 0.
    t_capture = t_capture(:);
    t_wx = t_wx(:);
    temp_c = temp_c(:);
    if numel(t_wx) ~= numel(temp_c)
        error('soop_viewer_util:nearest_above_freezing:length', ...
              'nearest_above_freezing: t_wx and temp_c must have equal length.');
    end
    if ~isduration(win) || ~isscalar(win) || ...
            ~isfinite(seconds(win)) || win < seconds(0)
        error('soop_viewer_util:nearest_above_freezing:window', ...
              'nearest_above_freezing: win must be a finite nonnegative duration.');
    end
    if ~isnumeric(threshold_c) || ~isscalar(threshold_c) || ~isfinite(threshold_c)
        error('soop_viewer_util:nearest_above_freezing:threshold', ...
              'nearest_above_freezing: threshold_c must be a finite numeric scalar.');
    end
    if xor(isempty(t_capture.TimeZone), isempty(t_wx.TimeZone))
        error('soop_viewer_util:nearest_above_freezing:timezone', ...
              'Collection and weather datetimes must both be zoned or both unzoned.');
    end

    warm = false(numel(t_capture), 1);
    wx_idx = zeros(numel(t_capture), 1);
    orig = (1:numel(t_wx))';
    valid = ~isnat(t_wx) & isfinite(temp_c);
    W = table(t_wx(valid), temp_c(valid), orig(valid), ...
              'VariableNames', {'t', 'temp_c', 'orig'});
    W = sortrows(W, {'t', 'orig'});
    for k = 1:numel(t_capture)
        if isnat(t_capture(k)) || isempty(W), continue; end
        [dist, j] = min(abs(W.t - t_capture(k)));
        if dist <= win
            wx_idx(k) = W.orig(j);
            warm(k) = W.temp_c(j) > threshold_c;
        end
    end
end


function [phi, rho] = phoff_measure(ch0, ch1)
% Inter-channel phase offset at lag 0 in the pipeline's D.*conj(R) order,
% matching compute_calib's C_RDNS: phi =
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
% The phi/rho numbers appear only while the
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


function spans = freeze_spans(t, y)
% Above-freezing spans for the wet-snow band overlay: contiguous runs of
% samples with y > 0 (STRICT) become [start end] datetime intervals padded
% by half the sampling interval on each side. Contract:
%   - t (datetime) and y must have equal length; both are canonicalized to
%     sorted columns. Rows with NaT timestamps are dropped.
%   - Rows with non-finite y are KEPT as cold separators — a present-but-
%     invalid sample always breaks a band.
%   - Sampling interval dt = median of the POSITIVE time diffs of the full
%     kept stream (duplicate timestamps contribute no zero diffs;
%     minutes(15) fallback when no positive diff exists), capped at 1 hour
%     so a sparse outage can never masquerade as the cadence — bands never
%     pad more than 30 min past a sample nor bridge gaps over 1.5 h.
%   - Runs additionally split at sample gaps > 1.5*dt (a missed scheduled
%     sample splits; exactly 1.5*dt does not), so bands never bridge
%     station outages.
%   - Returns NaT(0,2) when nothing qualifies.
    t = t(:);
    y = y(:);
    if numel(t) ~= numel(y)
        error('soop_viewer_util:freeze_spans:length', ...
              'freeze_spans: t and y must have equal length.');
    end
    keep = ~isnat(t);
    t = t(keep);
    y = y(keep);
    [t, ord] = sort(t);
    y = y(ord);
    if isempty(t), spans = NaT(0, 2); return; end
    dd = diff(t);
    dd = dd(dd > 0);
    if isempty(dd), dt = minutes(15); else, dt = min(median(dd), hours(1)); end
    hot = isfinite(y) & y > 0;
    if ~any(hot), spans = NaT(0, 2); return; end
    gap = [false; diff(t) > 1.5 * dt];   % gap(i): outage between i-1 and i
    is_start = hot & ([true; ~hot(1:end-1)] | gap);
    is_end   = hot & [~hot(2:end) | gap(2:end); true];
    spans = [t(is_start) - dt/2, t(is_end) + dt/2];
end


function R = wx_axis_cfg(series, vals)
% Per-series right-ruler plan for the candidates weather overlays — each
% series keeps its own units, label, and color (independent axes):
%   'depth' — meters, red,  pad 0.1 m
%   'swe'   — mm,     teal, pad 100 mm
% Accepts char or string selectors; unknown selectors error
% (soop:wx_axis_cfg:series). R.ymax is the max over FINITE values only
% (Inf/-Inf discarded), clamped >= 0 so a negative-only series (QC can
% retain a stable negative SWE) never produces a decreasing ylim; NaN when
% nothing finite. The render's ruler is ylim [0, R.ymax*1.1 + R.pad].
    switch char(series)
        case 'depth'
            R = struct('label', 'Snow depth (m)', 'color', [0.8 0 0], ...
                       'pad', 0.1);
        case 'swe'
            R = struct('label', 'SWE [mm]', 'color', [0.00 0.60 0.45], ...
                       'pad', 100);
        otherwise
            error('soop:wx_axis_cfg:series', ...
                  'Unknown weather series ''%s''.', char(series));
    end
    v = vals(isfinite(vals));
    if isempty(v)
        R.ymax = NaN;
    else
        R.ymax = max(max(v), 0);
    end
end


function P = wx_axes_plan(show_dep, show_swe, want_temp, hour_on, soil_on, ...
                          snowtemp_on)
% Deterministic axes/colorbar geometry + right-ruler ownership for the
% candidates figure (normalized panel units; the render never reads live
% Position values):
%   .right   — 'depth' | 'swe' | 'none': series owning the yyaxis ruler
%              (depth when shown; SWE only when depth is off)
%   .swe_ovl — SWE needs its own overlay axes (both series shown)
%   .ax_pos  — main axes [x y w h]; a bottom strip is reserved for the
%              point-color bar (hour or SNR) when hour_on
%   .cb_pos  — manual point-colorbar strip ([] when hour_on is false);
%              pinning the colorbar Position stops MATLAB's auto-layout
%              from shrinking ax after ax_pos was chosen
%   .swe_w / .tmp_w — overlay axes widths: ruler slots step out by SLOT_W
%              (SWE inner, temperatures outer)
%   .soil_w  — soil-moisture overlay width on the SnowTemp axes ([] when
%              soil_on is false). Its ruler takes a slot reclaimed from the
%              axes width, so BOTH stacked axes narrow together and stay
%              x-aligned instead of the ruler overrunning the panel edge
%   .dtc_cb_gap — gap from the SnowTemp axes right edge to its temperature
%              colorbar, widened to clear the soil ruler when soil_on
%
% snowtemp_on reserves the right margin for the SnowTemp colorbar ASSEMBLY —
% strip plus its tick labels plus its rotated axis label, which are drawn
% outside the strip and are otherwise clipped at the panel edge. Reserving it
% narrows BOTH stacked axes together: they are linkaxes'd on x, so unequal
% widths would map the same date to different horizontal positions and make
% the phase trace unreadable against the thermograph below it.
    P.swe_ovl = show_dep && show_swe;
    if show_dep
        P.right = 'depth';
    elseif show_swe
        P.right = 'swe';
    else
        P.right = 'none';
    end
    if nargin < 5, soil_on = false; end
    if nargin < 6, snowtemp_on = false; end
    SLOT_W = 0.06;   % per-ruler right-margin slot (spine-to-spine gap)
    % SnowTemp colorbar assembly: gap + strip + tick labels + rotated label.
    CB_W = 0.10;
    axW = 0.86 - 2 * SLOT_W * ...
          (double(P.swe_ovl) + double(want_temp) + double(soil_on)) ...
          - CB_W * double(snowtemp_on);
    if hour_on
        P.ax_pos = [0.09 0.25 axW 0.68];
        P.cb_pos = [0.09 0.11 axW 0.04];
    else
        P.ax_pos = [0.09 0.13 axW 0.80];
        P.cb_pos = [];
    end
    P.swe_w = axW + SLOT_W;
    P.tmp_w = axW + SLOT_W * (1 + double(P.swe_ovl));
    if soil_on
        P.soil_w = axW + SLOT_W;
        % Clear the full slot (spine step + tick-label margin) so the soil
        % ruler's labels are not crowded by the colorbar strip.
        P.dtc_cb_gap = 0.015 + 2 * SLOT_W;
    else
        P.soil_w     = [];
        P.dtc_cb_gap = 0.015;
    end
end


function mm = swe_per_fringe_mm(freq_hz, theta_inc_deg)
% SWE change per 360° of differential reflected phase (one fringe), in mm.
% From R. Shah, X. Xu, S. Yueh, C. S. Chae, K. Elder, B. Starr, and
% Y. Kim, "Remote Sensing of Snow Water Equivalent Using P-Band Coherent
% Reflection," IEEE Geoscience and Remote Sensing Letters, vol. 14, no. 3,
% pp. 309-313, Mar. 2017, doi:10.1109/LGRS.2016.2636664 — Eq. (6):
% dphi = (a/cos(theta_inc)) * f * SWE, i.e. phase rate
% scales with f/cos(theta_inc), so
%   SWE_fringe(f, theta) = 606 mm * (260 MHz / f) * cos(theta)/cos(43°).
% Calibration anchor: §II of that paper — "at 260 MHz and 43° incidence,
% ~606 mm of SWE per 360°" (the user-selected reference model; the same
% paper's §IV multilayer model gives ~530 mm/fringe and its experimental
% regression ~504 — different model outputs, recorded here, not used).
% Guards: f must be a real positive finite numeric scalar; theta_inc a real
% numeric scalar in [0, 90) degrees (negative incidence rejected). Invalid
% input returns NaN (fail closed — the overlay simply doesn't draw).
    SWE_FRINGE_REF_MM = 606;      % mm per fringe at the reference point
    F_REF_HZ          = 260e6;    % reference frequency
    THETA_REF_DEG     = 43;       % reference incidence angle
    ok = isnumeric(freq_hz) && isscalar(freq_hz) && isreal(freq_hz) && ...
         isfinite(freq_hz) && freq_hz > 0 && ...
         isnumeric(theta_inc_deg) && isscalar(theta_inc_deg) && ...
         isreal(theta_inc_deg) && isfinite(theta_inc_deg) && ...
         theta_inc_deg >= 0 && theta_inc_deg < 90;
    if ~ok, mm = NaN; return; end
    mm = SWE_FRINGE_REF_MM * (F_REF_HZ / double(freq_hz)) * ...
         (cosd(double(theta_inc_deg)) / cosd(THETA_REF_DEG));
end


function [mm, manual] = fringe_pick(txt, auto_mm)
% Active SWE-per-fringe rate for the theoretical overlay: the side-panel
% override field wins when it parses to a positive finite number, else the
% geometry-computed auto value. Pure and testable. manual reports which one
% won (the legend shows the active rate either way).
    v = str2double(strtrim(txt));
    manual = isfinite(v) && isreal(v) && v > 0;
    if manual, mm = v; else, mm = auto_mm; end
end


function O = theory_overlay(cand_t, cand_phi, wx_t, wx_swe, mode, fringe_mm, wrap_out)
% Theoretical differential-phase overlay for the L2: Candidates figures:
% the snow-scale SWE record converted to phase via the fringe rate, anchored
% to a MEASURED phase reference so it overlays the plotted points (the
% measured phase carries arbitrary chain offsets — a zero-at-anchor curve
% would float unrelated to the data). Pure and testable; the render draws
% O.t/O.phi_deg only when O.ok.
%   cand_t/cand_phi — DISPLAYED candidate times and phases (post SNR/TOD/
%                     range selection, timestamp-sorted; NaN phases allowed)
%   wx_t/wx_swe     — the FULL weather record (times must be sorted; the
%                     season-level anchor must not move with the date range)
%   mode            — 'swe0' (snow-free start) | 'first' (first shown)
%   fringe_mm       — swe_per_fringe_mm output
%   wrap_out        — optional (default true): wrap the output to ±180 for
%                     the wrapped views; false leaves the curve continuous
%                     across fringes for the unwrapped views. Scalar logical
%                     or numeric 0/1 only (caller-bug error otherwise:
%                     soop_viewer_util:theory_overlay:wrap_out).
% Contract:
%   phi(t) = wrap180(phase_ref + 360*(SWE(t) - SWE_anchor)/fringe_mm) at
%   EVERY non-NaT weather timestamp (wrap180 skipped when wrap_out is
%   false) — O.t keeps the full chronology and
%   invalid-SWE rows return NaN phase, so the drawn line BREAKS across
%   sensor/QC gaps instead of bridging them. Raw 15-min curve in every agg
%   mode (never aggregated), paper-positive sign (legend labels it).
%   'swe0': SWE_anchor = first run of 4 consecutive VALID |SWE| <= 10 mm
%   samples that also spans <= 2 h of clock time (true 1-h support at the
%   15-min cadence: an invalid row or a timestamp gap splits the run;
%   rejects negatives beyond +-10 and isolated lows); no such run ->
%   record-start fallback (first valid sample) with O.anchor_note =
%   ', record-start anchor' (user-accepted, made visible). phase_ref =
%   finite displayed phase nearest the anchor time, <= 7 days.
%   'first': phase_ref = first finite displayed phase; SWE_anchor = nearest
%   valid SWE sample to that capture, <= 2 h.
%   Any missing piece — including mismatched cand_t/cand_phi or
%   wx_t/wx_swe lengths — -> O.ok = false with O.why (never an error,
%   except an unknown mode, a caller bug:
%   soop_viewer_util:theory_overlay:mode).
    O = struct('ok', false, 'why', '', 't', [], 'phi_deg', [], 'anchor_note', '');
    if ~any(strcmp(mode, {'swe0', 'first'}))
        error('soop_viewer_util:theory_overlay:mode', ...
              'theory_overlay: unknown mode "%s".', mode);
    end
    if nargin < 7
        wrap_out = true;
    elseif ~(isscalar(wrap_out) && (islogical(wrap_out) || ...
             (isnumeric(wrap_out) && isreal(wrap_out) && any(wrap_out == [0 1]))))
        error('soop_viewer_util:theory_overlay:wrap_out', ...
              'theory_overlay: wrap_out must be a scalar logical or 0/1.');
    end
    if ~(isnumeric(fringe_mm) && isscalar(fringe_mm) && isreal(fringe_mm) && ...
         isfinite(fringe_mm) && fringe_mm > 0)
        O.why = 'no valid fringe rate'; return;
    end
    wx_t = wx_t(:);  wx_swe = double(wx_swe(:));
    cand_t = cand_t(:);  cand_phi = double(cand_phi(:));
    if numel(wx_t) ~= numel(wx_swe) || numel(cand_t) ~= numel(cand_phi)
        O.why = 'mismatched input lengths'; return;
    end
    % Full weather chronology (non-NaT only); validity mask per row.
    keep = ~isnat(wx_t);
    tw = wx_t(keep);  sw = wx_swe(keep);
    val = isfinite(sw);
    fin_c = ~isnat(cand_t) & isfinite(cand_phi);
    if ~any(val), O.why = 'no finite SWE samples'; return; end
    if ~any(fin_c), O.why = 'no finite displayed phase'; return; end
    tcnd = cand_t(fin_c);  pcnd = cand_phi(fin_c);
    n = numel(tw);
    if strcmp(mode, 'swe0')
        % Run test on the UNCOMPRESSED rows: 4 consecutive valid near-zero
        % samples whose clock span is <= 2 h (movsum shrinks at the tail,
        % so short records simply find no run and take the fallback).
        nearz = val & abs(sw) <= 10;
        i0 = [];
        if n >= 4
            cnt = movsum(nearz, [0 3]);
            cand_i = find(nearz(1:n-3) & cnt(1:n-3) == 4 & ...
                          (tw(4:n) - tw(1:n-3)) <= hours(2), 1);
            if ~isempty(cand_i), i0 = cand_i; end
        end
        if isempty(i0)
            i0 = find(val, 1);             % record-start fallback (visible)
            O.anchor_note = ', record-start anchor';
        end
        t_anchor = tw(i0);  swe_anchor = sw(i0);
        [dmin, ic] = min(abs(tcnd - t_anchor));
        if dmin > days(7)
            O.why = 'no displayed phase near the snow-free anchor'; return;
        end
        phase_ref = pcnd(ic);
    else                                   % 'first'
        phase_ref = pcnd(1);
        dt = abs(tw - tcnd(1));
        dt(~val) = seconds(Inf);           % anchor only on valid samples
        [dmin, iw] = min(dt);
        if dmin > hours(2)
            O.why = 'no SWE sample near the first shown capture'; return;
        end
        swe_anchor = sw(iw);
    end
    O.t = tw;
    O.phi_deg = nan(n, 1);
    O.phi_deg(val) = phase_ref + 360 * (sw(val) - swe_anchor) / fringe_mm;
    if wrap_out
        O.phi_deg(val) = wrap_deg(O.phi_deg(val));
    end
    O.ok = true;
end


function u = unwrap_deg(t, y_deg)
% Unwrap a wrapped-degree series along its timestamps: sorts by time
% (stable — equal timestamps keep input order), unwraps the finite samples
% with MATLAB unwrap's branch rule (an absolute jump STRICTLY greater than
% 180° between consecutive kept samples is folded by ±360°; exactly ±180°
% is preserved), and returns values in the INPUT order with the shape of
% y_deg. NaN/Inf samples and NaT
% timestamps come back as NaN and do NOT break the branch — the unwrap
% continues across data gaps of any length, so one ambiguous post-gap
% transition (true phase change > 180° between kept samples) shifts every
% later value by n*360°. Display-side transform only (product CSVs stay
% wrapped). Row-order invariance holds only while the finite timestamps
% are distinct. Pure — headlessly testable. Length mismatch is a caller
% bug: soop:unwrap_deg:length.
    if numel(t) ~= numel(y_deg)
        error('soop:unwrap_deg:length', ...
              'unwrap_deg: t and y_deg must have equal lengths.');
    end
    u  = nan(size(y_deg));
    tv = t(:);
    yv = double(y_deg(:));                 % columnize: row input stays 1-D
    [~, ord] = sort(tv);                   % stable: ties keep input order
    ys = yv(ord);
    f  = isfinite(ys) & ~isnat(tv(ord));
    ys(f)  = rad2deg(unwrap(deg2rad(ys(f))));
    ys(~f) = NaN;
    u(ord) = ys;
end


function ok = snrcut_usable(T)
% True when the candidates table can be SNR-filtered for display: a nonempty
% table with a real numeric snr_db column. Drives the side-panel spinner's
% Enable state — a disabled spinner means the loaded candidate product
% predates the snr_db column and must be regenerated to filter.
    ok = ~isempty(T) && istable(T) && ...
         ismember('snr_db', T.Properties.VariableNames) && ...
         isnumeric(T.snr_db) && isreal(T.snr_db);
end


function [T, ok] = snrcut_apply(T, cut)
% Display SNR cutoff, the EXACT producer predicate (compare_sat_candidates):
% keep rows with isfinite(snr_db) & snr_db >= cut, row order preserved —
% NaN and both infinities drop, matching the pipeline's finite-SNR gate.
% Fail-safe: an unusable table (see snrcut_usable) or an invalid cutoff
% (non-scalar / non-finite / non-numeric) returns the input unchanged with
% ok = false; never an operator error.
    ok = snrcut_usable(T) && isnumeric(cut) && isscalar(cut) && ...
         isreal(cut) && isfinite(cut);
    if ~ok, return; end
    T = T(isfinite(T.snr_db) & T.snr_db >= cut, :);
end


function [bases, ok, src] = ovf_load(cfg, base_out_dir)
% Resolve and read the overflow capture list (find_overflows output).
% Path precedence: cfg.overflow_file (stable season input, decoupled from
% out_dir) when set and present; else <cfg.out_dir>/overflow_timestamps.txt;
% else <base_out_dir>/overflow_timestamps.txt (shared input). ok = a file
% was FOUND — an empty file is ok = true with zero bases ("known zero
% overflows"), distinct from ok = false ("membership unknowable"), which
% disables the candidates-family overflow checkbox. src = the resolved
% path, "" when none found. Pure except for the file reads — headlessly
% testable with temp dirs.
    bases = strings(0, 1);
    ok    = false;
    src   = "";
    p = "";
    if isfield(cfg, 'overflow_file') && ~isempty(cfg.overflow_file) ...
            && isfile(cfg.overflow_file)
        p = string(cfg.overflow_file);
    else
        cand = fullfile(cfg.out_dir, 'overflow_timestamps.txt');
        if isfile(cand)
            p = string(cand);
        elseif nargin > 1 && ~isempty(base_out_dir)
            cand = fullfile(char(base_out_dir), 'overflow_timestamps.txt');
            if isfile(cand), p = string(cand); end
        end
    end
    if p == "", return; end
    lines = strtrim(readlines(p));
    bases = lines(strlength(lines) > 0);
    ok    = true;
    src   = p;
end


function m = ovf_mask(T, ovf_bases)
% Logical column mask of candidate rows whose base_name is in the overflow
% list. All-false (never an error) when the table is empty, lacks
% base_name, or the list is empty — operator input must not break a
% render. Row order preserved.
    if isempty(T) || ~istable(T) || ...
            ~ismember('base_name', T.Properties.VariableNames) || ...
            isempty(ovf_bases)
        if istable(T), n = height(T); else, n = 0; end
        m = false(n, 1);
        return;
    end
    m = ismember(string(T.base_name), string(ovf_bases));
    m = m(:);
end


function ok = ovf_usable(T, ovf_ok)
% True when the overflow display filter can act: an overflow list file was
% found (ovf_ok, see ovf_load) AND the candidates table has a base_name
% column of the text types ovf_mask matches on (string / cellstr). Drives
% the checkbox Enable state and gates both exclusion and marking in the
% render — a checked-but-unusable box must never silently filter.
    ok = (islogical(ovf_ok) || isnumeric(ovf_ok)) && isscalar(ovf_ok) && ...
         logical(ovf_ok) && ~isempty(T) && istable(T) && ...
         ismember('base_name', T.Properties.VariableNames) && ...
         (isstring(T.base_name) || iscellstr(T.base_name));
end


function v = snrcut_start(cfg)
% Validated starting value for the SNR-cutoff spinner: cfg.snr_threshold
% (the producer's scoring floor) when it is a real finite numeric scalar,
% else 10 (the pipeline default). The candidates CSV does not record its
% production cutoff, which may differ from this configured starting value.
    v = 10;
    if isfield(cfg, 'snr_threshold')
        t = cfg.snr_threshold;
        if isnumeric(t) && isscalar(t) && isreal(t) && isfinite(t)
            v = double(t);
        end
    end
end


function G = dtc_thermograph(t, depth_m, dtc_c, cfg)
% Shape DTC observations into a time-height temperature field. Sensor rows are
% top-to-bottom by default; heights are centimeters above ground, so the
% sensors buried in the soil carry NEGATIVE heights and the cable is treated
% as hanging straight down. The field spans the bottom sensor up to the SNOdar
% snow surface and is NaN above that surface or across missing DTC records.
    G = struct('ok', false, 'why', '', 't', [], 'height_cm', [], ...
               'temp_c', [], 'sensor_h', [], 'ground_row', []);
    if ~isdatetime(t) || ~isnumeric(depth_m) || ~isnumeric(dtc_c) || ...
            numel(t) ~= numel(depth_m) || size(dtc_c, 1) ~= numel(t)
        G.why = 'DTC and snow-depth records have incompatible shapes.';
        return;
    end
    if isempty(t) || isempty(dtc_c) || ~any(isfinite(dtc_c(:)))
        G.why = 'No finite DTC snow-temperature observations in this date range.';
        return;
    end
    % Sensor count comes from the data, not a constant — cable lengths differ
    % between sites while the sensor spacing does not.
    Q = dtc_geometry(cfg, size(dtc_c, 2));
    if ~Q.ok
        G.why = Q.why;
        return;
    end
    sensor_h = Q.sensor_h;
    depth_cm = 100 * double(depth_m(:));
    max_depth = max(depth_cm(isfinite(depth_cm) & depth_cm >= 0));
    if isempty(max_depth) || max_depth <= 0
        G.why = 'No finite positive snow depth in this date range.';
        return;
    end
    % Grid spans the buried sensors through the deepest snow surface in range,
    % at 1 cm steps, with both end heights represented exactly. A snow surface
    % at or below the lowest sensor collapses the grid to one height, which has
    % no drawable vertical extent — fail closed rather than hand the renderer a
    % degenerate single-row field.
    h_lo = min(sensor_h);
    if ~dtc_has_extent(max_depth, sensor_h)
        G.why = 'Snow surface is at or below the lowest DTC sensor — no vertical extent to draw.';
        return;
    end
    height_cm = unique([h_lo, ceil(h_lo):floor(max_depth), max_depth])';
    temp_c = nan(numel(height_cm), numel(t));
    for k = 1:numel(t)
        v = double(dtc_c(k, :));
        nodes = dtc_nodes(v, sensor_h, depth_cm(k));
        if sum(nodes) < 2
            continue;   % unrenderable record stays a blank column
        end
        [h, ix] = sort(sensor_h(nodes));
        vg = v(nodes);
        z = interp1(h, vg(ix), height_cm, 'linear', NaN);
        z(height_cm > depth_cm(k)) = NaN;   % air above the snow stays blank
        temp_c(:, k) = z;
    end
    if ~any(isfinite(temp_c(:)))
        G.why = 'DTC sensors do not overlap the measured snowpack in this date range.';
        return;
    end
    G.ok = true;
    G.t = t(:)';
    G.height_cm = height_cm;
    G.temp_c = temp_c;
    G.sensor_h = sensor_h;
    G.ground_row = any(sensor_h < 0);   % true when soil sensors are present
end


function v = dtc_cfg(cfg, field, fallback)
% Read a finite scalar DTC geometry parameter with a documented fallback.
    v = fallback;
    if isfield(cfg, field) && isnumeric(cfg.(field)) && ...
            isscalar(cfg.(field)) && isfinite(cfg.(field))
        v = double(cfg.(field));
    end
end


function Q = dtc_geometry(cfg, n_sensor)
% Resolve DTC sensor heights in cm above ground for a cable of n_sensor
% sensors. Spacing is constant between sites; cable length is not, so the
% count is supplied by the caller from the data. A negative bottom height
% means the lowest sensors are buried in the soil.
    Q = struct('ok', false, 'why', '', 'sensor_h', [], ...
               'spacing_cm', NaN, 'bottom_cm', NaN);
    spacing_cm = dtc_cfg(cfg, 'wx_dtc_sensor_spacing_cm', 10.16);
    bottom_cm  = dtc_cfg(cfg, 'wx_dtc_bottom_height_cm', 0);
    order = 'top_to_bottom';
    if isfield(cfg, 'wx_dtc_order') && ~isempty(cfg.wx_dtc_order)
        order = lower(char(cfg.wx_dtc_order));
    end
    if ~(isfinite(spacing_cm) && spacing_cm > 0 && isfinite(bottom_cm))
        Q.why = 'DTC geometry configuration is invalid.';
        return;
    end
    if ~(isscalar(n_sensor) && isfinite(n_sensor) && n_sensor >= 1)
        Q.why = 'DTC sensor count is invalid.';
        return;
    end
    switch order
        case 'top_to_bottom'
            Q.sensor_h = bottom_cm + (n_sensor-1:-1:0) * spacing_cm;
        case 'bottom_to_top'
            Q.sensor_h = bottom_cm + (0:n_sensor-1) * spacing_cm;
        otherwise
            Q.why = 'DTC sensor ordering must be top_to_bottom or bottom_to_top.';
            return;
    end
    Q.ok = true;
    Q.spacing_cm = spacing_cm;
    Q.bottom_cm  = bottom_cm;
end


function nodes = dtc_nodes(v, sensor_h, depth_cm)
% Interpolation nodes for one DTC record: every finite sensor at or below the
% snow surface, PLUS the lowest finite sensor above it. That bracketing node is
% what lets the field reach the surface instead of stopping at the topmost
% buried sensor and leaving an uncolored band. THE ONE place this rule lives —
% dtc_thermograph and dtc_renderable both call it so they cannot disagree about
% which records are renderable.
    nodes = false(1, numel(sensor_h));
    if numel(v) ~= numel(sensor_h)
        return;
    end
    good = isfinite(v(:)');
    if ~isfinite(depth_cm) || ~any(good)
        return;
    end
    nodes = good & (sensor_h <= depth_cm);
    above = find(good & (sensor_h > depth_cm));
    if ~isempty(above)
        [~, ia] = min(sensor_h(above));
        nodes(above(ia)) = true;
    end
end


function ok = dtc_renderable(depth_m, dtc_c, cfg)
% Per-record mask of DTC observations that dtc_thermograph can actually draw:
% finite positive snow depth and at least two interpolation nodes. Used to pick
% nearest-mode matches so a blank profile cannot win over a farther drawable
% one. Returns a logical column aligned with the rows of dtc_c.
    n_rec = size(dtc_c, 1);
    ok = false(n_rec, 1);
    if n_rec == 0 || isempty(dtc_c) || numel(depth_m) ~= n_rec
        return;
    end
    Q = dtc_geometry(cfg, size(dtc_c, 2));
    if ~Q.ok
        return;
    end
    % Positive depth, a drawable vertical extent, AND two nodes: shaping a
    % single record needs all three, so this predicts exactly what
    % dtc_thermograph returns for that row on its own.
    depth_cm = 100 * double(depth_m(:));
    for k = 1:n_rec
        ok(k) = depth_cm(k) > 0 && ...
            dtc_has_extent(depth_cm(k), Q.sensor_h) && ...
            sum(dtc_nodes(double(dtc_c(k, :)), Q.sensor_h, depth_cm(k))) >= 2;
    end
end


function tf = dtc_has_extent(depth_cm, sensor_h)
% True when a snow surface at depth_cm leaves a drawable vertical span above
% the lowest sensor. Shared by dtc_thermograph and dtc_renderable so a profile
% can never be declared renderable and then collapse to a single height row.
    tf = isfinite(depth_cm) && depth_cm > min(sensor_h);
end


function G = soil_geometry(cfg)
% Resolve the SoilVUE overlay's rod geometry and legend labels from cfg.
% cfg.wx_soil_rod_cm holds ROD POSITIONS in cm — the numbers the logger headers
% carry — and cfg.wx_soil_surface_rod_cm is the rod position of the soil
% surface, so depth below ground is rod position minus surface position. THE ONE
% place that subtraction lives, so labels and gating cannot disagree. Order is
% the configured order, which is the column order of WX.soil_vwc.
%
% FAIL-CLOSED: a rod list that is duplicated, non-increasing, or at/above the
% surface, or a missing/invalid surface position, disables the overlay instead
% of drawing. Every one of those cases would attach wrong depth semantics to
% otherwise-valid data — the surface offset is what separates rod positions
% (what the headers name) from depth below ground (what the labels claim), and
% inventing a reference plane silently relabels rod 60 cm as "60 cm deep".
    G = struct('ok', false, 'why', '', 'rod_cm', [], 'depth_cm', [], ...
               'surface_cm', NaN, 'labels', {{}});
    if ~isfield(cfg, 'wx_soil_rod_cm') || isempty(cfg.wx_soil_rod_cm) || ...
            ~isnumeric(cfg.wx_soil_rod_cm)
        G.why = 'Soil rod positions are not configured.';
        return;
    end
    rod = cfg.wx_soil_rod_cm(:)';
    if ~isreal(rod) || ~all(isfinite(rod))
        G.why = 'Soil rod positions must all be real and finite.';
        return;
    end
    rod = double(rod);
    if numel(unique(rod)) ~= numel(rod)
        G.why = 'Soil rod positions must be unique.';
        return;
    end
    % Strictly increasing: the color ramp darkens with configured order, so a
    % descending list would contradict the shading the legend implies.
    if numel(rod) > 1 && any(diff(rod) <= 0)
        G.why = 'Soil rod positions must be strictly increasing.';
        return;
    end
    if ~isfield(cfg, 'wx_soil_surface_rod_cm') || isempty(cfg.wx_soil_surface_rod_cm)
        G.why = 'Soil surface rod position is not configured.';
        return;
    end
    surface = cfg.wx_soil_surface_rod_cm;
    if ~(isnumeric(surface) && isscalar(surface) && isreal(surface) && isfinite(surface))
        G.why = 'Soil surface rod position is invalid.';
        return;
    end
    surface = double(surface);
    depth = rod - surface;                  % below ground, positive downward
    if any(depth <= 0)
        G.why = 'Soil rod positions must all sit below the surface position.';
        return;
    end
    G.rod_cm     = rod;
    G.surface_cm = surface;
    G.depth_cm   = depth;
    % Labels carry '~' because the surface position is surveyed only
    % approximately, so the derived depth is approximate too.
    G.labels     = arrayfun(@(d) sprintf('~%g cm', d), G.depth_cm, ...
                            'UniformOutput', false);
    G.ok = true;
end


function ok = soil_usable(WX, cfg)
% True when the soil-moisture overlay has something to draw: configured rod
% geometry, a soil_vwc column whose width matches that geometry, and at least
% one finite value. A width mismatch fails rather than drawing, because the
% column order carries the depth labels — mislabeled depths would be worse than
% no overlay. Segments in air or snow read exactly 0 (below the sensor's
% calibrated permittivity range), which is finite and legitimately drawable.
    ok = false;
    if ~istable(WX) || ~ismember('soil_vwc', WX.Properties.VariableNames)
        return;
    end
    G = soil_geometry(cfg);
    if ~G.ok
        return;
    end
    v = WX.soil_vwc;
    ok = isnumeric(v) && size(v, 2) == numel(G.rod_cm) && any(isfinite(v(:)));
end


function c = soil_color(k)
% Line color for the k-th soil-moisture depth, cycling through an earth-toned
% ramp that darkens with depth. Distinct from the DTC thermograph's diverging
% temperature map and from the teal SWE / black depth overlay lines.
    ramp = [0.72 0.53 0.24;    % shallowest — light ochre
            0.55 0.36 0.16;
            0.36 0.22 0.09];   % deepest — dark brown
    if ~(isnumeric(k) && isscalar(k) && isfinite(k) && k >= 1)
        c = ramp(1, :);
        return;
    end
    c = ramp(mod(round(k) - 1, size(ramp, 1)) + 1, :);
end


function cl = dtc_clim_order(lo, hi, moved, span, step)
% Restore low < high for the SnowTemp color-scale spinners after one of them
% moved, returning the corrected [low high]. The spinner named by `moved`
% ('lo' or 'hi') keeps its value and its PARTNER gives way, so the edit the
% user just made survives. Both share the same travel, so the nudge can
% saturate; when it does, the moved spinner yields instead, which always
% leaves an ordered pair inside span.
    lo = double(lo);  hi = double(hi);
    if hi > lo
        cl = [lo hi];
        return;
    end
    if strcmp(moved, 'lo')
        hi = min(span(2), lo + step);
        if hi <= lo, lo = hi - step; end
    else
        lo = max(span(1), hi - step);
        if lo >= hi, hi = lo + step; end
    end
    cl = [lo hi];
end


function cl = dtc_clim(lo, hi, default_cl)
% Validated SnowTemp thermograph color limits in degrees C, [low high].
% The spinner handler already keeps the pair ordered, so this is the render's
% own re-check: any non-real, nonfinite, non-scalar, or non-ascending pair
% falls back to default_cl rather than reaching clim(), which errors on a
% non-increasing range and would take the whole figure down with it.
    cl = default_cl;
    ok = @(v) isnumeric(v) && isscalar(v) && isreal(v) && isfinite(v);
    if ok(lo) && ok(hi) && double(hi) > double(lo)
        cl = [double(lo) double(hi)];
    end
end


function s = soil_linestyle(k)
% Line style for the k-th soil-moisture depth. Redundant with soil_color so
% depth stays readable in grayscale print and to color-blind viewers; cycles
% on the same period as the color ramp, keeping style and color paired.
    styles = {'-', '--', ':'};
    if ~(isnumeric(k) && isscalar(k) && isfinite(k) && k >= 1)
        s = styles{1};
        return;
    end
    s = styles{mod(round(k) - 1, numel(styles)) + 1};
end


function wx_idx = nearest_wx_idx(t_capture, t_wx, valid, win)
% Match each collection to its nearest USABLE weather observation. A match
% counts when its absolute time offset is <= win; `valid` lets the caller
% define usable (e.g. renderable DTC profiles) instead of hardcoding a rule
% here. Equal-time distances choose the earlier weather timestamp, then the
% earlier row. Output is a column aligned with t_capture; unmatched values
% are 0.
    if ~isdatetime(t_capture) || ~isdatetime(t_wx)
        error('soop_viewer_util:nearest_wx_idx:type', ...
              'nearest_wx_idx: t_capture and t_wx must be datetimes.');
    end
    t_capture = t_capture(:);
    t_wx = t_wx(:);
    if ~islogical(valid) || numel(valid) ~= numel(t_wx)
        error('soop_viewer_util:nearest_wx_idx:valid', ...
              'nearest_wx_idx: valid must be logical with one element per t_wx.');
    end
    valid = valid(:);
    if ~isduration(win) || ~isscalar(win) || ...
            ~isfinite(seconds(win)) || win < seconds(0)
        error('soop_viewer_util:nearest_wx_idx:window', ...
              'nearest_wx_idx: win must be a finite nonnegative duration.');
    end
    if xor(isempty(t_capture.TimeZone), isempty(t_wx.TimeZone))
        error('soop_viewer_util:nearest_wx_idx:timezone', ...
              'Collection and weather datetimes must both be zoned or both unzoned.');
    end

    wx_idx = zeros(numel(t_capture), 1);
    orig = (1:numel(t_wx))';
    keep = ~isnat(t_wx) & valid;
    W = table(t_wx(keep), orig(keep), 'VariableNames', {'t', 'orig'});
    W = sortrows(W, {'t', 'orig'});
    for k = 1:numel(t_capture)
        if isnat(t_capture(k)) || isempty(W), continue; end
        [dist, j] = min(abs(W.t - t_capture(k)));
        if dist <= win
            wx_idx(k) = W.orig(j);
        end
    end
end


function B = snowtemp_nearest_bands(t_cap, wx_idx, WX, cfg)
% Shape one DTC profile per kept capture for SnowTemp - Nearest mode.
% Each matched weather row is shaped on its own through dtc_thermograph, so
% surface bracketing and above-snow masking are identical to the continuous
% field. Bands are keyed to the CAPTURE time (not the observation time) so they
% line up with the phase markers above, and are emitted in capture-time order.
% No deduplication: two captures may legitimately share one nearest profile.
    B = struct('on', false, 't_cap', datetime.empty(0, 1), 'cols', {{}}, ...
               'height_cm', [], 'h_lo', NaN, 'h_hi', NaN, 'ground_row', false);
    t_cap = t_cap(:);
    wx_idx = wx_idx(:);
    if isempty(t_cap) || numel(wx_idx) ~= numel(t_cap)
        return;
    end
    [t_sorted, order] = sort(t_cap);
    wx_sorted = wx_idx(order);
    cols = {};
    h_lo = Inf;  h_hi = -Inf;  ground = false;
    for k = 1:numel(t_sorted)
        r = wx_sorted(k);
        if r < 1 || r > height(WX), continue; end
        G = dtc_thermograph(WX.timestamp(r), WX.depth_m(r), WX.dtc_c(r, :), cfg);
        if ~G.ok, continue; end
        cols{end+1} = struct('t', t_sorted(k), ...
                             'height_cm', G.height_cm, ...
                             'temp_c', G.temp_c(:, 1)); %#ok<AGROW>
        h_lo = min(h_lo, min(G.height_cm));
        h_hi = max(h_hi, max(G.height_cm));
        ground = ground || G.ground_row;
    end
    if isempty(cols)
        return;
    end
    B.on = true;
    B.cols = cols;
    B.t_cap = cellfun(@(c) c.t, cols).';
    B.h_lo = h_lo;
    B.h_hi = h_hi;
    B.height_cm = [h_lo; h_hi];
    B.ground_row = ground;
end


function half = band_halfwidth(t0, t1, ax_px, band_px)
% Half-width, as a duration, of a fixed-PIXEL-width band on a datetime axis.
% Width is specified in pixels (not points) so it needs no DPI conversion and
% stays meaningful headless. Falls back to a small fraction of the span when
% the axes width or span is unusable, so a band is always visible.
    span = t1 - t0;
    fallback = 0.002;   % fraction of the x-span when pixel geometry is unusable
    if ~isduration(span) || ~isfinite(seconds(span)) || span <= seconds(0)
        half = seconds(0);
        return;
    end
    usable = isnumeric(ax_px) && isscalar(ax_px) && isfinite(ax_px) && ax_px > 0 ...
        && isnumeric(band_px) && isscalar(band_px) && isfinite(band_px) && band_px > 0;
    if ~usable
        half = 0.5 * fallback * span;
        return;
    end
    half = 0.5 * min(double(band_px) / double(ax_px), 1) * span;
end


function [L, full] = wx_temp_labels(cfg)
% Display strings for the two temperature overlays — the ONE source of
% truth for both the row-1 checkbox Text and the render legend entries.
% Defaults to the Brundage headers; cfg.wx_temp_cols overrides per site
% (blank entries keep their default — the same per-entry fallback
% load_snodar applies, so the label always names the column actually
% loaded). `full` returns the untruncated names for tooltips. Long names
% are MIDDLE-truncated to 13 display chars (first 6 + '…' + last 6) — the
% layout policy bounding the row-1 'fit' columns within the 1500 px budget
% (pinned by the worst-case replica test) while keeping the distinguishing
% suffixes station schemes put at the end (..._2m_Avg vs ..._Srf_Avg).
    L = {'AirTC_Avg', 'Temp_C_Avg'};
    if isfield(cfg, 'wx_temp_cols') && numel(cfg.wx_temp_cols) >= 2
        c = cellstr(cfg.wx_temp_cols);
        for k = 1:2
            if ~isempty(strtrim(c{k})), L{k} = strtrim(c{k}); end
        end
    end
    full = L;
    for k = 1:2
        if numel(L{k}) > 13
            L{k} = [L{k}(1:6) char(8230) L{k}(end-5:end)];
        end
    end
end

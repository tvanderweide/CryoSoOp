function soop_viewer_layout(V)
% Build the viewer uifigure and wire controls to callbacks that capture V.
    S = V;
    cfg = V.cfg;
    COMPARE_DATASET = V.COMPARE_DATASET;
    CHAINCAL_DATASET = V.CHAINCAL_DATASET;
    PLOT_INFO = V.PLOT_INFO;
    cfgdef = @(varargin) V.U.cfgdef(V, varargin{:});
    % ---- Figure & layout ----
    % 1500 px wide: row 1 declares 15 columns (10 fixed = 946 px + 14 gaps
    % at 5 px + five fit-width weather checkboxes ~450 px) and must fit at
    % the initial size — see the r1 budget note below.
    S.fig = uifigure('Name', 'Brundage SoOp Viewer', 'Position', [80 80 1500 720]);
    gl = uigridlayout(S.fig, [4 1]);
    V.gl = gl;
    gl.RowHeight = {38, 38, 0, '1x'};   % row 3 = RFI explorer controls, collapsed by default
    gl.Padding   = [8 8 8 8];

    % Row 1 — plot type, aggregation, date range, action buttons, wx toggles
    % 15 children (10 controls + 5 weather checkboxes) — the grid must declare
    % all 15 columns, or the extras wrap onto an auto-added second row that
    % cannot fit in the fixed 38 px outer cell and the whole row clips.
    % Pixel budget at the 1500 px initial width: 946 fixed + 14x5 spacing
    % + ~450 for the fit checkboxes = ~1466 <= 1484 interior (pinned by the
    % row-1 replica test in viewer_swe_phaseline_test).
    r1 = uigridlayout(gl, [1 15]);
    r1.Layout.Row = 1;
    r1.ColumnWidth = {250, 120, 36, 105, 22, 105, 80, 80, 64, 84, 'fit', 'fit', 'fit', 'fit', 'fit'};
    r1.ColumnSpacing = 5;
    r1.Padding = [0 0 0 0];

    S.dd_plot = uidropdown(r1, 'Items', {PLOT_INFO.name}, 'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.dd_agg  = uidropdown(r1, 'Items', ...
        {'Raw captures', 'Per-run mean', 'Daily mean', 'Range mean'}, ...
        'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    uilabel(r1, 'Text', 'From', 'HorizontalAlignment', 'right');
    S.dp1 = uidatepicker(r1, 'ValueChangedFcn', @(~,~) V.CB.on_range_change(V));
    uilabel(r1, 'Text', 'To', 'HorizontalAlignment', 'right');
    S.dp2 = uidatepicker(r1, 'ValueChangedFcn', @(~,~) V.CB.on_range_change(V));
    uibutton(r1, 'Text', 'Full season', 'ButtonPushedFcn', @(~,~) V.CB.set_range(V, 'full'));
    uibutton(r1, 'Text', 'Last 7 days', 'ButtonPushedFcn', @(~,~) V.CB.set_range(V, 'week'));
    uibutton(r1, 'Text', 'Reload',      'ButtonPushedFcn', @(~,~) V.CB.on_reload(V));
    uibutton(r1, 'Text', 'Export PNG',  'ButtonPushedFcn', @(~,~) V.CB.on_export(V));
    % Weather-overlay toggles for the L2: Candidates views (shown only there):
    % snow depth (right axis, m) + snow-scale SWE (independent axis, mm) +
    % the two station temperatures (own overlay axis).
    S.cb_depth = uicheckbox(r1, 'Text', 'Snow depth', 'Value', true, ...
                            'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.cb_swe   = uicheckbox(r1, 'Text', 'SWE', 'Value', false, ...
                            'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    % Temperature checkbox labels are the per-site column names (single
    % source wx_temp_labels, shared with the render legend; long names are
    % middle-truncated so distinguishing suffixes survive, and the tooltip
    % carries the full configured header).
    [wxlab, wxfull] = V.U.wx_temp_labels(cfg);
    S.cb_airtc = uicheckbox(r1, 'Text', wxlab{1},  'Value', false, ...
                            'Tooltip', wxfull{1}, ...
                            'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.cb_tempc = uicheckbox(r1, 'Text', wxlab{2}, 'Value', false, ...
                            'Tooltip', wxfull{2}, ...
                            'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    % AboveFreezing (wet-snow indicator): the ticked temperature series draw
    % as one semi-translucent orange band layer over the times ANY of them
    % is > 0 degC, instead of temperature lines (soop_viewer_render_l2).
    S.cb_abvfrz = uicheckbox(r1, 'Text', 'AboveFreezing', 'Value', false, ...
                             'ValueChangedFcn', @(~,~) V.CB.refresh(V));

    % Row 2 — Dataset (RFI method) + Phase domain selectors + capture selector.
    % The Dataset dropdown switches the active product dir between the base
    % (unfiltered) set and the notch RFI-excised set (<out_dir>_notch), so the
    % same viewer compares filtering methods. The Phase domain dropdown selects
    % which phase column the product-CSV plots read: the frequency-domain value
    % (full band or MUOS sub-bands), the time-domain sinc value, or all overlaid.
    % Raw captures (cfg.data_dir) are shared, unaffected by either choice.
    r2 = uigridlayout(gl, [1 9]);
    r2.Layout.Row = 2;
    r2.ColumnWidth = {54, 110, 46, 152, 84, '1x', 60, 60, 200};
    r2.Padding = [0 0 0 0];

    uilabel(r2, 'Text', 'Dataset', 'HorizontalAlignment', 'right');
    S.dd_method = uidropdown(r2, ...
        'Items',     {'base (none)', 'notch', 'notch + phase offset cal (synth)', 'base vs notch'}, ...
        'ItemsData', {cfg.out_dir, S.notch_out_dir, CHAINCAL_DATASET, COMPARE_DATASET}, ...
        'Value',     cfg.out_dir, ...
        'ValueChangedFcn', @(~,~) V.CB.on_method_change(V));
    uilabel(r2, 'Text', 'Phase', 'HorizontalAlignment', 'right');
    S.dd_domain = uidropdown(r2, ...
        'Items',     {'Frequency - full band', 'Frequency - MUOS band', 'Time (sinc)', 'Compare all'}, ...
        'ItemsData', {'fd', 'fd_muos', 'sinc', 'compare'}, ...
        'Value',     'compare', ...
        'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.dd_ctype = uidropdown(r2, 'Items', {'Signal', 'NL', 'L'}, ...
                            'ValueChangedFcn', @(~,~) V.CB.rebuild_caplist(V, true));
    S.dd_cap   = uidropdown(r2, 'Items', {'(no captures)'}, 'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.btn_prev = uibutton(r2, 'Text', '< Prev', 'ButtonPushedFcn', @(~,~) V.CB.step_cap(V, -1));
    S.btn_next = uibutton(r2, 'Text', 'Next >', 'ButtonPushedFcn', @(~,~) V.CB.step_cap(V, +1));
    S.lbl_cap  = uilabel(r2, 'Text', '');

    % Row 3 — RFI band-explorer controls (shown for the two season RFI views;
    % collapsed to height 0 otherwise, toggled in refresh — on the notch-effect
    % view only the 'RFI set' selector stays enabled). 'RFI set' picks which
    % season spectrum (Signal / NL / L) feeds the view; adjust the
    % thresholds/gap to re-derive and re-highlight the proposed bands live,
    % then Export to write that set's rfi_bands_proposed CSV. (Named 'RFI set'
    % because row 2 already has a 'Dataset' label for the method selector.)
    S.rfi_row = uigridlayout(gl, [1 13]);
    S.rfi_row.Layout.Row = 3;
    S.rfi_row.ColumnWidth = {46, 72, 72, 60, 28, 64, 58, 150, 52, 74, 110, 220, '1x'};
    S.rfi_row.Padding = [0 0 0 0];
    uilabel(S.rfi_row, 'Text', 'RFI set', 'HorizontalAlignment', 'right');
    S.rfi_dataset = uidropdown(S.rfi_row, 'Items', {'Signal', 'NL', 'L'}, ...
        'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    uilabel(S.rfi_row, 'Text', 'Excess dB', 'HorizontalAlignment', 'right');
    S.rfi_excess = uieditfield(S.rfi_row, 'numeric', 'Limits', [0 40], ...
        'Value', cfgdef('rfi_excess_db', 6), 'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    uilabel(S.rfi_row, 'Text', 'SK', 'HorizontalAlignment', 'right');
    S.rfi_sk = uieditfield(S.rfi_row, 'numeric', 'Limits', [0 1e4], ...
        'Value', cfgdef('rfi_sk_threshold', 100), 'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    uilabel(S.rfi_row, 'Text', 'Gap kHz', 'HorizontalAlignment', 'right');
    % Gap kHz = slider + synced numeric field, integer kHz. The slider snaps to a
    % rounded integer on commit, the field mirrors it, and render_rfi reads
    % S.rfi_gap.Value — one source of truth, so the readout never disagrees with the
    % value used to derive bands. The field has NO Limits (a numeric field with
    % Limits can reject out-of-range input before its callback fires); on_gap_field
    % clamps manually to [0 200].
    S.rfi_gap = uislider(S.rfi_row, 'Limits', [0 200], 'MajorTicks', 0:50:200, ...
        'Value', round(cfgdef('rfi_merge_khz', 25)), ...
        'ValueChangingFcn', @(~,e) V.CB.on_gap_slider_changing(V, e), 'ValueChangedFcn', @(~,~) V.CB.on_gap_slider(V));
    S.rfi_gap_ef = uieditfield(S.rfi_row, 'numeric', 'RoundFractionalValues', 'on', ...
        'Value', round(cfgdef('rfi_merge_khz', 25)), 'ValueChangedFcn', @(~,~) V.CB.on_gap_field(V));
    S.rfi_usesk = uicheckbox(S.rfi_row, 'Text', 'Use SK', ...
        'Value', logical(cfgdef('rfi_use_sk', true)), 'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.btn_rfi_export = uibutton(S.rfi_row, 'Text', 'Export bands', ...
        'ButtonPushedFcn', @(~,~) V.CB.on_rfi_export(V));
    S.lbl_rfi = uilabel(S.rfi_row, 'Text', '— bands', 'FontWeight', 'bold');

    % Row 4 — plot panel (left) + explanation side panel (right)
    r3 = uigridlayout(gl, [1 2]);
    r3.Layout.Row = 4;
    r3.ColumnWidth = {'1x', 300};
    r3.Padding = [0 0 0 0];

    S.panel = uipanel(r3);   % plots (tiledlayout rebuilt per render)

    info_gl = uigridlayout(r3, [29 1]);
    % Rows 20/21 (geometry toggles, footprint-map controls) are two-line
    % sub-grids — 56 px so both lines fit inside the ~240 px side panel.
    % The 28 px control rows are children 1-19 (the run of 28s below), so a
    % new control row's height entry must be inserted BEFORE the two 56s.
    info_gl.RowHeight  = {28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 56, 56, 22, 150, 22, 250, 22, 60, 22, 'fit'};
    info_gl.Padding    = [6 6 6 6];
    info_gl.Scrollable = 'on';   % side panel can scroll if content is tall
    % Title / X-label / Y-label override rows — text field + Set button. Empty
    % field = the plot's auto label. These reset when the plot type changes.
    title_row = uigridlayout(info_gl, [1 3]);
    title_row.ColumnWidth = {44, '1x', 36};
    title_row.Padding = [0 0 0 0];
    uilabel(title_row, 'Text', 'Title', 'FontWeight', 'bold');
    S.ef_title = uieditfield(title_row, 'text', 'Placeholder', '(auto)', ...
        'ValueChangedFcn', @(~,~) V.CB.on_set_labels(V));
    uibutton(title_row, 'Text', 'Set', 'ButtonPushedFcn', @(~,~) V.CB.on_set_labels(V));

    xlabel_row = uigridlayout(info_gl, [1 3]);
    xlabel_row.ColumnWidth = {44, '1x', 36};
    xlabel_row.Padding = [0 0 0 0];
    uilabel(xlabel_row, 'Text', 'X-label', 'FontWeight', 'bold');
    S.ef_xlabel = uieditfield(xlabel_row, 'text', 'Placeholder', '(auto)', ...
        'ValueChangedFcn', @(~,~) V.CB.on_set_labels(V));
    uibutton(xlabel_row, 'Text', 'Set', 'ButtonPushedFcn', @(~,~) V.CB.on_set_labels(V));

    ylabel_row = uigridlayout(info_gl, [1 3]);
    ylabel_row.ColumnWidth = {44, '1x', 36};
    ylabel_row.Padding = [0 0 0 0];
    uilabel(ylabel_row, 'Text', 'Y-label', 'FontWeight', 'bold');
    S.ef_ylabel = uieditfield(ylabel_row, 'text', 'Placeholder', '(auto)', ...
        'ValueChangedFcn', @(~,~) V.CB.on_set_labels(V));
    uibutton(ylabel_row, 'Text', 'Set', 'ButtonPushedFcn', @(~,~) V.CB.on_set_labels(V));

    % Font-size controls (points): title / axis labels / legend. Applied live
    % to every axes & legend in the panel and persist across plots (global
    % style, so a deck keeps consistent sizing).
    fs_row = uigridlayout(info_gl, [1 6]);
    fs_row.ColumnWidth = {'fit', 46, 'fit', 46, 'fit', 46};
    fs_row.Padding = [0 0 0 0];
    fs_row.ColumnSpacing = 4;
    uilabel(fs_row, 'Text', 'Ttl', 'FontWeight', 'bold');
    S.sp_fs_title = uispinner(fs_row, 'Limits', [6 40], 'Step', 1, 'Value', 28, ...
        'ValueDisplayFormat', '%g', 'ValueChangedFcn', @(~,~) V.U.apply_overrides(V));
    uilabel(fs_row, 'Text', 'Lab', 'FontWeight', 'bold');
    S.sp_fs_label = uispinner(fs_row, 'Limits', [6 40], 'Step', 1, 'Value', 24, ...
        'ValueDisplayFormat', '%g', 'ValueChangedFcn', @(~,~) V.U.apply_overrides(V));
    uilabel(fs_row, 'Text', 'Leg', 'FontWeight', 'bold');
    S.sp_fs_legend = uispinner(fs_row, 'Limits', [6 40], 'Step', 1, 'Value', 22, ...
        'ValueDisplayFormat', '%g', 'ValueChangedFcn', @(~,~) V.U.apply_overrides(V));

    % Axis tick-label font size (points) — the numbers along the x and y axes.
    % One control drives both axes (like the single 'Lab' axis-label control);
    % applied live to every axes in the panel and persists across plots.
    tick_row = uigridlayout(info_gl, [1 2]);
    tick_row.ColumnWidth = {54, 46};
    tick_row.Padding = [0 0 0 0];
    uilabel(tick_row, 'Text', 'Ticks', 'FontWeight', 'bold');
    S.sp_fs_tick = uispinner(tick_row, 'Limits', [6 40], 'Step', 1, 'Value', 20, ...
        'ValueDisplayFormat', '%g', 'ValueChangedFcn', @(~,~) V.U.apply_overrides(V));

    % Legend placement (also draggable by mouse in the figure); 'none' hides it.
    legend_row = uigridlayout(info_gl, [1 2]);
    legend_row.ColumnWidth = {54, '1x'};
    legend_row.Padding = [0 0 0 0];
    uilabel(legend_row, 'Text', 'Legend', 'FontWeight', 'bold');
    S.dd_legend = uidropdown(legend_row, 'Items', ...
        {'best', 'northeast', 'northwest', 'southeast', 'southwest', ...
         'north', 'south', 'east', 'west', ...
         'northoutside', 'southoutside', 'eastoutside', 'westoutside', 'none'}, ...
        'Value', 'best', 'ValueChangedFcn', @(~,~) V.U.apply_overrides(V));

    % Line-width / point-size scale spinners — candidates family only.
    % Multipliers on the product base styles (x1 = today's look): Line x
    % scales the width of every drawn line (phase line, weather / theory /
    % temperature lines and their legend proxies, the 0 degC threshold);
    % Pt x scales the phase marker size and the hour-color dot size.
    % Applied at render time via style_factors + style_apply.
    style_row = uigridlayout(info_gl, [1 4]);
    style_row.ColumnWidth = {'fit', 58, 'fit', 58};
    style_row.Padding = [0 0 0 0];
    style_row.ColumnSpacing = 4;
    uilabel(style_row, 'Text', ['Line ' char(215)], 'FontWeight', 'bold');
    S.sp_linew = uispinner(style_row, 'Limits', [0.25 5], 'Step', 0.25, ...
        'Value', 1, 'ValueDisplayFormat', '%g', ...
        'ValueChangedFcn', @(~,~) V.CB.refresh(V), ...
        'Tooltip', ['Multiplies the width of every drawn line ' ...
                    '(1 = default; also thickens outlined marker edges)']);
    uilabel(style_row, 'Text', ['Pt ' char(215)], 'FontWeight', 'bold');
    S.sp_ptsz = uispinner(style_row, 'Limits', [0.25 5], 'Step', 0.25, ...
        'Value', 1, 'ValueDisplayFormat', '%g', ...
        'ValueChangedFcn', @(~,~) V.CB.refresh(V), ...
        'Tooltip', ['Multiplies the phase marker size and the ' ...
                    'hour-color dot size (1 = default)']);
    S.style_row = style_row;
    S.style_row.Visible = 'off';

    % Units switch — shown only for the 'Calib: Power ratio (NS / L)' view.
    units_row = uigridlayout(info_gl, [1 2]);
    units_row.ColumnWidth = {54, 'fit'};
    units_row.Padding = [0 0 0 0];
    uilabel(units_row, 'Text', 'Units', 'FontWeight', 'bold');
    S.sw_units = uiswitch(units_row, 'slider', 'Items', {'Linear', 'dB'}, ...
                          'Value', 'Linear', 'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.units_row = units_row;
    S.units_row.Visible = 'off';

    % Gain scaling switch — shown only for the 'Calib: Gain drift' view.
    % Norm = each gain / its season median (drift about 1); Raw = Eq. 34 output.
    gain_row = uigridlayout(info_gl, [1 2]);
    gain_row.ColumnWidth = {54, 'fit'};
    gain_row.Padding = [0 0 0 0];
    uilabel(gain_row, 'Text', 'Gain', 'FontWeight', 'bold');
    S.sw_gain = uiswitch(gain_row, 'slider', 'Items', {'Norm', 'Raw'}, ...
                         'Value', 'Norm', 'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.gain_row = gain_row;
    S.gain_row.Visible = 'off';

    % SNR units switch — shown only for the two SNR views (Eq. 37 / Eq. 39).
    % Linear = unitless power ratio (log y-axis); dB = 10*log10(ratio).
    snr_row = uigridlayout(info_gl, [1 2]);
    snr_row.ColumnWidth = {54, 'fit'};
    snr_row.Padding = [0 0 0 0];
    uilabel(snr_row, 'Text', 'SNR', 'FontWeight', 'bold');
    S.sw_snr = uiswitch(snr_row, 'slider', 'Items', {'Linear', 'dB'}, ...
                        'Value', 'dB', 'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.snr_row = snr_row;
    S.snr_row.Visible = 'off';

    % Y-scale switch — shown only for 'Calib: Cross-correlation amplitudes'.
    % Log (default) keeps the ~10x load-to-noise-source
    % separation legible; Linear shows the raw ADC^2 magnitude.
    ampscale_row = uigridlayout(info_gl, [1 2]);
    ampscale_row.ColumnWidth = {54, 'fit'};
    ampscale_row.Padding = [0 0 0 0];
    uilabel(ampscale_row, 'Text', 'Scale', 'FontWeight', 'bold');
    S.sw_ampscale = uiswitch(ampscale_row, 'slider', 'Items', {'Log', 'Linear'}, ...
                             'Value', 'Log', 'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.ampscale_row = ampscale_row;
    S.ampscale_row.Visible = 'off';

    % Phase cal switch — shown only for 'Raw: Phase Offset'. On rotates the
    % reflected channel by the capture's measured inter-channel offset
    % (angle(mean(D .* conj(R))) over the loaded analysis window) so the
    % correlated components align; Off shows the channels as recorded.
    phaseoff_row = uigridlayout(info_gl, [1 2]);
    phaseoff_row.ColumnWidth = {60, 'fit'};
    phaseoff_row.Padding = [0 0 0 0];
    uilabel(phaseoff_row, 'Text', 'Phase cal', 'FontWeight', 'bold');
    S.sw_phaseoff = uiswitch(phaseoff_row, 'slider', 'Items', {'Off', 'On'}, ...
                             'Value', 'Off', 'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.phaseoff_row = phaseoff_row;
    S.phaseoff_row.Visible = 'off';

    % Detrend toggle — shown only for 'L1: Diurnal phase pattern'. When on, each
    % capture's phase has its day's circular mean removed before hour binning, so
    % the plot shows the diurnal residual with the seasonal wander taken out.
    detrend_row = uigridlayout(info_gl, [1 1]);
    detrend_row.Padding = [0 0 0 0];
    S.sw_detrend = uicheckbox(detrend_row, 'Text', 'Detrend (subtract daily circ. mean)', ...
                              'Value', false, 'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.detrend_row = detrend_row;
    S.detrend_row.Visible = 'off';

    % Daily time-of-day filter — shown only for the three 'L2: Candidates'
    % views. When ticked, each target day keeps one capture: the one nearest
    % the entered time (H, HHMM, or HH:MM; capture/Pi clock); days whose
    % nearest capture is over 1 h away are dropped (TOD_WINDOW in
    % soop_viewer_render_l2).
    tod_row = uigridlayout(info_gl, [1 2]);
    tod_row.ColumnWidth = {'1x', 64};
    tod_row.Padding = [0 0 0 0];
    S.cb_tod = uicheckbox(tod_row, 'Text', 'Daily capture nearest', ...
                          'Value', false, 'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.ef_tod = uieditfield(tod_row, 'text', 'Value', '0600', 'Placeholder', 'HHMM', ...
        'Tooltip', ['Target time of day (H, HHMM, or HH:MM; capture/Pi ' ...
                    'clock). Each day keeps its capture nearest this time, ' ...
                    'within ' char(177) '1 h; farther days are dropped.'], ...
        'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.tod_row = tod_row;
    S.tod_row.Visible = 'off';

    % phaseLine — shown only on the three 'L2: Candidates' views. Governs the
    % phase series' connecting line in EVERY aggregation mode: unchecked =
    % markers only (scatter), checked = markers joined by a line (aggregated
    % modes keep their error bars either way).
    phline_row = uigridlayout(info_gl, [1 1]);
    phline_row.Padding = [0 0 0 0];
    S.cb_phline = uicheckbox(phline_row, 'Text', 'phaseLine (connect phase points)', ...
        'Value', false, 'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.phline_row = phline_row;
    S.phline_row.Visible = 'off';

    % SNR display cutoff — shown only on the three 'L2: Candidates' views.
    % Filters the DISPLAYED candidates with the producer's exact predicate
    % (isfinite(snr_db) & snr_db >= cut); rows below the pipeline scoring
    % threshold never reached the CSV, so lowering below the configured
    % start is a harmless no-op. Disabled when the loaded candidate product
    % has no snr_db column (regenerate to enable).
    snrcut_row = uigridlayout(info_gl, [1 3]);
    snrcut_row.ColumnWidth = {'fit', 60, 'fit'};
    snrcut_row.Padding = [0 0 0 0];
    snrcut_row.ColumnSpacing = 4;
    uilabel(snrcut_row, 'Text', ['SNR ' char(8805)], 'FontWeight', 'bold');
    % Limits bracket the validated start on BOTH sides — the pipeline allows
    % negative thresholds, and construction must never reject the start.
    snr0 = V.U.snrcut_start(cfg);
    S.sp_snrcut = uispinner(snrcut_row, ...
        'Limits', [min(0, floor(snr0)) max(60, ceil(snr0))], ...
        'Step', 1, 'Value', snr0, 'ValueDisplayFormat', '%g', ...
        'Tooltip', ['Display-only SNR floor for the candidate points (dB). ' ...
                    'Raising it can swap a day''s daily-filter pick to the ' ...
                    'nearest PASSING capture. Values below the processing ' ...
                    'threshold cannot restore rows absent from the CSV. ' ...
                    'Disabled = the loaded candidate product has no snr_db ' ...
                    'column (regenerate to filter).'], ...
        'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    uilabel(snrcut_row, 'Text', 'dB', 'FontWeight', 'bold');
    S.snrcut_row = snrcut_row;
    S.snrcut_row.Visible = 'off';

    % Theoretical phase-from-SWE overlay (candidate control block, directly
    % after the SNR cutoff — NOT the calibration snr_row above). Checkbox
    % draws the snow-scale SWE record converted to differential phase (the
    % coherent-reflection paper's Eq. 6 fringe rate, paper-positive sign) on
    % the phase axis, anchored per the dropdown; drawn only while the SWE
    % overlay is shown.
    theory_row = uigridlayout(info_gl, [1 2]);
    theory_row.ColumnWidth = {'fit', '1x'};
    theory_row.Padding = [0 0 0 0];
    theory_row.ColumnSpacing = 4;
    S.cb_theory = uicheckbox(theory_row, 'Text', 'theoretical', 'Value', false, ...
        'Tooltip', ['Overlay the theoretical differential phase computed from ' ...
                    'the snow-scale SWE (paper sign convention). Needs the SWE ' ...
                    'overlay on, SWE data, and satellite geometry.'], ...
        'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.dd_thanchor = uidropdown(theory_row, ...
        'Items', {'SWE = 0 start', 'First shown'}, 'Value', 'SWE = 0 start', ...
        'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.theory_row = theory_row;
    S.theory_row.Visible = 'off';

    % Manual SWE-per-fringe override for the theoretical overlay (empty =
    % auto from geometry via swe_per_fringe_mm; any positive number of mm
    % per 360° wins). The legend always shows the active rate.
    fringe_row = uigridlayout(info_gl, [1 3]);
    fringe_row.ColumnWidth = {'fit', '1x', 36};
    fringe_row.Padding = [0 0 0 0];
    fringe_row.ColumnSpacing = 4;
    uilabel(fringe_row, 'Text', ['mm/2' char(960)], 'FontWeight', 'bold', ...
            'Tooltip', 'SWE change per full fringe (360°) for the theoretical overlay');
    S.ef_fringe = uieditfield(fringe_row, 'text', 'Placeholder', '(auto)', ...
        'Tooltip', ['SWE-per-fringe rate (mm per 360°). Auto-populates with ' ...
                    'the geometry-computed value; type a positive number to ' ...
                    'override, clear the field to return to auto.'], ...
        'ValueChangedFcn', @(~,~) V.CB.on_fringe_edit(V));
    uibutton(fringe_row, 'Text', 'Set', 'ButtonPushedFcn', @(~,~) V.CB.refresh(V));
    S.fringe_row = fringe_row;
    S.fringe_row.Visible = 'off';

    % Hour-of-day point coloring — active only while the daily filter is
    % OFF and the aggregation keeps hour identity (Raw captures / Per-run
    % mean); the render checks the same predicate, so a checked-but-
    % disabled box draws nothing.
    hour_row = uigridlayout(info_gl, [1 1]);
    hour_row.Padding = [0 0 0 0];
    S.cb_hourcolor = uicheckbox(hour_row, 'Text', 'Color by hour', 'Value', false, ...
        'Tooltip', ['Color each phase point by its nearest hour of day ' ...
                    '(capture timebase; cyclic colormap). Available when the ' ...
                    'daily filter is off and aggregation is Raw captures or ' ...
                    'Per-run mean.'], ...
        'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.hour_row = hour_row;
    S.hour_row.Visible = 'off';

    % Geometry-series toggles — shown only for 'Radar Cal: geometry (r2c / r1mc /
    % A_eff)'. Each checkbox draws one geometry series: r_2c (= r_d_m) and r_1mc
    % on a shared log-scale left axis (m), A_eff on the linear right axis (m^2);
    % the legend lists only the checked series. The h dropdown selects the
    % reflector-height variant for r_1mc / A_eff: snow-corrected (default),
    % fixed tower height, or both overlaid (fixed solid, snow dashed).
    % Defaults show only A_eff.
    % Two-line sub-grid (the four controls overflow the side panel on one
    % line): checkboxes on top, the h dropdown below. 'fixed h' is the default
    % so the view renders even without weather-station data.
    geom_row = uigridlayout(info_gl, [2 3]);
    geom_row.ColumnWidth = {'fit', 'fit', 'fit'};
    geom_row.RowHeight   = {'fit', 'fit'};
    geom_row.RowSpacing  = 2;
    geom_row.Padding = [0 0 0 0];
    S.cb_geom_r2   = uicheckbox(geom_row, 'Text', 'r_2c range', 'Value', false, ...
                                'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.cb_geom_r1   = uicheckbox(geom_row, 'Text', 'r_1mc range', 'Value', false, ...
                                'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.cb_geom_aeff = uicheckbox(geom_row, 'Text', 'A_eff footprint', 'Value', true, ...
                                'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.dd_geom_h    = uidropdown(geom_row, 'Items', {'snow h', 'fixed h', 'both'}, ...
                                'Value', 'fixed h', ...
                                'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.dd_geom_h.Layout.Row = 2;
    S.dd_geom_h.Layout.Column = [1 2];
    S.geom_row = geom_row;
    S.geom_row.Visible = 'off';

    % Footprint-map controls — shown only for 'Radar Cal: footprint map'. The
    % satellite dropdown lists every muos_elevation_<norad>.csv found in
    % cfg.elev_dir (the MATLAB-side notion of "TLE available"; generate more
    % with make_muos_elevation.py); the h dropdown picks the reflector-height
    % variant(s) for the drawn Fresnel ellipse.
    % The date picker selects WHICH DAY the footprint is drawn for (that day's
    % mean elevation/azimuth and mean SNOdar depth — the snow-corrected h moves
    % with snow depth). Cleared (empty) = mean over the top date range.
    map_row = uigridlayout(info_gl, [2 2]);
    map_row.ColumnWidth = {'fit', '1x'};
    map_row.RowHeight   = {'fit', 'fit'};
    map_row.RowSpacing  = 2;
    map_row.Padding = [0 0 0 0];
    sat_names = {'(no elevation tables)'};
    sat_ids   = {[]};
    if isfield(V.cfg, 'elev_dir')
        cand = dir(fullfile(V.cfg.elev_dir, 'muos_elevation_*.csv'));
        if ~isempty(cand)
            known = containers.Map({'38093', '39206', '41622'}, ...
                                   {'MUOS-1', 'MUOS-2', 'MUOS-5'});
            sat_names = {};  sat_ids = {};
            for ci = 1:numel(cand)
                tok = regexp(cand(ci).name, 'muos_elevation_(\d+)\.csv', 'tokens', 'once');
                if isempty(tok), continue; end
                if isKey(known, tok{1}), nm = known(tok{1});
                else,                    nm = ['NORAD ' tok{1}];
                end
                sat_names{end+1} = sprintf('%s (%s)', nm, tok{1});  %#ok<AGROW>
                sat_ids{end+1}   = str2double(tok{1});              %#ok<AGROW>
            end
        end
    end
    % Two-line sub-grid: satellite selector on top (full width), h variant +
    % footprint date below. 'fixed h' default so the map renders without
    % weather-station data.
    S.dd_map_sat = uidropdown(map_row, 'Items', sat_names, 'ItemsData', sat_ids, ...
                              'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.dd_map_sat.Layout.Row = 1;
    S.dd_map_sat.Layout.Column = [1 2];
    S.dd_map_h   = uidropdown(map_row, 'Items', {'snow h', 'fixed h', 'both'}, ...
                              'Value', 'fixed h', ...
                              'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.dd_map_h.Layout.Row = 2;
    S.dd_map_h.Layout.Column = 1;
    S.dp_map     = uidatepicker(map_row, 'Value', NaT, ...
                              'Tooltip', ['Footprint date (day mean el/az + ' ...
                              'snow depth); empty = mean over the date range'], ...
                              'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.dp_map.Layout.Row = 2;
    S.dp_map.Layout.Column = 2;
    S.map_row = map_row;
    S.map_row.Visible = 'off';

    uilabel(info_gl, 'Text', 'Now showing', 'FontWeight', 'bold');
    S.lbl_settings = uitextarea(info_gl, 'Value', '', 'Editable', 'off');
    uilabel(info_gl, 'Text', 'How to read this', 'FontWeight', 'bold');
    S.lbl_expl = uitextarea(info_gl, 'Value', '', 'Editable', 'off');
    % Core formula for this plot.
    uilabel(info_gl, 'Text', 'Math', 'FontWeight', 'bold');
    S.lbl_math = uitextarea(info_gl, 'Value', '', 'Editable', 'off');
    % Link(s) to the function(s) in BrundageSoOp_fun.m (filled per plot).
    uilabel(info_gl, 'Text', 'Source (BrundageSoOp_fun.m)', 'FontWeight', 'bold');
    S.src_box = uigridlayout(info_gl, [1 1]);
    S.src_box.Padding = [0 0 0 0];
    S.src_box.RowSpacing = 2;
end

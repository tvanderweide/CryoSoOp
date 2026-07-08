function soop_viewer_layout(V)
% Build the viewer uifigure (4-row grid + side panel) and wire every control
% to a module callback capturing only V. Verbatim widget layout from the
% original; product-dir init moved to the shell.
    S = V;
    cfg = V.cfg;
    COMPARE_DATASET = V.COMPARE_DATASET;
    CHAINCAL_DATASET = V.CHAINCAL_DATASET;
    PLOT_INFO = V.PLOT_INFO;
    cfgdef = @(varargin) V.U.cfgdef(V, varargin{:});
    % ---- Figure & layout ----
    S.fig = uifigure('Name', 'Brundage SoOp Viewer', 'Position', [80 80 1200 720]);
    gl = uigridlayout(S.fig, [4 1]);
    V.gl = gl;
    gl.RowHeight = {38, 38, 0, '1x'};   % row 3 = RFI explorer controls, collapsed by default
    gl.Padding   = [8 8 8 8];

    % Row 1 — plot type, aggregation, date range, action buttons, temp toggles
    % 13 children (10 controls + 3 weather checkboxes) — the grid must declare
    % all 13 columns, or the extras wrap onto an auto-added second row that
    % cannot fit in the fixed 38 px outer cell and the whole row clips.
    r1 = uigridlayout(gl, [1 13]);
    r1.Layout.Row = 1;
    r1.ColumnWidth = {270, 130, 42, 115, 26, 115, 86, 86, 76, 96, 'fit', 'fit', 'fit'};
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
    % snow depth + the two station temperatures, each on its own axis.
    S.cb_depth = uicheckbox(r1, 'Text', 'Snow depth', 'Value', true, ...
                            'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.cb_airtc = uicheckbox(r1, 'Text', 'AirTC_Avg',  'Value', true, ...
                            'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.cb_tempc = uicheckbox(r1, 'Text', 'Temp_C_Avg', 'Value', true, ...
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

    % Row 3 — RFI band-explorer controls (shown only for 'Raw: Season RFI
    % spectrum'; collapsed to height 0 otherwise, toggled in refresh). Adjust
    % the thresholds/gap to re-derive and re-highlight the proposed bands live,
    % then Export to write rfi_bands_proposed.csv + a cfg.rfi_bands snippet.
    S.rfi_row = uigridlayout(gl, [1 11]);
    S.rfi_row.Layout.Row = 3;
    S.rfi_row.ColumnWidth = {72, 60, 28, 64, 58, 150, 52, 74, 110, 220, '1x'};
    S.rfi_row.Padding = [0 0 0 0];
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

    info_gl = uigridlayout(r3, [19 1]);
    info_gl.RowHeight  = {28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 22, 150, 22, 250, 22, 60, 22, 'fit'};
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
    % Log (default, current behaviour) keeps the ~10x load-to-noise-source
    % separation legible; Linear shows the raw ADC^2 magnitude.
    ampscale_row = uigridlayout(info_gl, [1 2]);
    ampscale_row.ColumnWidth = {54, 'fit'};
    ampscale_row.Padding = [0 0 0 0];
    uilabel(ampscale_row, 'Text', 'Scale', 'FontWeight', 'bold');
    S.sw_ampscale = uiswitch(ampscale_row, 'slider', 'Items', {'Log', 'Linear'}, ...
                             'Value', 'Log', 'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.ampscale_row = ampscale_row;
    S.ampscale_row.Visible = 'off';

    % Detrend toggle — shown only for 'L1: Diurnal phase pattern'. When on, each
    % capture's phase has its day's circular mean removed before hour binning, so
    % the plot shows the diurnal residual with the seasonal wander taken out.
    detrend_row = uigridlayout(info_gl, [1 1]);
    detrend_row.Padding = [0 0 0 0];
    S.sw_detrend = uicheckbox(detrend_row, 'Text', 'Detrend (subtract daily circ. mean)', ...
                              'Value', false, 'ValueChangedFcn', @(~,~) V.CB.refresh(V));
    S.detrend_row = detrend_row;
    S.detrend_row.Visible = 'off';

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

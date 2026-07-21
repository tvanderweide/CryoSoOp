% soop_viewer_render_raw  On-demand single-capture raw views (PSD / spectrogram /
% time domain / cross-correlation / FFT), live RFI filtering + base-anchored scales.
function soop_viewer_render_raw(V, kind)
    S = V;
    cfg = V.cfg;
    M = V.M;
    npts = V.npts;
    Erfi = V.Erfi;
    show_msg = @(varargin) V.U.show_msg(V, varargin{:});
    cfgdef = @(varargin) V.U.cfgdef(V, varargin{:});
    dropdown_method = @(varargin) V.U.dropdown_method(V, varargin{:});
    prep_excis = @(varargin) V.U.prep_excis(V, varargin{:});
    raw_cap_title = @(varargin) V.U.raw_cap_title(V, varargin{:});
    load_capture = @(varargin) rr_load_capture(V, varargin{:});
    nearest_capture = @(varargin) rr_nearest_capture(V, varargin{:});
    base = S.dd_cap.Value;
    if isempty(base) || startsWith(base, '(')
        show_msg('Select a capture (check data\_dir and date range).');
        return;
    end
    dlg = uiprogressdlg(S.fig, 'Indeterminate', 'on', ...
                        'Message', "Reading " + base + " ...");
    cleanup = onCleanup(@() close(dlg));

    % Creating the dialog above runs a drawnow that can let a queued
    % Prev/Next/dropdown callback advance the capture selection. If it did,
    % skip this (now-stale) compute — the refresh guard re-renders against
    % the new selection — so we don't burn an xcorr/PSD pass on a capture
    % that is no longer selected.
    if ~strcmp(string(S.dd_cap.Value), string(base))
        return;
    end

    % Method (Dataset dropdown) is part of the key: the Raw: PSD view
    % applies it live, so changing the filter must invalidate the cache.
    key = string(kind) + "|" + string(base) + "|" + string(S.dd_method.Value);
    if S.cache.key == key
        D = S.cache.data;
    else
        [ch0, ch1] = load_capture(base);
        switch kind
            case 'Raw: PSD (ch0 & ch1)'
                seg = 2^20;
                D.method = dropdown_method();
                if strcmp(D.method, 'none')
                    [P0_full, f_full] = M.welch_psd(ch0, cfg.fs, seg);
                    P1_full = M.welch_psd(ch1, cfg.fs, seg);
                else
                    excis = prep_excis(seg, D.method);
                    [P0_full, f_full] = M.welch_psd_filtered(ch0, cfg.fs, seg, D.method, excis, Erfi.apply);
                    P1_full = M.welch_psd_filtered(ch1, cfg.fs, seg, D.method, excis, Erfi.apply);
                end
                [D.f,  D.P0] = M.decimate_spectrum(f_full, P0_full, 4000, 'mean');
                [~,    D.P1] = M.decimate_spectrum(f_full, P1_full, 4000, 'mean');
            case 'Raw: Cross-correlation profile'
                method = dropdown_method();
                if strcmp(method, 'none')
                    D = M.xcorr_profile(ch0, ch1, npts, cfg.num_segs, cfg.lag_half_win);
                    base_peak = max(abs(D.R));
                else
                    excis = prep_excis(npts, method);
                    D = M.xcorr_profile_filtered(ch0, ch1, npts, cfg.num_segs, cfg.lag_half_win, method, excis, Erfi.apply);
                    % Also compute the base (unfiltered) xcorr so the |R_xy|
                    % y-axis can be anchored to its peak (same idea as the
                    % Spectrogram colorbar) — base/notch of one
                    % file then share a y-axis for direct comparison.
                    Dbase = M.xcorr_profile(ch0, ch1, npts, cfg.num_segs, cfg.lag_half_win);
                    base_peak = max(abs(Dbase.R));
                end
                D.method = method;   % set after: xcorr returns a fresh struct
                % Joint max guards the rare case where filtering sharpens the
                % peak above base (would otherwise clip); normally base
                % dominates so the axis is identical across datasets.
                D.ymax = max(base_peak, max(abs(D.R)));
            case 'Raw: Cross-correlation Comparison'
                % Anchor timestamp comes from whichever capture is selected
                % (any ctype); Signal/NL/L are then each independently
                % matched to their nearest-in-time file and loaded fresh —
                % this is a 3-capture view, so it does not reuse ch0/ch1
                % from load_capture(base) above.
                method = dropdown_method();
                excis  = [];
                if ~strcmp(method, 'none')
                    excis = prep_excis(npts, method);
                end
                anchor_ts = M.base_ts(string(base));
                types = ["Signal", "NL", "L"];
                peaks = nan(1, numel(types));
                D.method = method;
                D.types  = types;
                for ti = 1:numel(types)
                    nb = nearest_capture(char(types(ti)), anchor_ts);
                    Di = struct('base', nb, 'R', [], 'lag', []);
                    if strlength(nb) > 0
                        [c0, c1] = load_capture(nb);
                        if strcmp(method, 'none')
                            Pi = M.xcorr_profile(c0, c1, npts, cfg.num_segs, cfg.lag_half_win);
                        else
                            Pi = M.xcorr_profile_filtered(c0, c1, npts, cfg.num_segs, ...
                                 cfg.lag_half_win, method, excis, Erfi.apply);
                        end
                        Di.R   = Pi.R;
                        Di.lag = Pi.lag;
                        peaks(ti) = max(abs(Pi.R));
                    end
                    D.(types(ti)) = Di;
                end
                D.ymax = max(peaks, [], 'omitnan');
                if isempty(D.ymax) || isnan(D.ymax) || D.ymax <= 0, D.ymax = 1; end
            case 'Raw: FFT Amplitude'
                D.method = dropdown_method();
                if ~strcmp(D.method, 'none')
                    % Apply the RFI notch to the FULL-length signal in the
                    % frequency domain before the amplitude FFT — the same
                    % phase-safe per-bin operator the PSD / Time-domain views
                    % use (single fft/ifft per channel). numel is unchanged,
                    % so the fft_amp_fullband window/bins still hold.
                    excis = prep_excis(numel(ch0), D.method);
                    ch0 = ifft(Erfi.apply(fft(ch0), D.method, excis));
                    ch1 = ifft(Erfi.apply(fft(ch1), D.method, excis));
                end
                [D.A0, D.A1, D.f] = M.fft_amp_fullband(ch0, ch1, cfg.fs, numel(ch0));
            case 'Raw: Spectrogram'
                seg = 4096;
                D.method = dropdown_method();
                % Always compute the base (unfiltered) spectrogram so the
                % Power (dB) colorbar can be anchored to its joint maximum
                % (D.cmax_db). notch then use the SAME color
                % limits as base, for direct visual comparison.
                [b0, D.tms, D.fmhz] = M.spectro(ch0, cfg.fs, cfg.freq_hz, seg, 1000);
                b1 = M.spectro(ch1, cfg.fs, cfg.freq_hz, seg, 1000);
                D.cmax_db = 10*log10(max(max(b0(:)), max(b1(:))));
                if strcmp(D.method, 'none')
                    D.img0 = b0;  D.img1 = b1;
                else
                    excis = prep_excis(seg, D.method);
                    D.img0 = M.spectro_filtered(ch0, cfg.fs, cfg.freq_hz, seg, 1000, D.method, excis, Erfi.apply);
                    D.img1 = M.spectro_filtered(ch1, cfg.fs, cfg.freq_hz, seg, 1000, D.method, excis, Erfi.apply);
                end
            case 'Raw: Time domain'
                D.method = dropdown_method();
                n_disp = 20000;
                dec = max(1, floor(numel(ch0) / n_disp));
                idx = (1 : dec : dec*floor(numel(ch0)/dec))';
                D.t_ms = (idx - 1) / cfg.fs * 1e3;
                % Anchor the y-axis to the BASE (unfiltered) amplitude,
                % computed here before any filtering, so the notch view
                % shares limits with 'none' and the RFI removal reads as a
                % real reduction instead of being rescaled away (same idiom
                % as the Spectrogram colorbar / xcorr y-axis).
                D.ymax = max(abs([real(ch0(idx)); imag(ch0(idx)); ...
                                  real(ch1(idx)); imag(ch1(idx))]));
                if ~strcmp(D.method, 'none')
                    % Apply the RFI notch to the FULL-length signal in the
                    % frequency domain BEFORE the display decimation. numel
                    % is unchanged by fft/ifft, so idx/t_ms above still hold.
                    % Decimating first would alias the flagged RF bands so
                    % the bin mask lands on the wrong frequencies. The notch
                    % is the same phase-safe per-bin operator the PSD/xcorr
                    % views use; here it is a single fft/ifft per channel.
                    % Only the filtered trace is shown (no base overlay).
                    excis = prep_excis(numel(ch0), D.method);
                    ch0 = ifft(Erfi.apply(fft(ch0), D.method, excis));
                    ch1 = ifft(Erfi.apply(fft(ch1), D.method, excis));
                end
                D.I0 = real(ch0(idx));  D.Q0 = imag(ch0(idx));
                D.I1 = real(ch1(idx));  D.Q1 = imag(ch1(idx));
            case 'Raw: Phase Offset'
                % Always NL-notch-filtered (independent of the Dataset
                % dropdown): the view models the chain-phase measurement,
                % and compute_calib excises NL captures with the NL band
                % set. prep_excis picks bands by the pinned capture type
                % (NL -> cfg.rfi_bands_nl); empty bands = pass-through,
                % matching the pipeline's unexcised fallback.
                excis = prep_excis(numel(ch0), 'notch_interp');
                ch0 = ifft(Erfi.apply(fft(ch0), 'notch_interp', excis));
                ch1 = ifft(Erfi.apply(fft(ch1), 'notch_interp', excis));
                % Contiguous un-decimated slice about the midpoint of the
                % loaded ~1.8 s analysis window; phi/rho are measured over
                % the whole loaded window (compute_calib reads the entire
                % file, so its C_RDNS phase can differ slightly). Both
                % switch states are precomputed in D so the cached data
                % stays valid when the Phase cal switch toggles (the cache
                % key deliberately excludes the switch).
                SLICE_HALF = 1000;   % display samples each side of midpoint
                D = V.U.phoff_prep(ch0, ch1, cfg.fs, SLICE_HALF);
                D.xlim_us = 5;       % initial zoom half-width (us)
        end
        S.cache = struct('key', key, 'data', D);
    end

    switch kind
        case 'Raw: PSD (ch0 & ch1)'
            tl = tiledlayout(S.panel, 1, 1);
            ax = nexttile(tl);
            f_mhz = (D.f + cfg.freq_hz) / 1e6;
            dB0 = 10*log10(D.P0);
            dB1 = 10*log10(D.P1);
            % Thin raw traces use a ~25% darker pastel so
            % they're visible against a white background), thick
            % median-smoothed envelopes on top in fully-saturated b/r.
            plot(ax, f_mhz, dB0, 'Color', [0.3 0.45 0.75 0.45], 'LineWidth', 0.5);
            hold(ax, 'on');
            plot(ax, f_mhz, dB1, 'Color', [0.75 0.375 0.225 0.45], 'LineWidth', 0.5);
            % Envelope width from cfg.rfi_env_khz (same knob as the season PSD
            % envelope), converted to display bins via the decimated axis
            % spacing. Assumes a normal multi-segment capture (numel(D.f) >= 2).
            sm = rfi_env_window(cfgdef('rfi_env_khz', 1000), D.f(2) - D.f(1));
            plot(ax, f_mhz, movmedian(dB0, sm), 'b', 'LineWidth', 1.8);
            plot(ax, f_mhz, movmedian(dB1, sm), 'r', 'LineWidth', 1.8);
            xline(ax, cfg.freq_hz/1e6, ':', 'LO', 'LabelVerticalAlignment', 'bottom', ...
                  'Color', [0.4 0.4 0.4]);
            legend(ax, {'ch0','ch1','ch0 envelope','ch1 envelope'}, 'Location', 'best');
            xlabel(ax, 'RF frequency (MHz)');  ylabel(ax, 'PSD (dB)');
            % Title: '<base>' or '<base> w/ Notch'.
            title(ax, raw_cap_title(base, D), 'Interpreter', 'none');
            grid(ax, 'on');  xlim(ax, [min(f_mhz) max(f_mhz)]);
            ylim(ax, [-30 30]);  % static dB range, fixed across base/notch and Signal/NL/L for easy comparison
        case 'Raw: Cross-correlation profile'
            tl = tiledlayout(S.panel, 2, 1);
            ax1 = nexttile(tl);
            plot(ax1, D.lag, abs(D.R));
            xline(ax1, cfg.peak_lag, 'r--', 'peak\_lag');
            xlabel(ax1, 'Lag (samples)');  ylabel(ax1, '|R_{xy}|');
            % Title: '<base>' or '<base> w/ Notch'.
            title(ax1, raw_cap_title(base, D), 'Interpreter', 'none');
            grid(ax1, 'on');
            ylim(ax1, [0 D.ymax]);   % anchored to base peak — shared across base/notch
            ax2 = nexttile(tl);
            zoom_w = 25;
            zi = abs(D.lag) <= zoom_w;
            yyaxis(ax2, 'left');
            plot(ax2, D.lag(zi), abs(D.R(zi)), '.-');
            ylabel(ax2, '|R_{xy}|');
            ylim(ax2, [0 D.ymax]);   % same base-anchored scale as the full view
            yyaxis(ax2, 'right');
            plot(ax2, D.lag(zi), angle(D.R(zi)) * 180/pi, '.-');
            ylabel(ax2, 'Phase (deg)');  ylim(ax2, [-180 180]);
            xline(ax2, cfg.peak_lag, 'r--');
            xlabel(ax2, 'Lag (samples)');
            title(ax2, '\pm25 lags');
            grid(ax2, 'on');
        case 'Raw: Cross-correlation Comparison'
            tl = tiledlayout(S.panel, 3, 1);
            title(tl, raw_cap_title(base, D), 'Interpreter', 'none');
            zoom_w = 25;
            for ti = 1:numel(D.types)
                nm = D.types(ti);
                Di = D.(nm);
                ax = nexttile(tl);
                if isempty(Di.base) || strlength(Di.base) == 0
                    text(ax, 0.5, 0.5, "No " + xcorr_cmp_label(nm) + " capture found", ...
                         'HorizontalAlignment', 'center', 'Interpreter', 'none');
                    axis(ax, 'off');
                    continue;
                end
                zi = abs(Di.lag) <= zoom_w;
                yyaxis(ax, 'left');
                plot(ax, Di.lag(zi), abs(Di.R(zi)), '.-');
                ylabel(ax, '|R_{xy}|');
                ylim(ax, [0 D.ymax]);
                yyaxis(ax, 'right');
                plot(ax, Di.lag(zi), angle(Di.R(zi)) * 180/pi, '.-');
                ylabel(ax, 'Phase (deg)');  ylim(ax, [-180 180]);
                xline(ax, cfg.peak_lag, 'r--');
                xlabel(ax, 'Lag (samples)');
                title(ax, xcorr_cmp_label(nm), 'Interpreter', 'none');
                grid(ax, 'on');
            end
        case 'Raw: Spectrogram'
            tl = tiledlayout(S.panel, 2, 1);
            P0 = 10*log10(D.img0);
            P1 = 10*log10(D.img1);
            % Color scale anchored to the BASE (unfiltered) joint maximum,
            % top 70 dB below it — identical across base/notch
            % so the filter effect is directly comparable.
            cmax = D.cmax_db;
            cl = [cmax - 70, cmax];
            % Figure title carries the filename + active filter (e.g.
            % '<base> w/ Notch'); sidebar Title override replaces this whole
            % string (see apply_overrides). Subplot titles are static labels.
            title(tl, raw_cap_title(base, D), 'Interpreter', 'none');
            ax1 = nexttile(tl);
            imagesc(ax1, D.tms, D.fmhz, P0);
            axis(ax1, 'xy');  clim(ax1, cl);
            ylabel(ax1, 'RF frequency (MHz)');
            title(ax1, 'CH0 (Direct)', 'Interpreter', 'none');
            cb = colorbar(ax1);  cb.Label.String = 'Power (dB)';
            ax2 = nexttile(tl);
            imagesc(ax2, D.tms, D.fmhz, P1);
            axis(ax2, 'xy');  clim(ax2, cl);
            xlabel(ax2, 'Time (ms)');  ylabel(ax2, 'RF frequency (MHz)');
            title(ax2, 'CH1 (Reflected)', 'Interpreter', 'none');
            cb = colorbar(ax2);  cb.Label.String = 'Power (dB)';
        case 'Raw: FFT Amplitude'
            tl = tiledlayout(S.panel, 1, 1);
            ax = nexttile(tl);
            f_mhz = (D.f + cfg.freq_hz) / 1e6;
            % Thin faded raw traces, thick median-smoothed envelopes on top
            plot(ax, f_mhz, D.A0, 'Color', [0.4 0.6 1.0 0.45], 'LineWidth', 0.5);
            hold(ax, 'on');
            plot(ax, f_mhz, D.A1, 'Color', [1.0 0.5 0.3 0.45], 'LineWidth', 0.5);
            % Envelope width from cfg.rfi_env_khz, converted to display bins via
            % the decimated axis spacing. Assumes numel(D.f) >= 2 (normal capture).
            sm = rfi_env_window(cfgdef('rfi_env_khz', 1000), D.f(2) - D.f(1));
            plot(ax, f_mhz, movmedian(D.A0, sm), 'b', 'LineWidth', 1.8);
            plot(ax, f_mhz, movmedian(D.A1, sm), 'r', 'LineWidth', 1.8);
            xline(ax, cfg.freq_hz/1e6, ':', 'LO', 'LabelVerticalAlignment', 'bottom', ...
                  'Color', [0.4 0.4 0.4]);
            legend(ax, {'ch0 raw','ch1 raw','ch0 envelope','ch1 envelope'}, 'Location', 'best');
            xlabel(ax, 'RF frequency (MHz)');
            ylabel(ax, 'Amplitude (dB)');
            title(ax, raw_cap_title(base, D), 'Interpreter', 'none');
            grid(ax, 'on');
            xlim(ax, [min(f_mhz) max(f_mhz)]);
        case 'Raw: Time domain'
            tl = tiledlayout(S.panel, 2, 1);
            title(tl, raw_cap_title(base, D), 'Interpreter', 'none');
            ax1 = nexttile(tl);
            plot(ax1, D.t_ms, D.I0, D.t_ms, D.Q0);
            legend(ax1, {'I', 'Q'}, 'Location', 'best');
            ylabel(ax1, 'ADC count');
            title(ax1, 'CH0 (direct)', 'Interpreter', 'none');
            grid(ax1, 'on');
            ax2 = nexttile(tl);
            plot(ax2, D.t_ms, D.I1, D.t_ms, D.Q1);
            legend(ax2, {'I', 'Q'}, 'Location', 'best');
            xlabel(ax2, 'Time (ms)');  ylabel(ax2, 'ADC count');
            title(ax2, 'CH1 (reflected)', 'Interpreter', 'none');
            grid(ax2, 'on');
            % Match both channels' y-axes so amplitudes are directly
            % comparable (both are ADC counts, naturally symmetric about 0).
            % D.ymax is anchored to the base (unfiltered) amplitude, so the
            % notch view shares the 'none' limits and the RFI removal shows
            % as a real reduction rather than being rescaled to fill.
            if D.ymax > 0
                yl = [-D.ymax, D.ymax] * 1.05;
                ylim(ax1, yl);  ylim(ax2, yl);
            end
        case 'Raw: Phase Offset'
            if D.n == 0
                show_msg('No samples in this capture.');
                return;
            end
            % The correction rotates CH1 by the measured offset so the
            % correlated components align (the lag-0 cross-correlation
            % phase goes to 0); sample-exact overlap is not expected since
            % each channel keeps its own receiver noise and gain. With no
            % usable correlation (phi NaN) the switch is a no-op.
            corr_on = strcmp(S.sw_phaseoff.Value, 'On') && isfinite(D.phi);
            if corr_on
                r1 = D.r1_on;   leg1 = 'CH1 (reflected, corrected)';
            else
                r1 = D.r1_off;  leg1 = 'CH1 (reflected)';
            end
            tl = tiledlayout(S.panel, 1, 1);
            ax = nexttile(tl);
            plot(ax, D.t_us, D.r0, D.t_us, r1);
            legend(ax, {'CH0 (direct)', leg1}, 'Location', 'best');
            xlabel(ax, ['Time from window midpoint (' char(181) 's)']);
            ylabel(ax, 'Amplitude');
            % Title rule lives in the pure V.U.phoff_title helper (numbers
            % only while the correction is applied; n/a when on with no
            % usable correlation) so all three states are unit-tested.
            title(ax, V.U.phoff_title(base, D.phi, D.rho, ...
                      strcmp(S.sw_phaseoff.Value, 'On')), 'Interpreter', 'none');
            grid(ax, 'on');
            % Open zoomed to the window midpoint so the inter-channel offset
            % is visible; zoom out interactively for the full plotted slice.
            xw = min(D.xlim_us, max(abs(D.t_us)));
            if xw > 0, xlim(ax, [-xw, xw]); end
            % Symmetric limits from the union of the Off/On traces so the
            % scale does not jump when the switch toggles.
            if isfinite(D.ymax) && D.ymax > 0
                ylim(ax, [-D.ymax, D.ymax] * 1.05);
            end
    end
end


function [ch0, ch1] = rr_load_capture(V, base)
    cfg = V.cfg;
    M = V.M;
    n_want = V.n_want;
    % Resolve the capture's run folder or flat data root rather than assuming
    % every file lives directly in cfg.data_dir.
    folder = rr_folder_for(V, base);
    p0 = fullfile(folder, base + "_ch0.dat");
    p1 = fullfile(folder, base + "_ch1.dat");
    if ~isfile(p0) || ~isfile(p1)
        error('Capture files for %s not found under %s.', base, cfg.data_dir);
    end
    ch0 = M.read_channel(p0, n_want);
    ch1 = M.read_channel(p1, n_want);
    n = min(numel(ch0), numel(ch1));
    ch0 = ch0(1:n);  ch1 = ch1(1:n);
end


function folder = rr_folder_for(V, base)
    cfg = V.cfg;
    % base_name -> containing folder. The discovery passes (rebuild_caplist /
    % rr_nearest_capture) record folders in V.cap_folders as they scan; this is
    % the lookup with a self-sufficient fallback so a capture reached by any
    % path still resolves. base names are globally unique, so one map is sound.
    key = char(base);
    if isKey(V.cap_folders, key)
        folder = V.cap_folders(key);
        return;
    end
    % Not indexed yet: locate it anywhere under data_dir (recursive '**' matches
    % both the per-run subfolders and the flat season), cache, and return. Fall
    % back to data_dir so the caller's not-found error still fires sensibly.
    d = dir(fullfile(cfg.data_dir, '**', [key '_ch0.dat']));
    if ~isempty(d)
        folder = d(1).folder;
        V.cap_folders(key) = folder;
    else
        folder = cfg.data_dir;
    end
end


function lbl = xcorr_cmp_label(ctype)
    % Friendly subplot title for the Cross-correlation Comparison view —
    % CAP_PATTERNS keys ('Signal'/'NL'/'L') are filename-driven, not
    % display-friendly.
    names = struct('Signal', 'Signal', 'NL', 'Noise+Load', 'L', 'Load');
    lbl = names.(char(ctype));
end


function [near_base, near_ts] = rr_nearest_capture(V, ctype, ref_ts)
    cfg = V.cfg;
    M = V.M;
    CAP_PATTERNS = V.CAP_PATTERNS;
    % Base name (sans _ch0.dat) of the ctype ('Signal'/'NL'/'L') capture in
    % cfg.data_dir closest in time to ref_ts, for the Cross-correlation
    % Comparison view. Independent of the current date-range filter and
    % the dd_ctype/dd_cap selection — scans the full data_dir each call.
    near_base = strings(0, 1);
    near_ts   = NaT;
    if ~isfolder(cfg.data_dir), return; end
    % Recursive '**' scan so the nearest Signal/NL/L capture is found across the
    % run subfolders or the flat data root. Record each
    % scanned capture's folder so rr_load_capture can resolve the picked file
    % even though it may be out of the current date range / another run folder.
    d = dir(fullfile(cfg.data_dir, '**', CAP_PATTERNS.(ctype)));
    if isempty(d), return; end
    bases   = string(erase({d.name}',   '_ch0.dat'));
    folders = string({d.folder}');
    ts = M.base_ts(bases);
    ok = ~isnat(ts);
    bases = bases(ok);  ts = ts(ok);  folders = folders(ok);
    if isempty(bases), return; end
    for i = 1:numel(bases)
        V.cap_folders(char(bases(i))) = char(folders(i));
    end
    [~, kmin] = min(abs(ts - ref_ts));
    near_base = bases(kmin);
    near_ts   = ts(kmin);
end

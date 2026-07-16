function compute_L1(cfg)
% Compute L1 cross-correlation products from UHF signal capture pairs.
% MATLAB translation of Chan3ProcAll_boise_multi.py — incremental (appends
% only pairs missing from the output CSVs), batched CSV appends (every
% cfg.batch_size pairs), GPU path (serial, gpuArray FFTs) or CPU path (parfor).
%
% Input: UHF_YYYYMMDDHHMMSS_ch0.dat (direct) / _ch1.dat (reflected), each
% one channel of interleaved I/Q int16 (160 MB per 2 s capture at 20 MS/s);
% a pair needs >= cfg.min_bytes per file.
%
% Output: cfg.out_dir/BrundageSoOp_L1_sig.csv + rejected_sig.csv (appended
% per batch; one pair of files per cfg.rfi_methods entry). BrundageSoOp_L1_sig.csv
% columns: timestamp, base_name, peak_lag, meas_peak_lag, peak_amplitude,
% peak_phase_deg, snr_db, noise_floor, segments_processed, file_size_bytes,
% overflow_flag, peak_amplitude_fd, peak_phase_deg_fd, peak_amplitude_fd_muos,
% peak_phase_deg_fd_muos, pow_ch0_fd, pow_ch0_fd_muos, pow_ch1_fd,
% pow_ch1_fd_muos.
%   - meas_peak_lag: MEASURED discrete argmax of |R_xy| over +-lag_half_win
%     (diagnostic only — the observable is always extracted at cfg.peak_lag).
%   - peak_amplitude_fd/peak_phase_deg_fd: cross-spectrum evaluated at
%     cfg.peak_lag directly (no ifft/sinc round-trip); _fd_muos restricts
%     the same sum to cfg.muos_bands.
%   - pow_ch0_fd/pow_ch1_fd: windowed per-channel band powers (ADC^2) from the
%     SAME Hann-windowed segment spectra as peak_*_fd — sum_k |F|^2/n_segs/npts^2
%     with the SAME 1/npts^2 normalization (direct = ch0, reflected = ch1);
%     _fd_muos restricts the sum to cfg.muos_bands (NaN when muos_bands is
%     empty). The window/normalization factors cancel in ratios such as
%     peak_amplitude_fd_muos^2/(pow_ch0_fd_muos*pow_ch1_fd_muos), so those
%     ratios are window-independent; the columns feed the sigma0 stage's
%     direct-referenced calibration.
%   - overflow_flag (0/1): from cfg.overflow_file; 0 for all rows with a
%     warning logged if the file is absent/missing. compute_L2 excludes
%     overflow_flag==1 rows from the phase time series.
%
% Schema migration (behavior unchanged numerically): a sig CSV missing
% peak_phase_deg_fd OR any of the four channel-power columns (pow_ch0_fd,
% pow_ch0_fd_muos, pow_ch1_fd, pow_ch1_fd_muos — a partial set counts as
% missing) is archived (collision-safe yyyyMMdd_HHmmss suffix) and the season
% reprocessed: existing columns are recomputed byte-identically and the missing
% columns added (the FFT-derived columns can't be back-patched); a sig CSV
% missing overflow_flag is patched in place from cfg.overflow_file, no
% reprocessing.
%
% cfg fields consumed: data_dir, out_dir, fs, Ti, num_segs, peak_lag,
% lag_half_win, min_bytes, batch_size (default 200), use_gpu, overflow_file,
% rfi_methods (default {'none'}), rfi_bands, muos_bands.
%

    % --- Find ch0/ch1 pairs (mirrors Python find_file_pairs) ---
    % 'UHF_2' matches signal files (UHF_2025..., UHF_2026...) but not the
    % calibration prefixes UHF__NL_ / UHF__L_ (double underscore). The '**'
    % recurses into the cryosoop <YYYYMMDD>/<HHMMSS>/ per-run subfolders while
    % still matching a legacy flat directory (** matches zero folder levels);
    % each partner path is built from the hit's .folder (process_pair).
    ch0_files = dir(fullfile(cfg.data_dir, '**', 'UHF_2*_ch0.dat'));
    if isempty(ch0_files)
        fprintf('[L1] No UHF_*_ch0.dat files found in %s\n', cfg.data_dir);
        return;
    end
    base_names = string(erase({ch0_files.name}', '_ch0.dat'));

    % --- Timezone-provenance guard (first, before any setup side effects) ---
    % UTC-era cryosoop runs record "wall_clock": "UTC" in their per-run
    % summary.json (legacy runs lack the field). Processing such runs with a
    % local-zone cfg.capture_tz would silently shift every satellite-geometry
    % product by the UTC offset, so refuse outright. capture_tz absent or
    % 'UTC' is consistent with UTC stamps — no scan needed.
    if isfield(cfg, 'capture_tz') && ~isempty(cfg.capture_tz) && ~strcmpi(cfg.capture_tz, 'UTC')
        run_dirs = unique(string({ch0_files.folder}'));
        for rd = run_dirs(:)'
            sj = fullfile(rd, 'summary.json');
            if ~isfile(sj), continue; end
            try
                s = jsondecode(fileread(sj));
            catch
                continue;   % unreadable summary — not a provenance signal
            end
            if isfield(s, 'wall_clock') && strcmpi(string(s.wall_clock), 'UTC')
                error('BrundageSoOp:captureTzMismatch', ...
                      ['%s is a UTC-stamped cryosoop run (summary.json wall_clock=UTC) but ' ...
                       'cfg.capture_tz=''%s''. Set site_config.json "capture_tz" to "UTC" for ' ...
                       'UTC-era data (local-zone capture_tz is only for legacy pre-UTC ' ...
                       'seasons), and never mix the two eras under one data root.'], ...
                      rd, string(cfg.capture_tz));
            end
        end
    end

    % --- RFI excision methods + per-method output directories ---
    % Each method writes a self-contained product set so every downstream stage
    % runs unchanged per dir: 'none' -> cfg.out_dir (v3 path), 'notch_interp' ->
    % <out_dir>_notch. A single read/FFT per pair feeds all selected methods
    % (see process_pair). {'none'} reproduces the original single-output behavior.
    methods = cellstr(getfield_default(cfg, 'rfi_methods', {'none'}));
    E_rfi   = rfi_excise();
    if cfg.use_gpu && any(~strcmp(methods, 'none'))
        error('compute_L1:gpuRFI', ['RFI excision is CPU-only — set cfg.use_gpu ' ...
              '= false when cfg.rfi_methods includes a non-none method.']);
    end
    nM       = numel(methods);
    out_sig  = cell(nM, 1);  out_rej = cell(nM, 1);
    for mi = 1:nM
        d           = E_rfi.method_out_dir(cfg.out_dir, methods{mi});
        out_sig{mi} = fullfile(d, 'BrundageSoOp_L1_sig.csv');
        out_rej{mi} = fullfile(d, 'rejected_sig.csv');
    end

    % --- Load overflow base names (find_overflows output) ---
    if isfield(cfg, 'overflow_file') && isfile(cfg.overflow_file)
        of_lines = strtrim(splitlines(fileread(cfg.overflow_file)));
        overflow_set = of_lines(strlength(of_lines) > 0);
        fprintf('[L1] Overflow list loaded: %d flagged captures from %s\n', ...
                numel(overflow_set), cfg.overflow_file);
    else
        overflow_set = strings(0, 1);
        if ~isfield(cfg, 'overflow_file')
            fprintf(['[L1] WARNING: cfg.overflow_file not set — overflow_flag will ' ...
                     'be 0 for all rows. Add cfg.overflow_file = fullfile(cfg.out_dir, ' ...
                     '''overflow_timestamps.txt'') to BrundageSoOp.m.\n']);
        else
            fprintf(['[L1] WARNING: overflow file not found (%s) — overflow_flag will ' ...
                     'be 0 for all rows.\n'], cfg.overflow_file);
        end
    end

    % --- Archive + reprocess any L1 sig CSV missing FFT-derived columns ---
    % The freq-domain phase (peak_*_fd) and channel-power (pow_ch*_fd) columns
    % both need per-segment FFTs and can't be back-patched, so a CSV missing the
    % fd phase OR any of the four channel-power columns (a partial set included)
    % is archived and the season reprocessed. Archive names carry a full
    % yyyyMMdd_HHmmss stamp so repeated migrations never collide.
    pow_cols = {'pow_ch0_fd', 'pow_ch0_fd_muos', 'pow_ch1_fd', 'pow_ch1_fd_muos'};
    for mi = 1:nM
        os = out_sig{mi};
        if ~isfile(os), continue; end
        try
            v = readtable(os, 'TextType', 'string').Properties.VariableNames;
        catch
            continue;   % unreadable file is reported in the done loop below
        end
        need_fdphase = ~ismember('peak_phase_deg_fd', v);
        need_chanpow = ~all(ismember(pow_cols, v));
        if need_fdphase || need_chanpow
            if need_fdphase, tag = "fdphase"; else, tag = "chanpow"; end
            stamp    = string(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
            archived = strrep(os, '.csv', "_pre_" + tag + "_" + stamp + ".csv");
            movefile(os, archived);
            fprintf(['[L1] %s lacks the frequency-domain phase / channel-power ' ...
                     'columns — archived to %s; reprocessing to add them.\n'], ...
                     os, archived);
        end
    end

    % --- Incremental update: skip bases already processed OR rejected ---
    % Per-method incremental.
    done = cell(nM, 1);
    for mi = 1:nM
        d = strings(0, 1);
        for csv_path = {out_sig{mi}, out_rej{mi}}
            if isfile(csv_path{1})
                try
                    prev = readtable(csv_path{1}, 'TextType', 'string');
                    d = [d; prev.base_name]; %#ok<AGROW>
                catch ME
                    error(['compute_L1: could not read existing %s (%s). ' ...
                           'If a previous run was killed mid-append, the last ' ...
                           'line may be truncated — inspect and remove it, ' ...
                           'then re-run.'], csv_path{1}, ME.message);
                end
            end
        end
        done{mi} = d;
    end

    % --- Patch existing L1 CSV(s) if overflow_flag column is missing ---
    % Fast CSV-only patch — no signal reprocessing needed.
    for mi = 1:nM
        os = out_sig{mi};
        if ~isfile(os), continue; end
        try
            existing = readtable(os, 'TextType', 'string');
            if ~ismember('overflow_flag', existing.Properties.VariableNames)
                if ~isempty(overflow_set)
                    existing.overflow_flag = uint8(ismember(existing.base_name, overflow_set));
                    n_flagged = sum(existing.overflow_flag);
                else
                    existing.overflow_flag = zeros(height(existing), 1, 'uint8');
                    n_flagged = 0;
                end
                writetable(existing, os);
                fprintf(['[L1] Patched %s with overflow_flag column ' ...
                         '(%d rows flagged) — no signal reprocessing needed.\n'], os, n_flagged);
            end
        catch ME
            fprintf('[L1] WARNING: could not patch overflow_flag into %s: %s\n', ...
                    os, ME.message);
        end
    end

    needed = false(numel(base_names), nM);
    for mi = 1:nM
        needed(:, mi) = ~ismember(base_names, done{mi});
    end
    new_idx = find(any(needed, 2));

    if isempty(new_idx)
        fprintf('[L1] No new pairs to process (all %d method(s) up to date).\n', nM);
        return;
    end
    fprintf('[L1] %d new pair(s) across %d method(s) (%d total in data dir).\n', ...
            numel(new_idx), nM, numel(base_names));

    for mi = 1:nM
        dm = fileparts(out_sig{mi});
        if ~isfolder(dm), mkdir(dm); end
    end

    % --- Precompute window (shared by all pairs) ---
    npts = floor(cfg.fs * cfg.Ti);  % samples per segment, e.g. 18,000,000
    n    = (0:npts-1)';
    win  = 0.5 * (1 - cos(2*pi*n / (npts-1)));  % Hanning, matches numpy.hanning(N)

    % --- RFI excision operators (built once for this FFT length) ---
    excis     = E_rfi.prepare(cfg, npts);
    apply_rfi = E_rfi.apply;   % handle broadcast to workers

    % --- Frequency-domain phase: delay ramp + MUOS-band mask (built once) ---
    % The phase observable is read straight from the averaged cross-spectrum S as
    %   c = sum(S .* ramp) / npts^2  == R_xy(cfg.peak_lag)  (exact; no ifft/sinc).
    % nu is the signed normalized frequency (cyc/sample) of each UNSHIFTED fft bin
    % from the SAME bin map rfi_excise uses, so ramp and the RFI/MUOS masks share
    % one frequency convention. +1j matches MATLAB ifft's +j (sign-critical).
    nu   = (E_rfi.bin_freqs_rf(cfg.freq_hz, cfg.fs, npts) - cfg.freq_hz) / cfg.fs;
    ramp = exp(1j * 2*pi * nu * cfg.peak_lag);
    % freq_muos: restrict the same sum to the four MUOS sub-channels only.
    muos_bands = getfield_default(cfg, 'muos_bands', []);
    if isempty(muos_bands)
        muos_mask = false(npts, 1);
    else
        muos_mask = E_rfi.band_mask(muos_bands, cfg.freq_hz, cfg.fs, npts);
    end

    if ~isfield(cfg, 'batch_size'), cfg.batch_size = 200; end

    % --- Batched processing: append CSVs after each batch so an interrupted
    %     run loses at most one batch of work. ---
    n_new     = numel(new_idx);
    n_batches = ceil(n_new / cfg.batch_size);
    t_start   = tic;

    for b = 1:n_batches
        bi = new_idx((b-1)*cfg.batch_size + 1 : min(b*cfg.batch_size, n_new));
        nb = numel(bi);
        rows    = cell(nb, 1);
        rejects = cell(nb, 1);

        if cfg.use_gpu
            % Serial with GPU: one 18M-point FFT at a time on the A30.
            for k = 1:nb
                f = ch0_files(bi(k));
                [rows{k}, rejects{k}] = process_pair(f, base_names(bi(k)), cfg, win, npts, overflow_set, methods, apply_rfi, excis, ramp, muos_mask);
            end
        else
            f_batch    = ch0_files(bi);
            base_batch = base_names(bi);
            ovf_set    = overflow_set;   % broadcast to parfor workers
            parfor k = 1:nb
                [rows{k}, rejects{k}] = process_pair(f_batch(k), base_batch(k), cfg, win, npts, ovf_set, methods, apply_rfi, excis, ramp, muos_mask);
            end
        end

        % rows{k} is a 1xnM cell (one L1 row per method, or [] if rejected);
        % append each method only for the batch pairs it still needs.
        for mi = 1:nM
            sel = needed(bi, mi);
            append_rows(out_sig{mi}, cellfun(@(rk) rk{mi}, rows(sel), 'UniformOutput', false));
            append_rows(out_rej{mi}, rejects(sel));
        end

        done_pairs = min(b*cfg.batch_size, n_new);
        fprintf('[L1] Batch %d/%d done — %d/%d pairs, %.1f min elapsed.\n', ...
                b, n_batches, done_pairs, n_new, toc(t_start)/60);
    end

    fprintf('[L1] Complete. Results → %s\n', strjoin(string(out_sig), ', '));
end


% =========================================================================
function append_rows(csv_path, row_cells)
% Append non-empty result structs to a CSV (header written on first create).
    valid = row_cells(~cellfun(@isempty, row_cells));
    if isempty(valid), return; end
    T = struct2table(vertcat(valid{:}));
    if isfile(csv_path)
        writetable(T, csv_path, 'WriteMode', 'append', 'WriteVariableNames', false);
    else
        writetable(T, csv_path);
    end
end


% =========================================================================
function [rows, rej] = process_pair(f_ch0, base_name, cfg, win, npts, overflow_set, methods, apply_rfi, excis, ramp, muos_mask)
% Process one ch0/ch1 pair: read both channels once, then for EACH RFI method
% form the cross-correlation and extract amplitude/phase/SNR at cfg.peak_lag.
% Returns rows = 1xnumel(methods) cell (one L1 row struct per method, in the
% same order as methods) or all-empty if the pair is rejected; rej is the
% shared rejection struct. overflow_set: base names with known UHD overflows.
% ramp/muos_mask: precomputed delay phase ramp (full band) and MUOS-band mask
% for the frequency-domain phase (peak_*_fd / peak_*_fd_muos).

    nMeth = numel(methods);
    rows  = cell(1, nMeth);
    rej   = [];

    ch0_path = fullfile(f_ch0.folder, f_ch0.name);
    ch1_path = fullfile(f_ch0.folder, base_name + "_ch1.dat");

    % Missing partner file.
    d1 = dir(ch1_path);
    if isempty(d1)
        rej = make_reject(base_name, f_ch0.bytes, 'missing_ch1');
        return;
    end

    % Size gate: both channel files must hold cfg.num_segs full segments.
    % Reboot stubs and truncated captures land here.
    if f_ch0.bytes < cfg.min_bytes || d1.bytes < cfg.min_bytes
        rej = make_reject(base_name, min(f_ch0.bytes, d1.bytes), 'too_small');
        return;
    end

    % Read both channels. Each file is one channel, interleaved I/Q int16.
    % Only the first num_segs*npts samples are needed (Python reads the
    % same leading segments sequentially).
    n_want = npts * cfg.num_segs;
    ch0 = read_channel(ch0_path, n_want);
    ch1 = read_channel(ch1_path, n_want);

    n_segs_avail = floor(min(numel(ch0), numel(ch1)) / npts);
    n_segs_avail = min(n_segs_avail, cfg.num_segs);
    if n_segs_avail == 0
        rej = make_reject(base_name, min(f_ch0.bytes, d1.bytes), 'short_read');
        return;
    end

    % Coherent averaging of per-segment cross-correlations, accumulated per
    % method. The unfiltered F0,F1 are computed once and reused; each method
    % applies its identical-on-both-channels frequency-domain operator
    % (rfi_excise), so the cross-spectrum is reweighted with no differential
    % phase. 'none' returns F0,F1 unchanged -> identical to the v3 path.
    % Accumulate the per-segment CROSS-SPECTRUM S = F0m.*conj(F1m) (unshifted
    % fft order), not R_xy: the phase observable is read straight from S in the
    % frequency domain (no ifft/sinc), and R_xy is recovered with a single ifft
    % after averaging for the magnitude QA.
    % P0_sum/P1_sum accumulate the per-channel windowed POWER spectra |F|^2 on
    % the SAME segments and RFI operators as S_sum, so the channel powers below
    % share c_full's window and 1/npts^2 normalization (direct=ch0, reflected=ch1).
    S_sum  = repmat({zeros(npts, 1)}, 1, nMeth);
    P0_sum = repmat({zeros(npts, 1)}, 1, nMeth);
    P1_sum = repmat({zeros(npts, 1)}, 1, nMeth);
    for seg = 1:n_segs_avail
        i1 = (seg-1)*npts + 1;
        i2 =  seg   *npts;

        % NOTE: .* with column slices — no transpose of complex data here.
        % (A ' conjugate-transpose would silently negate every phase.)
        s0 = ch0(i1:i2) .* win;
        s1 = ch1(i1:i2) .* win;

        if cfg.use_gpu
            s0 = gpuArray(s0);
            s1 = gpuArray(s1);
        end

        F0 = fft(s0);
        F1 = fft(s1);

        for mi = 1:nMeth
            F0m = apply_rfi(F0, methods{mi}, excis);
            F1m = apply_rfi(F1, methods{mi}, excis);
            S_seg  = F0m .* conj(F1m);   % cross-spectrum (unshifted fft order)
            P0_seg = abs(F0m).^2;        % direct   power spectrum (same window)
            P1_seg = abs(F1m).^2;        % reflected power spectrum (same window)
            if cfg.use_gpu
                S_seg  = gather(S_seg);
                P0_seg = gather(P0_seg);
                P1_seg = gather(P1_seg);
            end
            S_sum{mi}  = S_sum{mi}  + S_seg;
            P0_sum{mi} = P0_sum{mi} + P0_seg;
            P1_sum{mi} = P1_sum{mi} + P1_seg;
        end
    end

    % Datetime (not raw digit string) so the CSV round-trips through
    % readtable and matches the Python summary format (yyyy-MM-dd HH:mm:ss).
    ts       = base_to_datetime(base_name);
    ovf      = uint8(ismember(base_name, overflow_set));
    has_muos = any(muos_mask);
    for mi = 1:nMeth
        S_avg = S_sum{mi} / n_segs_avail;

        % Magnitude QA from the lag-domain profile (one exact ifft). The sinc
        % peak_amplitude/peak_phase_deg are kept for the time-domain comparison.
        R_xy = fftshift(ifft(S_avg)) / npts;
        [peak_amp, peak_phase_deg, snr_db, noise_floor, meas_peak_lag] = ...
            extract_peak(R_xy, npts, cfg.peak_lag, cfg.lag_half_win);

        % Frequency-domain phase: evaluate the cross-spectrum at cfg.peak_lag
        % directly (== R_xy(peak_lag), no sinc truncation). c_full uses every
        % bin; c_muos uses only the four MUOS sub-channels (freq_muos).
        c_full = sum(S_avg .* ramp) / npts^2;
        if has_muos
            c_muos = sum(S_avg(muos_mask) .* ramp(muos_mask)) / npts^2;
        else
            c_muos = complex(NaN, NaN);
        end

        % Windowed per-channel band powers from the SAME averaged spectra, with
        % the SAME 1/npts^2 normalization as c_full (window factor cancels in
        % |c|^2/(pow_ch0*pow_ch1) ratios). _muos restricts to the MUOS bins like
        % c_muos, NaN when the band is absent. Direct = ch0, reflected = ch1.
        P0_avg = P0_sum{mi} / n_segs_avail;
        P1_avg = P1_sum{mi} / n_segs_avail;
        pow_ch0_fd = sum(P0_avg) / npts^2;
        pow_ch1_fd = sum(P1_avg) / npts^2;
        if has_muos
            pow_ch0_fd_muos = sum(P0_avg(muos_mask)) / npts^2;
            pow_ch1_fd_muos = sum(P1_avg(muos_mask)) / npts^2;
        else
            pow_ch0_fd_muos = NaN;
            pow_ch1_fd_muos = NaN;
        end

        row = struct();
        row.timestamp              = ts;
        row.base_name              = base_name;
        row.peak_lag               = cfg.peak_lag;
        row.meas_peak_lag          = meas_peak_lag;
        row.peak_amplitude         = peak_amp;
        row.peak_phase_deg         = peak_phase_deg;
        row.snr_db                 = snr_db;
        row.noise_floor            = noise_floor;
        row.segments_processed     = n_segs_avail;
        row.file_size_bytes        = f_ch0.bytes;
        row.overflow_flag          = ovf;
        row.peak_amplitude_fd      = abs(c_full);
        row.peak_phase_deg_fd      = angle(c_full) * (180/pi);
        row.peak_amplitude_fd_muos = abs(c_muos);
        row.peak_phase_deg_fd_muos = angle(c_muos) * (180/pi);
        row.pow_ch0_fd             = pow_ch0_fd;
        row.pow_ch0_fd_muos        = pow_ch0_fd_muos;
        row.pow_ch1_fd             = pow_ch1_fd;
        row.pow_ch1_fd_muos        = pow_ch1_fd_muos;
        rows{mi} = row;
    end
end


% =========================================================================
function rej = make_reject(base_name, bytes, reason)
    rej.base_name       = base_name;
    rej.file_size_bytes = bytes;
    rej.reason          = string(reason);
end


% =========================================================================
function ts = base_to_datetime(base_name)
% Parse the 14-digit YYYYMMDDHHMMSS timestamp out of a base filename.
    m = regexp(base_name, '\d{14}', 'match', 'once');
    if strlength(m) == 14
        ts = datetime(m, 'InputFormat', 'yyyyMMddHHmmss');
    else
        ts = NaT;
    end
    ts.Format = 'yyyy-MM-dd HH:mm:ss';
end


% =========================================================================
function ch = read_channel(filepath, n_want)
% Read up to n_want complex samples from a single-channel sc16 file.
% File layout: [I0, Q0, I1, Q1, ...] int16. Returns a complex double column.
    fid = fopen(filepath, 'rb');
    raw = fread(fid, [2, n_want], '*int16');  % row 1 = I, row 2 = Q
    fclose(fid);
    % .' on the real int16 rows — never ' on complex data (conjugates).
    ch = double(raw(1,:)).' + 1j * double(raw(2,:)).';
end


% =========================================================================
function [peak_amp, peak_phase_deg, snr_db, noise_floor, meas_peak_lag] = ...
        extract_peak(R_xy, npts, target_lag, lag_half_win)
% Extract correlation amplitude and phase at target_lag using sinc interpolation.
%
% Matches Python detect_peak_and_snr() + _extract_at_fractional_lag():
%   1. Trim to ±lag_half_win lags around lag=0 (same as Python llm/uum window).
%   2. Noise floor = mean of outer 20% of the trimmed window.
%   3. Sinc interpolation at target_lag using ±8 nearest integer lags.
%   4. SNR = 10*log10(peak_power / noise_power).
%
% npts is passed (not a full lag vector) to avoid broadcasting an 18M-element
% array to workers. Zero-lag sits at 1-indexed position npts/2+1 for even npts.

    center_idx = npts/2 + 1;
    lo_trim = max(1, center_idx - lag_half_win);
    hi_trim = min(npts, center_idx + lag_half_win);

    R_trim   = R_xy(lo_trim:hi_trim);
    lag_trim = ((lo_trim:hi_trim) - center_idx)';  % lag values in samples
    mag      = abs(R_trim);
    n        = numel(mag);

    % Measured discrete peak: lag of max |R_xy| within the analysis window —
    % the "signal arrival" the viewer's cross-correlation profile shows.
    % Diagnostic only; the observable is extracted at the fixed target_lag below.
    [~, j_meas]   = max(mag);
    meas_peak_lag = double(lag_trim(j_meas));

    % Noise floor from outer 20% of trimmed window (Python noise_fraction=0.2).
    n_noise = max(floor(n * 0.2), 10);
    noise_floor = mean([mag(1:n_noise); mag(end-n_noise+1:end)]);

    % Sinc interpolation at target_lag (±8 taps, matches Python half_win=8).
    % Python: hi = center + half_win + 1 with exclusive slice → center±8.
    % MATLAB inclusive indexing → hi = center + half_win for the same window.
    [~, center_trim] = min(abs(lag_trim - target_lag));
    half_win = 8;
    lo = max(1, center_trim - half_win);
    hi = min(n, center_trim + half_win);

    offsets = target_lag - double(lag_trim(lo:hi));
    weights = safe_sinc(offsets);

    complex_val    = sum(R_trim(lo:hi) .* weights);
    peak_amp       = abs(complex_val);
    peak_phase_deg = angle(complex_val) * (180/pi);

    if noise_floor > 0
        snr_db = 10 * log10(peak_amp^2 / noise_floor^2);
    else
        snr_db = Inf;
    end
end


% =========================================================================
function y = safe_sinc(x)
% Normalized sinc: sin(pi*x) / (pi*x), with safe handling at x=0.
% Equivalent to numpy.sinc(x) and MATLAB sinc(x) from Signal Processing Toolbox.
    y      = ones(size(x));
    nz     = (x ~= 0);
    y(nz)  = sin(pi * x(nz)) ./ (pi * x(nz));
end


% =========================================================================
function v = getfield_default(s, name, default)
% cfg field with a fallback when absent/empty (keeps {'none'} the default).
    if isfield(s, name) && ~isempty(s.(name)), v = s.(name); else, v = default; end
end

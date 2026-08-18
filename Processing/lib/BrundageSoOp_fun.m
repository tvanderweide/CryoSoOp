function F = BrundageSoOp_fun()
% Math, DSP, statistics, and data-IO helpers for BrundageSoOp_viewer.
%
% Returns a struct of function handles so the viewer can stay UI-only:
%   M = BrundageSoOp_fun();  P = M.welch_psd(x, fs, seg_len);
%
% Contains the math and data IO that feed the displays. DSP conventions are
% Hann windows, FFT/conj/fftshift ordering, dB units, circular statistics, and
% sc16 sample ordering. The viewer side panel names each plot's helper.

    F.hann_win         = @hann_win;
    F.circ_stats       = @circ_stats;
    F.sigma_phi_deg    = @sigma_phi_deg;
    F.looks_curve      = @looks_curve;
    F.run_groups       = @run_groups;
    F.aggregate        = @aggregate;
    F.first_out        = @first_out;
    F.second_out       = @second_out;
    F.welch_psd        = @welch_psd;
    F.welch_psd_filtered = @welch_psd_filtered;
    F.decimate_spectrum= @decimate_spectrum;
    F.fft_amp_fullband = @fft_amp_fullband;
    F.spectro          = @spectro;
    F.spectro_filtered = @spectro_filtered;
    F.xcorr_profile    = @xcorr_profile;
    F.xcorr_profile_filtered = @xcorr_profile_filtered;
    F.read_channel     = @read_channel;
    F.read_product     = @read_product;
    F.load_snodar      = @load_snodar;
    F.base_ts          = @base_ts;
end


% =========================================================================
% Aggregation / statistics
% =========================================================================

function [ta, ya, ys] = aggregate(t, y, mode, kind)
% kind: 'lin' (arithmetic) | 'phase' (circular, deg) | 'db' (linear-power mean)
    ok = isfinite(y);
    t = t(ok);  y = y(ok);
    switch mode
        case 'Raw captures'
            ta = t;  ya = y;  ys = [];
            return;
        case 'Per-run mean'
            grp = run_groups(t);
        case 'Daily mean'
            grp = findgroups(dateshift(t, 'start', 'day'));
        otherwise   % Range mean
            grp = ones(numel(t), 1);
    end
    ta = splitapply(@(x) min(x) + (max(x) - min(x))/2, t, grp);   % group midpoint
    switch kind
        case 'phase'
            ya = splitapply(@(x) first_out(@circ_stats, x),  y, grp);
            ys = splitapply(@(x) second_out(@circ_stats, x), y, grp);
        case 'db'
            ya = splitapply(@(x) 10*log10(mean(10.^(x/10))), y, grp);
            ys = splitapply(@std, y, grp);   % spread shown in dB
        otherwise
            ya = splitapply(@mean, y, grp);
            ys = splitapply(@std,  y, grp);
    end
end

function grp = run_groups(t)
% Group captures into collection runs: a gap > 30 min starts a new run
% (runs are 2 h apart; captures within a run are seconds apart).
% Returns group ids in the original row order, suitable for splitapply.
    [ts, order] = sort(t);
    g = cumsum([1; diff(ts) > minutes(30)]);
    grp = zeros(numel(t), 1);
    grp(order) = g;
end

function [mu, sd] = circ_stats(deg)
% Circular mean and std (degrees) — correct for ±180°-wrapped phase.
    z  = mean(exp(1i * deg2rad(deg)), 'omitnan');
    mu = rad2deg(angle(z));
    sd = rad2deg(sqrt(-2 * log(max(abs(z), eps))));
end

function s = sigma_phi_deg(rho, N_L)
% Expected thermal interferometric phase std (degrees) vs coherence MAGNITUDE
% rho and number of independent looks N_L:
%       sigma_phi = (1 / sqrt(2*N_L)) * sqrt(1 - rho^2) / rho      [radians]
% the standard high-coherence/high-look phase-noise floor. rho is the
% |coherence| (rho_DRL / rho_DRNS); the phase itself is read from C_*_phase_deg,
% not from rho. max(1-rho^2,0) keeps rho slightly > 1 (numerical) real rather
% than complex; non-positive / non-finite rho yields NaN (no envelope).
    s = (1 ./ sqrt(2 * N_L)) .* sqrt(max(1 - rho.^2, 0)) ./ rho * (180/pi);
    s(rho <= 0 | ~isfinite(rho)) = NaN;
end

function [k, adev, npair] = looks_curve(deg, grp, min_pairs)
% Non-overlapping ("static") Allan deviation of within-run block-mean phase vs
% look count k, for testing whether phase scatter integrates down thermally
% (1/sqrt(k)) or sits on a systematic pedestal.
%
% For each look count k = 1,2,3,...:
%   * within each run (grp id), the captures (in TIME ORDER) are partitioned
%     into NON-OVERLAPPING blocks of k consecutive captures;
%   * each block is reduced to its CIRCULAR mean phase (deg, wrap-safe);
%   * adjacent block means within the SAME run are differenced (wrap-safe),
%     never across a run boundary;
%   * the squared differences are pooled across all runs and
%       adev(k)  = sqrt( 0.5 * mean(diff.^2) ),   npair(k) = #pooled pairs.
%
% Differencing adjacent blocks removes each run's constant phase offset WITHOUT
% the finite-sample demeaning bias of a re-centered block std, so for white
% (thermal) phase noise adev(k) = adev(1)/sqrt(k) exactly (slope -1/2 on
% log-log). A within-run correlated systematic (drift, alternating bias, AR(1))
% makes adev(k) flatten or rise above that line -- the pedestal signature.
%
% deg       : phase in DEGREES (may be wrapped to +/-180), assumed in TIME
%             ORDER within each run (read_product sorts products by timestamp).
% grp       : run-group id per capture (e.g. M.run_groups(t)), same size as deg.
% min_pairs : drop any k whose pooled pair count npair(k) < min_pairs.
%
% Returns COLUMN vectors k, adev (deg), npair, for the retained k only (sorted
% ascending). Circular; no toolbox required. Empty outputs if nothing qualifies.
    k = zeros(0, 1);  adev = zeros(0, 1);  npair = zeros(0, 1);
    deg = deg(:);  grp = grp(:);
    ok  = isfinite(deg) & isfinite(grp);
    deg = deg(ok);  grp = grp(ok);
    if isempty(deg), return; end

    % Per-run phasor lists, in the row order supplied (time order within run).
    z_all = exp(1i * deg2rad(deg));
    runs  = unique(grp);
    runZ  = cell(numel(runs), 1);
    nmax  = 0;
    for r = 1:numel(runs)
        runZ{r} = z_all(grp == runs(r));
        nmax    = max(nmax, numel(runZ{r}));
    end
    if nmax < 2, return; end           % need >= 2 blocks somewhere for a pair

    kmax = floor(nmax / 2);            % largest k that still yields >= 1 pair
    kk   = (1:kmax)';
    av   = nan(kmax, 1);
    np   = zeros(kmax, 1);
    for ik = 1:kmax
        kc = kk(ik);
        sq_sum = 0;  pairs = 0;
        for r = 1:numel(runs)
            z  = runZ{r};
            nb = floor(numel(z) / kc);          % non-overlapping blocks of size kc
            if nb < 2, continue; end
            zc   = z(1:nb*kc);
            bm   = mean(reshape(zc, kc, nb), 1); % per-block resultant (1 x nb)
            bdeg = rad2deg(angle(bm));           % circular block-mean phase (deg)
            d    = wrap180(diff(bdeg));          % wrap-safe adjacent differences
            sq_sum = sq_sum + sum(d.^2);
            pairs  = pairs + numel(d);
        end
        np(ik) = pairs;
        if pairs > 0
            av(ik) = sqrt(0.5 * sq_sum / pairs);
        end
    end

    keep  = (np >= min_pairs) & isfinite(av);
    k     = kk(keep);
    adev  = av(keep);
    npair = np(keep);
end

function y = wrap180(x)
    y = mod(x + 180, 360) - 180;
end

function a = first_out(f, varargin),  [a, ~] = f(varargin{:}); end
function b = second_out(f, varargin), [~, b] = f(varargin{:}); end


% =========================================================================
% DSP / spectra
% =========================================================================

function w = hann_win(N)
% Hann window matching compute_L1.
    n = (0:N-1)';
    w = 0.5 * (1 - cos(2*pi*n / (N-1)));
end

function [P, f] = welch_psd(x, fs, seg_len)
% Welch-averaged PSD, non-overlapping Hann segments, fftshifted.
% ~34 averages at seg_len=2^20 over a 36M-sample capture.
    n_segs = floor(numel(x) / seg_len);
    X = reshape(x(1:n_segs*seg_len), seg_len, n_segs);
    w = hann_win(seg_len);
    P = mean(abs(fft(X .* w)).^2, 2) / (fs * (w' * w));
    P = fftshift(P);
    f = (-seg_len/2 : seg_len/2 - 1)' * (fs / seg_len);
end

function [P, f] = welch_psd_filtered(x, fs, seg_len, method, excis, applyfun)
% welch_psd with the RFI-excision operator applied to EACH segment's spectrum
% before averaging — the exact per-segment frequency-domain excision that
% compute_L1 performs, so the displayed PSD matches the pipeline. method is an
% rfi_excise method name ('none'/'notch_interp'); excis =
% rfi_excise().prepare(cfg, seg_len); applyfun = rfi_excise().apply. method
% 'none' returns the spectrum unchanged, so this reduces to welch_psd exactly.
    n_segs = floor(numel(x) / seg_len);
    X = reshape(x(1:n_segs*seg_len), seg_len, n_segs);
    w = hann_win(seg_len);
    F = fft(X .* w);                 % unshifted fft order (what apply expects)
    for c = 1:n_segs
        F(:, c) = applyfun(F(:, c), method, excis);
    end
    P = mean(abs(F).^2, 2) / (fs * (w' * w));
    P = fftshift(P);
    f = (-seg_len/2 : seg_len/2 - 1)' * (fs / seg_len);
end

function [fd, Pd] = decimate_spectrum(f, P, n_pts, mode)
% Decimate a spectrum to ~n_pts display points.
% mode 'max' (default): max-hold, preserves narrow peaks.
% mode 'mean': mean-fold, preserves notches and broadband shape.
    if nargin < 4, mode = 'max'; end
    dec = max(1, floor(numel(f) / n_pts));
    m   = floor(numel(f) / dec);
    switch mode
        case 'mean'
            Pd = mean(reshape(P(1:dec*m), dec, m), 1)';
        otherwise
            Pd = max(reshape(P(1:dec*m), dec, m), [], 1)';
    end
    fd = f(ceil(dec/2) : dec : dec*m);
end

function [A0, A1, f] = fft_amp_fullband(ch0, ch1, fs, npts)
% Full-band amplitude spectrum: |FFT| of a single Hann-windowed segment,
% fftshifted to -fs/2..+fs/2 (= full RF band), max-hold decimated to ~4000
% display points. Y values are dB relative to each channel's own median noise
% floor (middle 80% of band), so 0 dB = noise level and peaks are above 0.
    N  = min(npts, min(numel(ch0), numel(ch1)));
    w  = hann_win(N);
    A0 = fftshift(abs(fft(ch0(1:N) .* w)));
    A1 = fftshift(abs(fft(ch1(1:N) .* w)));
    f  = (-N/2 : N/2-1)' * (fs / N);   % baseband Hz, -fs/2..+fs/2
    % Max-hold decimation to ~4000 display points — narrow peaks survive.
    dec = max(1, floor(N / 4000));
    m   = floor(N / dec);
    A0  = max(reshape(A0(1:dec*m), dec, m), [], 1)';
    A1  = max(reshape(A1(1:dec*m), dec, m), [], 1)';
    f   = f(ceil(dec/2) : dec : dec*m);
    A0  = 20*log10(A0);
    A1  = 20*log10(A1);
end

function [img, t_ms, f_mhz] = spectro(x, fs, f0, seg_len, n_cols)
% STFT magnitude-squared, time-averaged down to ~n_cols columns so the
% image stays renderable while still catching short RFI bursts (every
% segment contributes to its column's average — bursts aren't skipped).
    n_segs = floor(numel(x) / seg_len);
    X = abs(fft(reshape(x(1:n_segs*seg_len), seg_len, n_segs) .* hann_win(seg_len))).^2;
    g = max(1, floor(n_segs / n_cols));            % segments per column
    m = floor(n_segs / g);
    img = squeeze(mean(reshape(X(:, 1:g*m), seg_len, g, m), 2));
    img = fftshift(img, 1);
    t_ms  = ((0:m-1)' + 0.5) * g * seg_len / fs * 1e3;
    f_mhz = ((-seg_len/2 : seg_len/2 - 1)' * (fs / seg_len) + f0) / 1e6;
end

function [img, t_ms, f_mhz] = spectro_filtered(x, fs, f0, seg_len, n_cols, method, excis, applyfun)
% spectro with the RFI-excision operator applied to EACH STFT frame's spectrum
% before |.|^2 — the same per-segment frequency-domain excision compute_L1
% performs. method is an rfi_excise method name; excis =
% rfi_excise().prepare(cfg, seg_len); applyfun = rfi_excise().apply. method
% 'none' returns each frame unchanged, so this reduces to spectro exactly.
    n_segs = floor(numel(x) / seg_len);
    F = fft(reshape(x(1:n_segs*seg_len), seg_len, n_segs) .* hann_win(seg_len));
    for c = 1:n_segs
        F(:, c) = applyfun(F(:, c), method, excis);
    end
    X = abs(F).^2;
    g = max(1, floor(n_segs / n_cols));            % segments per column
    m = floor(n_segs / g);
    img = squeeze(mean(reshape(X(:, 1:g*m), seg_len, g, m), 2));
    img = fftshift(img, 1);
    t_ms  = ((0:m-1)' + 0.5) * g * seg_len / fs * 1e3;
    f_mhz = ((-seg_len/2 : seg_len/2 - 1)' * (fs / seg_len) + f0) / 1e6;
end

function D = xcorr_profile(ch0, ch1, npts, num_segs, lag_half_win)
% Same windowed, segment-averaged cross-correlation as compute_L1,
% trimmed to the L1 analysis window (±lag_half_win around lag 0).
% npts, num_segs, and lag_half_win are explicit inputs.
    win = hann_win(npts);
    n_segs = min(floor(numel(ch0) / npts), num_segs);
    R_sum = zeros(npts, 1);
    for seg = 1:n_segs
        i1 = (seg-1)*npts + 1;  i2 = seg*npts;
        F0 = fft(ch0(i1:i2) .* win);
        F1 = fft(ch1(i1:i2) .* win);
        R_sum = R_sum + fftshift(ifft(F0 .* conj(F1))) / npts;
    end
    center = npts/2 + 1;
    idx = (center - lag_half_win):(center + lag_half_win);
    D.R   = R_sum(idx) / n_segs;
    D.lag = (idx - center)';
end

function D = xcorr_profile_filtered(ch0, ch1, npts, num_segs, lag_half_win, method, excis, applyfun)
% xcorr_profile with the RFI-excision operator applied to each segment's
% per-channel spectra (F0, F1) BEFORE the cross-spectrum — exactly the
% phase-safe excision compute_L1 performs (the SAME real operator on both
% channels, so no differential phase). method 'none' returns F0/F1 unchanged,
% reducing this to xcorr_profile exactly. excis = rfi_excise().prepare(cfg,
% npts); applyfun = rfi_excise().apply.
    win = hann_win(npts);
    n_segs = min(floor(numel(ch0) / npts), num_segs);
    R_sum = zeros(npts, 1);
    for seg = 1:n_segs
        i1 = (seg-1)*npts + 1;  i2 = seg*npts;
        F0 = applyfun(fft(ch0(i1:i2) .* win), method, excis);
        F1 = applyfun(fft(ch1(i1:i2) .* win), method, excis);
        R_sum = R_sum + fftshift(ifft(F0 .* conj(F1))) / npts;
    end
    center = npts/2 + 1;
    idx = (center - lag_half_win):(center + lag_half_win);
    D.R   = R_sum(idx) / n_segs;
    D.lag = (idx - center)';
end


% =========================================================================
% Data IO / parsing
% =========================================================================

function ch = read_channel(filepath, n_want)
% Read up to n_want complex samples from a single-channel sc16 file.
% [I0, Q0, I1, Q1, ...] int16 -> complex double column.
% .' (not ') on the int16 rows — ' would conjugate complex data.
    fid = fopen(filepath, 'rb');
    raw = fread(fid, [2, n_want], '*int16');
    fclose(fid);
    ch = double(raw(1,:)).' + 1j * double(raw(2,:)).';
end

function T = read_product(csv_path)
% Read a product CSV; returns an empty table if absent. The timestamp column is
% normalized to datetime, accepting ISO 'yyyy-MM-dd HH:mm:ss' and MATLAB's
% default 'dd-MMM-yyyy HH:mm:ss' display format. The
% timestamp is forced to TEXT on read: readtable's datetime auto-detect locks
% onto ONE format and silently NaTs the minority rows (dropping them from every
% plot), so we control the parse ourselves.
    T = table();
    if ~isfile(csv_path), return; end
    opts = detectImportOptions(csv_path, 'TextType', 'string');
    if ismember('timestamp', opts.VariableNames)
        opts = setvartype(opts, 'timestamp', 'string');
    end
    T = readtable(csv_path, opts);
    if ismember('timestamp', T.Properties.VariableNames)
        T.timestamp = parse_mixed_datetime(T.timestamp);
        T = sortrows(T, 'timestamp');
    end
end

function dt = parse_mixed_datetime(s)
% Parse a timestamp column that may mix ISO 'yyyy-MM-dd HH:mm:ss' and MATLAB's
% default 'dd-MMM-yyyy HH:mm:ss' display format within one file. datetime() with
% an explicit InputFormat ERRORS on a non-matching string (it does not return
% NaT), so each row is classified by its format first and parsed with its own
% format. Unmatched/blank rows stay NaT (Locale pinned to en_US so the month
% abbreviations Jan..Dec always match regardless of the system locale).
    s  = string(s);
    dt = NaT(size(s));
    dt.Format = 'yyyy-MM-dd HH:mm:ss';

    isIso = ~cellfun('isempty', regexp(s, '^\s*\d{4}-\d{2}-\d{2}',      'once'));
    isDmy = ~cellfun('isempty', regexp(s, '^\s*\d{1,2}-[A-Za-z]{3}-\d{4}', 'once'));

    if any(isIso)
        dt(isIso) = datetime(s(isIso), 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
    end
    if any(isDmy)
        dt(isDmy) = datetime(s(isDmy), 'InputFormat', 'dd-MMM-yyyy HH:mm:ss', ...
                             'Locale', 'en_US');
    end
end

function ts = base_ts(bases)
% Datetime from base names containing 14-digit YYYYMMDDHHMMSS.
    ts = NaT(numel(bases), 1);
    for i = 1:numel(bases)
        m = regexp(bases(i), '\d{14}', 'match', 'once');
        if strlength(m) == 14
            ts(i) = datetime(m, 'InputFormat', 'yyyyMMddHHmmss');
        end
    end
end

function WX = load_snodar(cfg)
% Load and clean the Brundage weather station SNOdar data from a Campbell TOA5 file.
% Returns a table with columns {timestamp (datetime), depth_m, airtc_c, temp_c,
% swe_mm, dtc_c, soil_vwc}. dtc_c is rows by sensors in configured cable order,
% deg C; soil_vwc is rows by rod positions in configured order, m^3/m^3.
% The two temperature columns (cfg.wx_temp_cols, default AirTC_Avg / Temp_C_Avg)
% feed the viewer's toggleable SNOdar-overlay temperature lines — or, with the
% viewer's AboveFreezing box, its orange above-freezing (wet-snow) band layer.
% swe_mm is the snow-scale SWE (cfg.wx_swe_cols, default SS_SWE_Avg masked by
% SS_SWE_ErrCode_Avg; mm water column) feeding the viewer's SWE overlay line —
% error-code-masked (fail closed), spike-filtered. Depth reads cfg.wx_depth_cols
% {distance, snow_depth} (defaults SnoDAR_distance_Avg / SnoDAR_snow_depth_Avg);
% soil_vwc reads cfg.wx_soil_vwc_cols (see soil_column_names). Every sensor is
% optional and independent: a missing header NaN-fills only its own column, so
% one absent sensor never blocks the rest of the file from loading. The
% cfg.wx_*_cols overrides are set per site in BrundageSoOp.m's weather block.
%
% Timestamp timebase: when cfg.wx_tz is set (the logger's clock zone — Campbell
% loggers run FIXED standard time year-round, no DST), timestamps are converted
% into the capture timebase (cfg.capture_tz if set, else UTC) so the viewer
% overlay aligns with the capture timestamp column. When cfg.wx_tz is absent,
% timestamps pass through as recorded by the logger.
%
% Uses SnoDAR_snow_depth_Avg directly. The device applies its own per-season
% calibrated reference height (~2.81 m WY2024, ~3.79 m WY2026); a fixed
% distance-based formula causes season-dependent offsets up to ~1 m.
%
% Calibration drift flag: rows with distance + snow_depth above 4.2 m are NaN.
% This is above the highest calibrated seasonal reference (~3.79 m) and below
% the observed drift/configuration state (~5.016 m).
%
% Spike/dip filter: 97-point sliding median (24-hour window at 15-min sampling)
% removes near-zero dips and spikes from people or maintenance under the sensor.
    WX = table();
    if ~isfield(cfg, 'wx_dat') || isempty(cfg.wx_dat) || ~isfile(cfg.wx_dat)
        return;
    end
    try
        drift_thr = 4.2;    % m — distance + snow_depth above this = drift/config anomaly
        spike_thr = 0.5;    % m — deviation from 97-pt median to flag as spike/dip
        swe_spike_thr   = 100;  % mm w.c. — SWE deviation from 97-pt median to flag as a
                                % transient (p99 sample-to-sample noise is 2.1 mm; rejects
                                % ~110 mm dip-and-recover artifacts but keeps persistent
                                % steps of at least ~175 mm)
        swe_min_support = 13;   % min finite samples in the 97-pt window (~3 h at 15 min)
                                % — sparser support can make an isolated bad value its
                                % own median, so such samples are masked instead

        fid = fopen(cfg.wx_dat, 'r', 'n', 'UTF-8');
        fgetl(fid);                          % TOA5 station info (skip)
        hdr = strtrim(string(strsplit(string(fgetl(fid)), ',')));
        fgetl(fid);                          % units (skip)
        fgetl(fid);                          % processing types (skip)
        % Snow-depth columns {distance, snow_depth} — optional, like every other
        % sensor here: a missing header NaN-fills depth_m and warns rather than
        % dropping the whole table, so the remaining sensors still reach the
        % viewer. distance feeds only the drift flag, so losing it costs that QC
        % check but not the depth series. cfg.wx_depth_cols overrides the two
        % header names per site.
        depth_cols = {'SnoDAR_distance_Avg', 'SnoDAR_snow_depth_Avg'};
        if isfield(cfg, 'wx_depth_cols') && numel(cfg.wx_depth_cols) >= 2
            depth_cols = cfg.wx_depth_cols(1:2);
        end
        dist_col  = find(hdr == string(depth_cols{1}), 1);
        depth_col = find(hdr == string(depth_cols{2}), 1);

        % Temperature columns for the viewer overlay (no drift/spike filter —
        % those are depth-specific). cfg.wx_temp_cols overrides the two header
        % names in order (airtc_c, temp_c); defaults to air temp + Temp_C_Avg.
        % Per-entry blank fallback — the same contract wx_temp_labels uses
        % for the checkbox/legend text, so the label always names the
        % column actually loaded here.
        temp_cols = {'AirTC_Avg', 'Temp_C_Avg'};
        if isfield(cfg, 'wx_temp_cols') && numel(cfg.wx_temp_cols) >= 2
            tcc = cellstr(cfg.wx_temp_cols);
            for tk = 1:2
                if ~isempty(strtrim(tcc{tk})), temp_cols{tk} = strtrim(tcc{tk}); end
            end
        end
        airtc_col = find(hdr == string(temp_cols{1}), 1);
        tempc_col = find(hdr == string(temp_cols{2}), 1);

        % Snow-scale SWE columns (value, error code) for the viewer overlay —
        % optional sensor. cfg.wx_swe_cols overrides the two header names in
        % order {value, errcode}. Value column absent -> swe_mm all-NaN,
        % silently; value present without its errcode column -> values kept
        % unmasked, with one warning that error-code QC is unavailable.
        swe_cols = {'SS_SWE_Avg', 'SS_SWE_ErrCode_Avg'};
        if isfield(cfg, 'wx_swe_cols') && numel(cfg.wx_swe_cols) >= 2
            swe_cols = cfg.wx_swe_cols(1:2);
        end
        swe_col    = find(hdr == string(swe_cols{1}), 1);
        sweerr_col = find(hdr == string(swe_cols{2}), 1);

        % DTC headers are optional. Their configured order is physical cable
        % order — sensor 1 at cable top, last sensor at cable bottom. The
        % lowest sensors sit in the soil (negative heights above ground).
        dtc_names = dtc_column_names(cfg, hdr);
        dtc_col = zeros(1, numel(dtc_names));
        for dk = 1:numel(dtc_names)
            found = find(hdr == string(dtc_names{dk}), 1);
            if ~isempty(found), dtc_col(dk) = found; end
        end

        % SoilVUE volumetric water content (m^3/m^3) for the viewer overlay —
        % optional sensor. cfg.wx_soil_rod_cm lists ROD POSITIONS in cm, which
        % is what the logger headers name; the probe's upper section sits above
        % ground, so rod position is not depth below ground. Column order
        % follows the configured rod order and is preserved end to end, so a
        % missing header keeps its slot as an all-NaN column.
        soil_names = soil_column_names(cfg);
        soil_col = zeros(1, numel(soil_names));
        for sk = 1:numel(soil_names)
            found = find(hdr == string(soil_names{sk}), 1);
            if ~isempty(found), soil_col(sk) = found; end
        end

        % Read all fields as strings — handles quoted timestamps, NAN, unquoted numbers.
        n_cols = numel(hdr);
        fmt    = repmat('%q ', 1, n_cols);
        C = textscan(fid, fmt, 'Delimiter', ',', 'CollectOutput', true);
        fclose(fid);
        data = C{1};   % n_rows × n_cols cell array of strings

        ts_raw = strtrim(data(:, 1));

        % Parse timestamps (may or may not be quoted in TOA5)
        ts = NaT(size(data, 1), 1);
        pv = ~cellfun(@isempty, ts_raw);
        if any(pv)
            ts(pv) = datetime(ts_raw(pv), 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
        end

        n_rows = size(data, 1);

        % Snow depth (m) and the raw sensor distance (m) that pairs with it for
        % the drift flag: parse if present, else NaN-fill + warn. An all-NaN
        % dist_num leaves every drift comparison false, so the depth series
        % passes through unflagged instead of being wiped.
        if ~isempty(depth_col)
            depth_num = str2double(strtrim(data(:, depth_col)));
        else
            depth_num = nan(n_rows, 1);
            warning('BrundageSoOp:snodar', 'Snow-depth column "%s" not found.', depth_cols{2});
        end
        if ~isempty(dist_col)
            dist_num = str2double(strtrim(data(:, dist_col)));
        else
            dist_num = nan(n_rows, 1);
            warning('BrundageSoOp:snodar', ...
                'Sensor-distance column "%s" not found — depth drift flag unavailable.', ...
                depth_cols{1});
        end

        % Temperatures (deg C): parse if the column is present, else NaN-fill + warn.
        if ~isempty(airtc_col)
            airtc_num = str2double(strtrim(data(:, airtc_col)));
        else
            airtc_num = nan(n_rows, 1);
            warning('BrundageSoOp:snodar', 'Temperature column "%s" not found.', temp_cols{1});
        end
        if ~isempty(tempc_col)
            tempc_num = str2double(strtrim(data(:, tempc_col)));
        else
            tempc_num = nan(n_rows, 1);
            warning('BrundageSoOp:snodar', 'Temperature column "%s" not found.', temp_cols{2});
        end

        % SWE (mm w.c.): parse + error-code mask (fail closed). With the
        % errcode column present, a value is valid ONLY where the errcode is
        % finite and exactly 0 — a nonzero 15-min average errcode means part
        % of the window errored (the sensor reads ~0 while erroring, which
        % would paint false drop-to-zero excursions), and an unknown (NaN)
        % error state is not trusted either.
        if isempty(swe_col)
            swe_num = nan(n_rows, 1);              % optional sensor — silent
        else
            swe_num = str2double(strtrim(data(:, swe_col)));
            swe_num(~isfinite(swe_num)) = NaN;     % normalize ±Inf before QC
            if isempty(sweerr_col)
                warning('BrundageSoOp:snodar', ...
                    'SWE column "%s" present without its error-code column "%s" — values kept unmasked.', ...
                    swe_cols{1}, swe_cols{2});
            else
                swe_err = str2double(strtrim(data(:, sweerr_col)));
                swe_num(~(isfinite(swe_err) & swe_err == 0)) = NaN;
            end
        end

        dtc_num = nan(n_rows, numel(dtc_names));
        for dk = 1:numel(dtc_names)
            if dtc_col(dk) ~= 0
                v = str2double(strtrim(data(:, dtc_col(dk))));
                v(~isfinite(v)) = NaN;
                dtc_num(:, dk) = v;
            end
        end

        % SoilVUE VWC (m^3/m^3): one column per configured rod position, in
        % configured order. A configured header the logger does not carry stays
        % all-NaN in its own slot so the remaining rods keep their positions.
        soil_vwc = nan(n_rows, numel(soil_names));
        for sk = 1:numel(soil_names)
            if soil_col(sk) ~= 0
                v = str2double(strtrim(data(:, soil_col(sk))));
                v(~isfinite(v)) = NaN;
                soil_vwc(:, sk) = v;
            end
        end

        % Calibration drift: flag rows where distance + snow_depth exceeds threshold.
        drift_mask = (dist_num + depth_num) > drift_thr;
        depth_num(drift_mask | ~isfinite(depth_num)) = NaN;

        % Drop rows with unparseable timestamps
        keep      = ~isnat(ts);
        ts        = ts(keep);
        depth_num = depth_num(keep);
        airtc_num = airtc_num(keep);
        tempc_num = tempc_num(keep);
        swe_num   = swe_num(keep);
        dtc_num   = dtc_num(keep, :);
        soil_vwc  = soil_vwc(keep, :);

        % Weather logger clock -> capture timebase (see header). Brundage logger
        % zone is 'Etc/GMT+7' — POSIX sign convention: Etc/GMT+7 IS UTC-7. An
        % invalid zone lands in the outer catch (empty WX + warning) with the
        % offending value named.
        if isfield(cfg, 'wx_tz') && ~isempty(cfg.wx_tz)
            if isfield(cfg, 'capture_tz') && ~isempty(cfg.capture_tz)
                target = cfg.capture_tz;
            else
                target = 'UTC';
            end
            try
                ts.TimeZone = cfg.wx_tz;   % declare the logger's clock zone
                ts.TimeZone = target;      % convert the instant
                ts.TimeZone = '';          % back to naive, in the capture timebase
            catch tzME
                error('BrundageSoOp:snodarTz', ...
                      'weather timezone conversion failed (wx_tz=''%s'', target=''%s''): %s', ...
                      string(cfg.wx_tz), string(target), tzME.message);
            end
        end

        % Spike/dip filter: 97-pt sliding median (24-hour window at 15-min sampling).
        % The wider window catches multi-reading near-zero dips that a short window
        % misses when the local median shifts toward the dip.
        ref = movmedian(depth_num, 97, 'omitnan');
        depth_num(abs(depth_num - ref) > spike_thr) = NaN;

        % SWE spike + support filter (same deviation idiom). The median tracks
        % monotone runs, so interior melt/accumulation staircases and lasting
        % steps survive; isolated blips are masked. At the record boundary the
        % window shrinks one-sided, so a steep ramp right at the ends CAN be
        % flagged (harmless in practice — season boundaries are flat). Samples
        % with < swe_min_support finite neighbors in the window are masked:
        % too little local support to QC against.
        swe_ref = movmedian(swe_num, 97, 'omitnan');
        swe_n   = movsum(isfinite(swe_num), 97);
        swe_num(abs(swe_num - swe_ref) > swe_spike_thr | ...
                (isfinite(swe_num) & swe_n < swe_min_support)) = NaN;

        WX = table(ts, depth_num, airtc_num, tempc_num, swe_num, dtc_num, soil_vwc, ...
            'VariableNames', {'timestamp', 'depth_m', 'airtc_c', 'temp_c', 'swe_mm', ...
                              'dtc_c', 'soil_vwc'});
        WX = sortrows(WX, 'timestamp');
    catch ME
        warning('BrundageSoOp:snodar', 'SNOdar load failed: %s', ME.message);
    end
end


function names = dtc_column_names(cfg, hdr)
% Resolve DTC headers from a printf-style pattern or an explicit ordered list.
% Pattern form expands from sensor 1 until a header is absent, so cables with
% different sensor counts are picked up without a per-site count setting.
    spec = 'DTC_Avg(%d)';
    if isfield(cfg, 'wx_dtc_cols') && ~isempty(cfg.wx_dtc_cols)
        spec = cfg.wx_dtc_cols;
    end
    if ~(ischar(spec) || (isstring(spec) && isscalar(spec)))
        names = cellstr(spec);
        return;
    end
    max_sensor = 200;   % guard against a pattern that matches everything
    names = {};
    for k = 1:max_sensor
        nm = sprintf(char(spec), k);
        if ~any(hdr == string(nm))
            break;
        end
        names{end+1} = nm; %#ok<AGROW>
    end
end


function names = soil_column_names(cfg)
% Resolve SoilVUE VWC headers from a printf-style pattern substituted with the
% configured ROD POSITIONS in cm (cfg.wx_soil_rod_cm — the numbers the logger
% headers carry, not depth below ground), or from an explicit ordered list.
% Every configured slot is returned in configured order and none is dropped, so
% a header the logger does not carry keeps its position as an all-NaN column
% instead of shifting its neighbours — unlike the DTC pattern, which expands
% sequentially until a header is missing. Returns empty when the sensor is not
% configured: rod geometry is site-specific and is never guessed.
%
% FAIL-CLOSED, like soil_geometry: a nonfinite rod, a pattern carrying no
% conversion spec, or two rods expanding to the same header all return empty
% rather than a partial list. Silently dropping a slot would shift the
% remaining columns out of step with cfg.wx_soil_rod_cm, which is what carries
% the depth labels — mislabelling every rod after the gap.
    names = {};
    if ~isfield(cfg, 'wx_soil_vwc_cols') || isempty(cfg.wx_soil_vwc_cols)
        return;
    end
    spec = cfg.wx_soil_vwc_cols;
    if ~(ischar(spec) || (isstring(spec) && isscalar(spec)))
        names = cellstr(spec);      % explicit ordered header list
        names = names(:)';
        if numel(unique(names)) ~= numel(names), names = {}; end
        return;
    end
    if ~isfield(cfg, 'wx_soil_rod_cm') || isempty(cfg.wx_soil_rod_cm) || ...
            ~isnumeric(cfg.wx_soil_rod_cm)
        return;                     % pattern with no rod positions to fill it
    end
    rods = cfg.wx_soil_rod_cm(:)';
    if ~isreal(rods) || ~all(isfinite(rods))
        return;
    end
    spec = char(spec);
    % A pattern with no conversion spec expands to the SAME header for every
    % rod, loading one physical column into differently labelled slots.
    if isempty(regexp(spec, '%[-+ #0-9.]*[diufg]', 'once'))
        return;
    end
    names = arrayfun(@(r) sprintf(spec, r), double(rods), 'UniformOutput', false);
    if numel(unique(names)) ~= numel(names), names = {}; end
end

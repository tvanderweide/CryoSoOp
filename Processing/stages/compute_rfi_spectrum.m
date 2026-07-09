function compute_rfi_spectrum(cfg)
% Season-aggregated RFI spectra + proposed excision bands (frequency-domain),
% one product set per dataset: Signal, NL (noise+load), and L (load-only).
%
% Persistent narrowband RFI at Brundage shows as spikes standing above the
% smoothed PSD envelope in essentially every capture. This tool aggregates
% across an even season-wide sample of each dataset's captures and reports,
% per FFT bin and per channel: mean PSD (dB); OCCUPANCY (PRIMARY) — fraction
% of captures whose PSD exceeds a per-capture movmedian baseline by
% cfg.rfi_excess_db (robust to the colored receiver response; matches the
% by-eye PSD-vs-envelope method); spectral kurtosis (CHECK, reported not
% gating) — SK = (M+1)/(M-1)*(M*S2/S1^2 - 1), thermal noise -> 1, RFI
% deviates, catches intermittent/buried RFI the mean hides; and ch0xch1
% coherence — |<X0 X1*>|^2 / (<|X0|^2><|X1|^2>), marks the coherent signal
% region to PROTECT.
%
% Candidate bands come from rfi_propose_bands (the shared band-finder): bins
% whose mean PSD exceeds the smoothed envelope by >= cfg.rfi_excess_db, UNION
% bins with spectral kurtosis >= cfg.rfi_sk_threshold (when cfg.rfi_use_sk),
% outside the protected region, merged into [f_lo,f_hi]. The SK gate applies
% to the Signal dataset only — NL/L band-finding is PSD-excess only (SK is
% still computed and written as a diagnostic). (Occupancy is computed and
% written to the CSV for offline inspection but is diagnostic-only — it does
% NOT gate the proposed bands.) The user confirms the bands from the figure
% before curating them into the per-dataset band CSV (the defensibility
% safeguard): rfi_bands.csv (Signal), rfi_bands_NL.csv, rfi_bands_L.csv.
%
% Not incremental — recomputes and overwrites on each run.
% Outputs (cfg.input_dir, the Static folder), per dataset with suffix
% '' / '_NL' / '_L': rfi_spectrum<sfx>.csv, rfi_spectrum<sfx>.png,
% rfi_bands_proposed<sfx>.csv. Season-wide and method-independent, so they
% live in Static alongside the curated band CSVs — not in a dated per-run
% cfg.out_dir.
%

    % --- Parameters (defaults; override via cfg) ---
    % Aggregation:
    ap.seg_len   = getdef(cfg, 'rfi_seg_len',      2^16);   % ~305 Hz bins at 20 MS/s
    ap.n_read    = getdef(cfg, 'rfi_read_samples', 16*ap.seg_len);
    ap.excess_db = getdef(cfg, 'rfi_excess_db',    6);      % per-capture occupancy excess (diag)
    ap.max_caps  = getdef(cfg, 'rfi_max_captures', 500);    % even season subsample
    ap.base_khz  = getdef(cfg, 'rfi_baseline_khz', 750);    % per-capture occupancy baseline width
    % Band-finder (shared with the viewer's interactive explorer; see rfi_propose_bands):
    bp.excess_db      = ap.excess_db;                           % PSD-excess-above-envelope (dB)
    bp.sk_threshold   = getdef(cfg, 'rfi_sk_threshold',   100); % also flag SK >= this
    bp.use_sk         = getdef(cfg, 'rfi_use_sk',         true);
    bp.env_khz        = getdef(cfg, 'rfi_env_khz',        1000);% envelope movmedian width
    bp.merge_khz      = getdef(cfg, 'rfi_merge_khz',      25);  % merge runs closer than this
    bp.edge_guard_hz  = getdef(cfg, 'rfi_edge_guard_khz', 150) * 1e3;
    bp.protect_hz     = getdef(cfg, 'rfi_protect_hz',     50e3);% +/- around DC (LO leak)
    bp.min_width_khz  = getdef(cfg, 'rfi_min_width_khz',  0.3); % drop narrower runs
    bp.band_pad_khz   = getdef(cfg, 'rfi_band_pad_khz',   1);   % widen each band for the notch
    bp.center_hz      = cfg.freq_hz;
    ap.fs = cfg.fs;  ap.freq_hz = cfg.freq_hz;
    ap.df = ap.fs / ap.seg_len;
    ap.out = cfg.input_dir;   % Static: season-wide products (not the dated out_dir)
    ap.data_dir = cfg.data_dir;

    % --- Datasets: Signal + the two calibration states ---
    % Filename patterns match the compute_L1/compute_calib discovery
    % ('UHF__NL_2*' does not match the 'UHF__NLs_*' small sets). NL/L
    % band-finding is PSD-excess only (use_sk = false); Signal keeps the
    % cfg-controlled SK gate. An empty dataset is skipped, not fatal.
    ds = struct( ...
        'name',   {'Signal',          'NL',                 'L'}, ...
        'pat',    {'UHF_2*_ch0.dat',  'UHF__NL_2*_ch0.dat', 'UHF__L_2*_ch0.dat'}, ...
        'sfx',    {'',                '_NL',                '_L'}, ...
        'use_sk', {bp.use_sk,         false,                false});
    for di = 1:numel(ds)
        bpd = bp;  bpd.use_sk = ds(di).use_sk;
        aggregate_dataset(ds(di), bpd, ap);
    end
end


% =========================================================================
function aggregate_dataset(ds, bp, ap)
% One dataset's season aggregation -> rfi_spectrum<sfx>.{csv,png} +
% rfi_bands_proposed<sfx>.csv. Identical math for all datasets; only the
% filename pattern, output suffix, and band-finder SK gate differ.

    % --- Discover + evenly subsample this dataset's season captures ---
    % '**' recurses into the cryosoop <YYYYMMDD>/<HHMMSS>/ per-run subfolders
    % while still matching a legacy flat directory (** matches zero levels);
    % one_capture builds each partner path from the hit's .folder.
    ch0_files = dir(fullfile(ap.data_dir, '**', ds.pat));
    if isempty(ch0_files)
        fprintf('[rfi:%s] No %s in %s — skipped.\n', ds.name, ds.pat, ap.data_dir);
        return;
    end
    M0    = BrundageSoOp_fun();
    bases = string(erase({ch0_files.name}', '_ch0.dat'));
    ts    = M0.base_ts(bases);
    [~, ord] = sort(ts);
    ch0_files = ch0_files(ord);  bases = bases(ord);
    nAll = numel(ch0_files);
    if nAll > ap.max_caps
        pick = round(linspace(1, nAll, ap.max_caps));
        ch0_files = ch0_files(pick);  bases = bases(pick);
    end
    nC = numel(ch0_files);
    fprintf('[rfi:%s] Aggregating %d of %d captures, seg_len=%d (%.0f Hz bins).\n', ...
            ds.name, nC, nAll, ap.seg_len, ap.df);

    % --- Accumulators (fftshifted bin order, length seg_len) ---
    L = ap.seg_len;
    w = M0.hann_win(L);  wpow = w' * w;
    A0 = zeros(L,1); A1 = zeros(L,1);   % sum |X|^2  (= S1 for SK; autospectra)
    Q0 = zeros(L,1); Q1 = zeros(L,1);   % sum |X|^4  (S2 for SK)
    X01 = complex(zeros(L,1));          % sum X0 .* conj(X1)  (coherence numerator)
    OCC0 = zeros(L,1); OCC1 = zeros(L,1);
    Mtot = 0; Ncap = 0;

    % --- Deterministic season aggregation -------------------------------------
    % A parfor reduction (A0 = A0 + a0) folds the workers' partial sums in
    % completion order, so the season spectra were bit-nondeterministic between
    % runs. Instead each capture writes its per-capture spectra into a disjoint
    % COLUMN of a per-chunk slice buffer (a sliced output — order-independent),
    % then a SERIAL, fixed-order reduction sums the chunk (sum(...,2)) and folds
    % chunks in ascending order — bit-reproducible for a given capture set.
    % Peak extra memory is bounded by one chunk buffer: chunk_sz*L doubles per
    % real stat (7) plus complex X01 (2x), e.g. seg_len=2^16 (nbins) and
    % chunk_sz=64 is ~0.3 GB — vs ~2.3 GB to hold all rfi_max_captures (500)
    % captures at once. (Holding the full nbins*captures slice for every stat is
    % the memory bound noted in the task; the chunking keeps peak use modest.)
    files = ch0_files;  bnames = bases;
    n_read = ap.n_read;  excess_db = bp.excess_db;  base_khz = ap.base_khz;  df = ap.df;
    chunk_sz = min(nC, 64);
    for c0 = 1:chunk_sz:nC
        cidx = c0:min(c0 + chunk_sz - 1, nC);
        mC   = numel(cidx);
        a0c = zeros(L, mC); a1c = zeros(L, mC);
        q0c = zeros(L, mC); q1c = zeros(L, mC);
        x01c = complex(zeros(L, mC));
        o0c = zeros(L, mC); o1c = zeros(L, mC);
        msc = zeros(1, mC);
        parfor j = 1:mC
            k = cidx(j);
            [a0,a1,q0,q1,x01,o0,o1,ms] = one_capture( ...
                files(k), bnames(k), n_read, L, w, excess_db, base_khz, df); %#ok<PFBNS>
            a0c(:,j) = a0;  a1c(:,j) = a1;
            q0c(:,j) = q0;  q1c(:,j) = q1;
            x01c(:,j) = x01;
            o0c(:,j) = o0;  o1c(:,j) = o1;
            msc(j)   = ms;
        end
        % Serial, fixed-order fold (deterministic given the sliced per-capture data).
        A0 = A0 + sum(a0c,2);    A1 = A1 + sum(a1c,2);
        Q0 = Q0 + sum(q0c,2);    Q1 = Q1 + sum(q1c,2);
        X01 = X01 + sum(x01c,2);
        OCC0 = OCC0 + sum(o0c,2);  OCC1 = OCC1 + sum(o1c,2);
        Mtot = Mtot + sum(msc);    Ncap = Ncap + sum(msc > 0);
    end
    if Ncap == 0 || Mtot < 3
        fprintf('[rfi:%s] No usable captures/segments — skipped.\n', ds.name);
        return;
    end
    fprintf('[rfi:%s] Aggregated %d capture(s), %d segment(s).\n', ds.name, Ncap, Mtot);

    % --- Derived spectra (fftshifted; RF frequency axis) ---
    f_bb   = ((-L/2):(L/2-1))' * df;
    f_rf   = f_bb + ap.freq_hz;
    psd0_db = 10*log10( (A0/Mtot) / (ap.fs*wpow) );
    psd1_db = 10*log10( (A1/Mtot) / (ap.fs*wpow) );
    sk0 = (Mtot+1)/(Mtot-1) * (Mtot*Q0./A0.^2 - 1);
    sk1 = (Mtot+1)/(Mtot-1) * (Mtot*Q1./A1.^2 - 1);
    coh = abs(X01).^2 ./ max(A0.*A1, eps);
    occ0 = OCC0 / Ncap;  occ1 = OCC1 / Ncap;         % occupancy (diagnostic only)

    % --- Propose bands via the shared finder (PSD-excess + SK union) ---
    [bands_rf, band_src, band_chan] = rfi_propose_bands(f_rf, psd0_db, psd1_db, sk0, sk1, bp);

    % --- Write CSV products ---
    if ~isfolder(ap.out), mkdir(ap.out); end
    T = table(f_rf, psd0_db, psd1_db, occ0, occ1, sk0, sk1, coh, ...
        'VariableNames', {'freq_hz','psd_db_ch0','psd_db_ch1', ...
                          'occupancy_ch0','occupancy_ch1','sk_ch0','sk_ch1','coherence'});
    writetable(T, fullfile(ap.out, ['rfi_spectrum' ds.sfx '.csv']));

    if isempty(bands_rf)
        fprintf('[rfi:%s] No bands proposed at the current thresholds.\n', ds.name);
        Bt = table('Size',[0 4],'VariableTypes',{'double','double','string','string'}, ...
                   'VariableNames',{'f_lo_hz','f_hi_hz','source','channel'});
    else
        Bt = table(bands_rf(:,1), bands_rf(:,2), band_src, band_chan, ...
                   'VariableNames',{'f_lo_hz','f_hi_hz','source','channel'});
        if bp.use_sk
            gate = sprintf('PSD-excess >= %g dB OR SK >= %g', bp.excess_db, bp.sk_threshold);
        else
            gate = sprintf('PSD-excess >= %g dB, no SK', bp.excess_db);
        end
        fprintf('[rfi:%s] %d candidate band(s) (%s):\n', ds.name, size(bands_rf,1), gate);
        for i = 1:size(bands_rf,1)
            fprintf('      %8.4f - %8.4f MHz  (%.1f kHz, %s, %s)\n', ...
                    bands_rf(i,1)/1e6, bands_rf(i,2)/1e6, diff(bands_rf(i,:))/1e3, ...
                    band_src(i), band_chan(i));
        end
    end
    writetable(Bt, fullfile(ap.out, ['rfi_bands_proposed' ds.sfx '.csv']));

    % --- Figure: PSD+envelope+bands, SK ---
    % Bands are shaded by source (psd / sk / both), matching the viewer explorer.
    % Occupancy/coherence are computed and written to rfi_spectrum<sfx>.csv (still
    % available for offline inspection) but are diagnostic-only — not consumed
    % by rfi_propose_bands — so they're left off this figure.
    ew = round(bp.env_khz*1e3/df);  ew = max(3, ew + (1-mod(ew,2)));
    env0 = movmedian(psd0_db, ew);  env1 = movmedian(psd1_db, ew);
    f_mhz = f_rf / 1e6;
    fig = figure('Visible','off','Position',[60 60 1150 650]);
    tl  = tiledlayout(fig, 2, 1, 'TileSpacing','compact');

    ax1 = nexttile(tl); hold(ax1,'on'); grid(ax1,'on');
    h0 = plot(ax1, f_mhz, psd0_db, 'b'); h1 = plot(ax1, f_mhz, psd1_db, 'r');
    plot(ax1, f_mhz, env0, 'b--'); plot(ax1, f_mhz, env1, 'r--');
    ylabel(ax1,'Mean PSD (dB)'); title(ax1, sprintf( ...
        'Season RFI spectrum (%s) — %d captures, %d segments (shaded = proposed bands)', ...
        ds.name, Ncap, Mtot));
    H = shade_src(ax1, bands_rf/1e6, band_src);
    legend([H h0 h1], {'psd','sk','both','ch0','ch1'}, 'Location','best');

    ax2 = nexttile(tl); hold(ax2,'on'); grid(ax2,'on');
    s0h = plot(ax2, f_mhz, sk0, 'b'); s1h = plot(ax2, f_mhz, sk1, 'r');
    yline(ax2, 1, 'k-');
    if bp.use_sk, yline(ax2, bp.sk_threshold, 'k--'); end
    ylabel(ax2,'Spectral kurtosis'); xlabel(ax2,'RF frequency (MHz)');
    shade_src(ax2, bands_rf/1e6, band_src);
    legend([s0h s1h], {'ch0','ch1'},'Location','best');
    linkaxes([ax1 ax2], 'x');

    saveas(fig, fullfile(ap.out, ['rfi_spectrum' ds.sfx '.png']));  close(fig);
    fprintf('[rfi:%s] Wrote rfi_spectrum%s.csv / .png / rfi_bands_proposed%s.csv to %s\n', ...
            ds.name, ds.sfx, ds.sfx, ap.out);
end


% =========================================================================
function [a0,a1,q0,q1,x01,o0,o1,ms] = one_capture(f_ch0, base, n_read, L, w, excess_db, base_khz, df)
% Per-capture spectral accumulation (fftshifted bin order). Returns zeros and
% ms=0 if the pair is missing/short so it contributes nothing to the season sums.
    a0=zeros(L,1); a1=zeros(L,1); q0=zeros(L,1); q1=zeros(L,1);
    x01=complex(zeros(L,1)); o0=zeros(L,1); o1=zeros(L,1); ms=0;

    p0 = fullfile(f_ch0.folder, f_ch0.name);
    p1 = fullfile(f_ch0.folder, base + "_ch1.dat");
    if ~isfile(p1), return; end
    M = BrundageSoOp_fun();
    ch0 = M.read_channel(p0, n_read);
    ch1 = M.read_channel(p1, n_read);
    n   = min(numel(ch0), numel(ch1));
    nseg = floor(n / L);
    if nseg < 1, return; end

    for s = 1:nseg
        i1 = (s-1)*L + 1;  i2 = s*L;
        X0 = fftshift(fft(ch0(i1:i2) .* w));
        X1 = fftshift(fft(ch1(i1:i2) .* w));
        p0s = abs(X0).^2;  p1s = abs(X1).^2;
        a0 = a0 + p0s;     a1 = a1 + p1s;
        q0 = q0 + p0s.^2;  q1 = q1 + p1s.^2;
        x01 = x01 + X0 .* conj(X1);
    end
    ms = nseg;

    % Per-capture occupancy: this capture's mean PSD vs its movmedian baseline.
    base_bins = max(3, round(base_khz*1e3 / df));
    d0 = 10*log10(a0/nseg) - movmedian(10*log10(a0/nseg), base_bins, 'omitnan');
    d1 = 10*log10(a1/nseg) - movmedian(10*log10(a1/nseg), base_bins, 'omitnan');
    o0 = double(d0 >= excess_db);
    o1 = double(d1 >= excess_db);
end


% =========================================================================
function H = shade_src(ax, bands_mhz, src)
% Shade each proposed band colored by source (psd=orange, sk=purple,
% both=red), drawn AFTER the traces at the axis's current y-limits so it never
% distorts autoscaling, HandleVisibility off. Returns 3 NaN-patch proxies
% [psd sk both] for the legend. patch() (not xregion) for r2023b.
    cols = struct('psd',[1 0.7 0.3], 'sk',[0.6 0.4 0.8], 'both',[0.9 0.4 0.4]);
    yl = ylim(ax);
    for i = 1:size(bands_mhz,1)
        c = cols.(char(src(i)));
        patch(ax, [bands_mhz(i,1) bands_mhz(i,2) bands_mhz(i,2) bands_mhz(i,1)], ...
              [yl(1) yl(1) yl(2) yl(2)], c, ...
              'EdgeColor','none', 'FaceAlpha',0.45, 'HandleVisibility','off');
    end
    ylim(ax, yl);
    H = [patch(ax, NaN(1,4), NaN(1,4), cols.psd,  'EdgeColor','none'), ...
         patch(ax, NaN(1,4), NaN(1,4), cols.sk,   'EdgeColor','none'), ...
         patch(ax, NaN(1,4), NaN(1,4), cols.both, 'EdgeColor','none')];
end


% =========================================================================
function v = getdef(s, name, default)
    if isfield(s, name) && ~isempty(s.(name)), v = s.(name); else, v = default; end
end

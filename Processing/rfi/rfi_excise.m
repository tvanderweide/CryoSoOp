function F = rfi_excise()
% Frequency-domain RFI excision helpers for the Brundage SoOp L1 pipeline.
%
% Returns a struct of function handles (same idiom as BrundageSoOp_fun):
%   E = rfi_excise();  P = E.prepare(cfg, npts);  Fm = E.apply(F, method, P);
%
% The L1 observable is the ch0xch1 cross-correlation phase
%   R_xy = fftshift(ifft(F0 .* conj(F1))) / npts.
% Every excision here is a REAL, per-bin operation applied IDENTICALLY to F0
% and F1, so the cross-spectrum becomes (real weight) .* F0.*conj(F1): the
% phase at unaffected bins is untouched and removed/attenuated bins inject NO
% differential phase. This is the correctness guarantee (see rfi_excise_test).
%
% Two methods (selected per call so a single FFT feeds both of them):
%   'none'         - pass-through (exact baseline).
%   'notch_interp' - linear-interpolate the complex spectrum across each
%                    flagged band's edge bins (sharp; out-of-band untouched).
%
% Bands are given in RF Hz (cfg.rfi_bands, as read off the PSD x-axis) and
% mapped to UNSHIFTED FFT bins internally (compute_L1 forms F=fft(x) with no
% shift; the fftshift is applied later, to R_xy).
%
% References: Fridman & Baan (2001), A&A 378:327 (frequency-domain RFI
% excision).

    F.prepare        = @prepare;
    F.apply          = @apply;
    F.band_mask      = @band_mask;
    F.notch_interp   = @notch_interp;
    F.method_out_dir = @method_out_dir;
    F.bin_freqs_rf   = @bin_freqs_rf;
end


% =========================================================================
function P = prepare(cfg, npts)
% Precompute the per-bin operators once for a given FFT length so workers
% reuse them. cfg supplies fs, freq_hz, rfi_bands (RF Hz), rfi_methods.
% mask is built only if a notch method is requested.
    methods = cellstr(cfg.rfi_methods);
    bands   = cfg.rfi_bands;

    P.methods = methods;
    P.bands   = bands;
    P.npts    = npts;
    P.mask    = [];

    if isempty(bands)
        if any(~strcmp(methods, 'none'))
            warning('rfi_excise:noBands', ...
                ['rfi_methods requests excision but cfg.rfi_bands is empty — ' ...
                 'those methods will behave like ''none''.']);
        end
        return;
    end

    if any(strcmp(methods, 'notch_interp'))
        P.mask = band_mask(bands, cfg.freq_hz, cfg.fs, npts);
    end
end


% =========================================================================
function Fout = apply(Fin, method, P)
% Apply one excision method to a single-channel spectrum Fin (npts x 1,
% unshifted fft order). Call once per channel with the SAME P so F0 and F1
% receive an identical real weighting (phase-safe).
    switch char(method)
        case 'none'
            Fout = Fin;
        case 'notch_interp'
            if isempty(P.mask) || isempty(P.bands)
                Fout = Fin;
            else
                Fout = notch_interp(Fin, P.mask);
            end
        otherwise
            error('rfi_excise:badMethod', 'Unknown rfi method "%s".', char(method));
    end
end


% =========================================================================
function f_rf = bin_freqs_rf(freq_hz, fs, npts)
% RF frequency (Hz) of each UNSHIFTED fft bin: bins 0..npts/2-1 are positive
% baseband, npts/2..npts-1 are negative baseband (k-npts), plus the center.
    k    = (0:npts-1)';
    f_bb = k * (fs / npts);
    f_bb(k >= npts/2) = f_bb(k >= npts/2) - fs;   % wrap upper half to negatives
    f_rf = f_bb + freq_hz;
end


% =========================================================================
function mask = band_mask(bands_rf, freq_hz, fs, npts)
% Logical npts x 1 mask: true where the bin's RF frequency falls inside any
% [f_lo, f_hi] band (order within a row is irrelevant).
    mask = false(npts, 1);
    if isempty(bands_rf), return; end
    f_rf = bin_freqs_rf(freq_hz, fs, npts);
    for i = 1:size(bands_rf, 1)
        lo = min(bands_rf(i, 1), bands_rf(i, 2));
        hi = max(bands_rf(i, 1), bands_rf(i, 2));
        mask = mask | (f_rf >= lo & f_rf <= hi);
    end
end


% =========================================================================
function F = notch_interp(F, mask)
% Linearly interpolate the complex spectrum across each contiguous masked run,
% using the nearest unmasked bin on either side (replaces RFI bins with a
% smooth estimate; cheaper and lower-ringing than hard-zeroing). Operates only
% on masked samples, so cost scales with total flagged bandwidth, not npts.
    if ~any(mask), return; end
    n      = numel(F);
    d      = diff([false; mask(:); false]);
    starts = find(d == 1);        % first masked index of each run
    ends   = find(d == -1) - 1;   % last  masked index of each run
    for r = 1:numel(starts)
        a = starts(r);  b = ends(r);
        lo = a - 1;  hi = b + 1;
        if lo < 1 && hi > n
            F(a:b) = 0;                       % whole spectrum masked
        elseif lo < 1
            F(a:b) = F(hi);                   % run at the start: flat-fill
        elseif hi > n
            F(a:b) = F(lo);                   % run at the end: flat-fill
        else
            w = ((a:b).' - lo) / (hi - lo);   % 0..1 across the gap
            F(a:b) = (1 - w) * F(lo) + w * F(hi);
        end
    end
end


% =========================================================================
function d = method_out_dir(base, method)
% Output directory for a method: 'none' -> base,
% 'notch_interp' -> <base>_notch. Keeps each method's products self-contained
% so every downstream stage runs unchanged.
    b = char(base);
    while ~isempty(b) && (b(end) == '/' || b(end) == '\')
        b(end) = [];
    end
    switch char(method)
        case 'none',         suffix = '';
        case 'notch_interp', suffix = '_notch';
        otherwise, error('rfi_excise:badMethod', 'Unknown rfi method "%s".', char(method));
    end
    d = [b suffix filesep];
end

function [bands_hz, source, channel] = rfi_propose_bands(freq_hz, psd0_db, psd1_db, sk0, sk1, p)
% Propose RFI excision bands from the season RFI spectrum.
%
% Pure function of the per-bin season statistics + thresholds, shared by
% compute_rfi_spectrum (static products) and the viewer's interactive explorer
% (live re-highlight). Inputs are in ASCENDING (fftshifted) RF-frequency order.
%
% Gate = PSD-excess-above-envelope (either channel) UNION spectral kurtosis:
%   env  = movmedian(psd_db, env_bins)               % smoothed PSD envelope
%   flag = (psd0-env0 >= excess_db) | (psd1-env1 >= excess_db)   % stable carriers
%          | (use_sk & max(sk0,sk1) >= sk_threshold)             % bursty RFI
% Band edges (FFT-edge artifacts) and DC (LO leakage) are guarded out;
% contiguous flagged runs closer than merge_khz are joined; runs narrower than
% min_width_khz are dropped; each surviving band is padded by +/- band_pad_khz.
%
% Returns:
%   bands_hz : N x 2  [f_lo_hz f_hi_hz]
%   source   : N x 1  string, "both" | "psd" | "sk"  (which gate(s) flagged it)
%   channel  : N x 1  string, "both" | "ch0" | "ch1"  (which channel(s) flagged it).
%              "both" = each channel had >=1 flagged bin somewhere inside the merged
%              band span, NOT that both flagged the same bin. Excision still applies
%              to both channels regardless; this is attribution only.
%
% p (struct) fields: excess_db, sk_threshold, use_sk, env_khz, merge_khz,
%   edge_guard_hz, protect_hz, center_hz, min_width_khz, band_pad_khz.

    freq_hz  = freq_hz(:);
    psd0_db  = psd0_db(:);  psd1_db = psd1_db(:);
    sk0      = sk0(:);      sk1     = sk1(:);
    df       = freq_hz(2) - freq_hz(1);

    % Smoothed PSD envelope (odd movmedian window; shared cfg.rfi_env_khz width).
    w  = rfi_env_window(p.env_khz, df);
    env0 = movmedian(psd0_db, w);
    env1 = movmedian(psd1_db, w);

    % Per-channel gate flags, kept separate so each band can be attributed to the
    % channel(s) that triggered it. The merged flag preserves the previous union
    % semantics exactly: sk_flag = sk0_flag | sk1_flag == max(sk0,sk1) >= threshold.
    psd0_flag = (psd0_db - env0 >= p.excess_db);
    psd1_flag = (psd1_db - env1 >= p.excess_db);
    if p.use_sk
        sk0_flag = sk0 >= p.sk_threshold;
        sk1_flag = sk1 >= p.sk_threshold;
    else
        sk0_flag = false(size(freq_hz));
        sk1_flag = false(size(freq_hz));
    end
    psd_flag = psd0_flag | psd1_flag;
    sk_flag  = sk0_flag  | sk1_flag;
    flag     = psd_flag  | sk_flag;
    ch0_flag = psd0_flag | sk0_flag;
    ch1_flag = psd1_flag | sk1_flag;

    % Guards: band edges (FFT-edge artifacts) and DC / LO leakage. Apply to every
    % flag (merged + per-gate + per-channel) so protected bins never appear in any
    % source or channel attribution.
    guard = (freq_hz <= freq_hz(1)   + p.edge_guard_hz) ...
          | (freq_hz >= freq_hz(end) - p.edge_guard_hz) ...
          | (abs(freq_hz - p.center_hz) <= p.protect_hz);
    flag(guard)     = false;
    psd_flag(guard) = false;   sk_flag(guard)  = false;
    ch0_flag(guard) = false;   ch1_flag(guard) = false;

    merge_bins = max(1, round(p.merge_khz    * 1e3 / df));
    min_bins   = max(1, round(p.min_width_khz * 1e3 / df));
    [A, B] = runs_to_bands(flag, merge_bins, min_bins);

    n        = numel(A);
    bands_hz = zeros(n, 2);
    source   = strings(n, 1);
    channel  = strings(n, 1);
    pad      = p.band_pad_khz * 1e3;
    for i = 1:n
        bands_hz(i, :) = [freq_hz(A(i)) - pad, freq_hz(B(i)) + pad];
        has_psd = any(psd_flag(A(i):B(i)));
        has_sk  = any(sk_flag(A(i):B(i)));
        if      has_psd && has_sk, source(i) = "both";
        elseif  has_psd,           source(i) = "psd";
        else,                      source(i) = "sk";
        end
        has_ch0 = any(ch0_flag(A(i):B(i)));
        has_ch1 = any(ch1_flag(A(i):B(i)));
        if      has_ch0 && has_ch1, channel(i) = "both";
        elseif  has_ch0,            channel(i) = "ch0";
        else,                       channel(i) = "ch1";
        end
    end
end


% =========================================================================
function [A, B] = runs_to_bands(flag, merge_bins, min_bins)
% Contiguous true-runs in flag -> [A B] start/end bin indices. Runs separated
% by <= merge_bins are bridged; runs narrower than min_bins are dropped.
    A = [];  B = [];
    flag = flag(:);
    d = diff([false; flag; false]);
    a = find(d == 1);  b = find(d == -1) - 1;
    if isempty(a), return; end
    ka = a(1);  kb = b(1);
    for r = 2:numel(a)
        if a(r) - kb - 1 <= merge_bins
            kb = b(r);
        else
            A(end+1) = ka;  B(end+1) = kb; %#ok<AGROW>
            ka = a(r);  kb = b(r);
        end
    end
    A(end+1) = ka;  B(end+1) = kb; %#ok<AGROW>
    keep = (B - A + 1) >= min_bins;
    A = A(keep);  B = B(keep);
end

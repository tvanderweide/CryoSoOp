function tests = rfi_propose_bands_test
% Unit tests for rfi_propose_bands: gate (source) and channel attribution.
% Pure-function tests on synthetic spectra — no data files, no GUI.
% Run: matlab -batch "runtests('rfi_propose_bands_test')"
tests = functiontests(localfunctions);
end

% ----------------------------------------------------------- shared fixture ----
function [f, psd0, psd1, sk0, sk1, p] = base_inputs()
    % 1 kHz bins over 369-371 MHz (center 370 MHz). Flat floor + thermal SK; tests
    % inject isolated spikes. The movmedian envelope (median) is robust to the
    % isolated spikes, so a +10 dB spike clears excess_db = 6.
    df  = 1e3;
    f   = (369.0e6 : df : 371.0e6 - df)';   % 2000 bins
    n   = numel(f);
    psd0 = -100*ones(n,1);  psd1 = -100*ones(n,1);   % flat PSD floor (dB)
    sk0  =    1*ones(n,1);  sk1  =    1*ones(n,1);    % thermal SK -> 1
    p = struct('excess_db',6, 'sk_threshold',100, 'use_sk',true, ...
               'env_khz',1000, 'merge_khz',25, 'edge_guard_hz',0, ...
               'protect_hz',50e3, 'center_hz',370e6, ...
               'min_width_khz',0.3, 'band_pad_khz',1);
end

function k = bin_at(f, f0)
    [~, k] = min(abs(f - f0));
end

% ------------------------------------------------------------------- tests ----
function test_ch0_only_psd(tc)
    [f, psd0, psd1, sk0, sk1, p] = base_inputs();
    psd0(bin_at(f, 369.5e6)) = -90;                 % +10 dB spike, ch0 only
    [b, src, ch] = rfi_propose_bands(f, psd0, psd1, sk0, sk1, p);
    verifyEqual(tc, size(b,1), 1);
    verifyEqual(tc, src(1), "psd");
    verifyEqual(tc, ch(1),  "ch0");
end

function test_ch1_only_psd(tc)
    [f, psd0, psd1, sk0, sk1, p] = base_inputs();
    psd1(bin_at(f, 369.5e6)) = -90;                 % ch1 only
    [b, src, ch] = rfi_propose_bands(f, psd0, psd1, sk0, sk1, p);
    verifyEqual(tc, size(b,1), 1);
    verifyEqual(tc, src(1), "psd");
    verifyEqual(tc, ch(1),  "ch1");
end

function test_sk_only_ch0(tc)
    [f, psd0, psd1, sk0, sk1, p] = base_inputs();
    sk0(bin_at(f, 369.5e6)) = 200;                  % SK spike, ch0 only
    [b, src, ch] = rfi_propose_bands(f, psd0, psd1, sk0, sk1, p);
    verifyEqual(tc, size(b,1), 1);
    verifyEqual(tc, src(1), "sk");
    verifyEqual(tc, ch(1),  "ch0");
end

function test_merged_ch0_ch1_both(tc)
    [f, psd0, psd1, sk0, sk1, p] = base_inputs();
    psd0(bin_at(f, 369.500e6)) = -90;               % ch0 spike
    psd1(bin_at(f, 369.510e6)) = -90;               % ch1 spike, 10 kHz away (< Gap 25)
    [b, src, ch] = rfi_propose_bands(f, psd0, psd1, sk0, sk1, p);
    verifyEqual(tc, size(b,1), 1);                  % merged into one band
    verifyEqual(tc, ch(1),  "both");
    verifyEqual(tc, src(1), "psd");
end

function test_guards_ignored(tc)
    [f, psd0, psd1, sk0, sk1, p] = base_inputs();
    p.edge_guard_hz = 5e3;                           % guard 5 kHz at each end
    psd0(1)                 = -90;                    % within edge guard (low)
    psd0(end)               = -90;                    % within edge guard (high)
    psd0(bin_at(f, 370.0e6)) = -90;                   % within DC protect (+/-50 kHz)
    [b, src, ch] = rfi_propose_bands(f, psd0, psd1, sk0, sk1, p);
    verifyEqual(tc, size(b,1), 0);                   % all spikes guarded out
    verifyEqual(tc, numel(src), 0);
    verifyEqual(tc, numel(ch),  0);
end

function test_empty_aligned(tc)
    [f, psd0, psd1, sk0, sk1, p] = base_inputs();    % flat: no spikes
    [b, src, ch] = rfi_propose_bands(f, psd0, psd1, sk0, sk1, p);
    verifyEqual(tc, size(b),   [0 2]);
    verifyEqual(tc, size(src), [0 1]);
    verifyEqual(tc, size(ch),  [0 1]);               % aligned empty outputs
end

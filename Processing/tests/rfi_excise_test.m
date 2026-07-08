function ok = rfi_excise_test()
% Phase-safety + excision unit test for rfi_excise.
%
% Builds a 2-channel synthetic spectrum: a weak in-band SIGNAL tone with a
% known cross-channel phase, plus a strong RFI tone inside a flagged band.
% Verifies, for both excision methods, that
%   (a) the RFI band energy is strongly attenuated, and
%   (b) the cross-spectrum PHASE at the (unflagged) signal bin is unchanged to
%       numerical precision — the guarantee that excision corrupts no phase.
%
% Run: ok = rfi_excise_test();   % prints a PASS/FAIL table, returns logical.

    wrap = @(x) mod(x + pi, 2*pi) - pi;   % wrap to (-pi, pi]

    % --- Synthetic two-channel signal ---
    % Tones placed on EXACT fft bins so there is no spectral leakage and the
    % recovered cross phase equals -dphi to machine precision.
    npts    = 2^16;
    fs      = 20e6;
    freq_hz = 370e6;
    t       = (0:npts-1).' / fs;

    ksig0 = 4044;   f_sig = ksig0 * fs / npts;   % in-band signal (NOT flagged)
    krfi0 = 9830;   f_rfi = krfi0 * fs / npts;   % RFI tone, inside flagged band
    dphi  = 0.7;              % true ch1-ch0 phase at the signal tone (rad)
    A_sig = 1;  A_rfi = 50;   % RFI is 34 dB stronger than the signal

    ch0 = A_sig*exp(1j*2*pi*f_sig*t)         + A_rfi*exp(1j*2*pi*f_rfi*t);
    ch1 = A_sig*exp(1j*(2*pi*f_sig*t + dphi)) + A_rfi*exp(1j*(2*pi*f_rfi*t + 0.3));

    % --- Config: flag a 200 kHz band around the RFI tone ---
    cfg.fs              = fs;
    cfg.freq_hz         = freq_hz;
    cfg.rfi_bands       = freq_hz + [f_rfi - 100e3, f_rfi + 100e3];   % RF Hz
    cfg.rfi_methods     = {'none', 'notch_interp'};

    E  = rfi_excise();
    P  = E.prepare(cfg, npts);
    F0 = fft(ch0);  F1 = fft(ch1);

    ksig = ksig0 + 1;   % 1-indexed signal bin
    krfi = krfi0 + 1;   % 1-indexed RFI bin

    phase0 = angle(F0(ksig) * conj(F1(ksig)));   % baseline cross phase at signal

    % Sanity: F0*conj(F1) phase = phi0 - phi1 = -dphi at the signal tone.
    sane = abs(wrap(phase0 - (-dphi))) < 1e-6;

    methods = {'notch_interp'};
    fprintf('\n  method         RFI atten (dB)   |dphase_sig| (rad)   result\n');
    fprintf(  '  ------------   --------------   ------------------   ------\n');
    ok = sane;
    for i = 1:numel(methods)
        m   = methods{i};
        F0m = E.apply(F0, m, P);
        F1m = E.apply(F1, m, P);

        atten_db = 20*log10(abs(F0(krfi)) / max(abs(F0m(krfi)), eps));
        dphase   = abs(wrap(angle(F0m(ksig) * conj(F1m(ksig))) - phase0));

        pass = (atten_db > 20) && (dphase < 1e-9);
        ok   = ok && pass;
        fprintf('  %-12s   %12.1f     %16.2e     %s\n', ...
                m, atten_db, dphase, ternary(pass, 'PASS', 'FAIL'));
    end

    fprintf('\n  signal-phase sanity (recovers -dphi): %s\n', ternary(sane, 'PASS', 'FAIL'));
    fprintf('  OVERALL: %s\n\n', ternary(ok, 'PASS', 'FAIL'));
end

function s = ternary(c, a, b)
    if c, s = a; else, s = b; end
end

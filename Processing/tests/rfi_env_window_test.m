function tests = rfi_env_window_test
% Unit tests for rfi_env_window: the shared "kHz -> odd movmedian window in
% bins" conversion used by every PSD envelope/baseline.
% Run: matlab -batch "soop_setup_paths; addpath('tests'); runtests('rfi_env_window_test')"
    tests = functiontests(localfunctions);
end

% Reference: the exact inline formula the helper replaced across the codebase.
function w = ref(env_khz, df)
    w = round(env_khz * 1e3 / df);
    w = max(3, w + (1 - mod(w, 2)));
end

function test_parity_native_bins(tc)
    % Native season FFT spacing (~305 Hz at seg_len=2^16, fs=20 MHz).
    df = 20e6 / 2^16;
    for env_khz = [50 100 250 500 750 1000 1500]
        verifyEqual(tc, rfi_env_window(env_khz, df), ref(env_khz, df), ...
            sprintf('native df, env_khz=%g', env_khz));
    end
end

function test_parity_display_bins(tc)
    % Decimated viewer display spacing (~5 kHz over the 20 MHz band, 4000 pts).
    df = 20e6 / 4000;
    for env_khz = [50 100 250 500 750 1000 1500]
        verifyEqual(tc, rfi_env_window(env_khz, df), ref(env_khz, df), ...
            sprintf('display df, env_khz=%g', env_khz));
    end
end

function test_window_is_odd(tc)
    % The window must always be odd (movmedian centering convention).
    df = 20e6 / 4000;
    for env_khz = [37 50 60 100 123 500 1000]
        w = rfi_env_window(env_khz, df);
        verifyEqual(tc, mod(w, 2), 1, sprintf('odd for env_khz=%g', env_khz));
    end
end

function test_even_rounds_up_to_odd(tc)
    % When round(env_khz*1e3/df) is EVEN, the helper adds 1 (never subtracts).
    % df = 1000 Hz, env_khz = 2 -> round(2000/1000)=2 (even) -> 3.
    verifyEqual(tc, rfi_env_window(2, 1000), 3);
    % df = 1000 Hz, env_khz = 4 -> round(4000/1000)=4 (even) -> 5.
    verifyEqual(tc, rfi_env_window(4, 1000), 5);
    % Odd stays put: env_khz = 3 -> round(3000/1000)=3 (odd) -> 3.
    verifyEqual(tc, rfi_env_window(3, 1000), 3);
end

function test_minimum_window_floor(tc)
    % Widths that round below 3 are floored at 3.
    verifyEqual(tc, rfi_env_window(1,    1000), 3);   % round(1)=1  -> 3
    verifyEqual(tc, rfi_env_window(0.1,  1000), 3);   % round(0.1)=0 -> 3
    verifyEqual(tc, rfi_env_window(1e-9, 1000), 3);   % ->0 -> 3
end

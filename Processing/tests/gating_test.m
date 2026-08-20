function tests = gating_test
% Unit tests for time-domain RFI gating: gating_mode_check validation,
% get_gating_masks mask geometry, and the BrundageSoOp.m gating enable guard.
% Run: matlab -batch "soop_setup_paths; addpath('tests'); runtests('gating_test')"
    tests = functiontests(localfunctions);
end

% fs and window_ms are chosen so round(fs*window_ms/1000) >= 1; the helper does
% not clamp the rolling window, so a lower fs would make movmean error.
function p = params()
    p.fs         = 1e5;   % Hz
    p.window_ms  = 0.5;   % ms -> 50-sample rolling window
    p.blank_ms   = 2.0;   % ms -> 200-sample guard band
    p.blank_samp = round(p.fs * p.blank_ms / 1000);
end

% Two constant-power halves: one internal loud/quiet transition.
function iq = one_transition_iq(n)
    iq = [ones(n/2, 1); 10*ones(n/2, 1)];
end

%% gating_mode_check

function test_mode_check_normalizes(tc)
    verifyEqual(tc, gating_mode_check('quiet'), 'quiet');
    verifyEqual(tc, gating_mode_check('Quiet'), 'quiet');
    verifyEqual(tc, gating_mode_check('loud'),  'loud');
    verifyEqual(tc, gating_mode_check("LOUD"),  'loud');   % string scalar
end

function test_mode_check_rejects(tc)
    % 'none' is not a mode: gating is switched off with "toggle": false.
    bad = {'none', 'off', '', 5, [], {'quiet'}, ["a" "b"]};
    for k = 1:numel(bad)
        verifyError(tc, @() gating_mode_check(bad{k}), 'BrundageSoOp:gatingMode', ...
            sprintf('bad input #%d must be rejected', k));
    end
end

%% get_gating_masks

function test_mask_orientation_column_and_row(tc)
    p = params();
    iq = one_transition_iq(20000);
    [qc, lc] = get_gating_masks(iq,   p.fs, p.window_ms, p.blank_ms);
    [qr, lr] = get_gating_masks(iq.', p.fs, p.window_ms, p.blank_ms);
    verifyEqual(tc, size(qc), size(iq),   'column input keeps column masks');
    verifyEqual(tc, size(qr), size(iq.'), 'row input keeps row masks');
    verifyEqual(tc, qr, qc.', 'row and column results agree');
    verifyEqual(tc, lr, lc.', 'row and column results agree');
end

function test_masks_are_disjoint(tc)
    p = params();
    for frac = [0.1 0.25 0.5 0.75]
        n = 20000;  nlow = round(frac * n);
        iq = [ones(nlow, 1); 10*ones(n - nlow, 1)];
        [q, l] = get_gating_masks(iq, p.fs, p.window_ms, p.blank_ms);
        verifyFalse(tc, any(q & l), sprintf('masks overlap at frac=%g', frac));
    end
end

function test_quiet_selects_low_power(tc)
    p = params();
    iq = one_transition_iq(20000);
    [q, l] = get_gating_masks(iq, p.fs, p.window_ms, p.blank_ms);
    verifyTrue(tc, any(q) && any(l), 'both masks must be non-empty here');
    verifyLessThan(tc, mean(abs(iq(q)).^2) * 10, mean(abs(iq(l)).^2));
end

function test_one_transition_blanks_four_bands(tc)
    % Guard bands apply at both capture ends AND both sides of the internal
    % transition, so one transition excludes 4*blank_samples in total.
    p = params();
    iq = one_transition_iq(20000);
    [q, l] = get_gating_masks(iq, p.fs, p.window_ms, p.blank_ms);
    verifyEqual(tc, sum(~q & ~l), 4 * p.blank_samp);
end

function test_no_transition_blanks_capture_edges(tc)
    % Constant power: no internal transition, but both capture ends are still
    % trimmed, so 2*blank_samples are excluded and everything else is quiet.
    p = params();
    iq = ones(20000, 1);
    [q, l] = get_gating_masks(iq, p.fs, p.window_ms, p.blank_ms);
    verifyEqual(tc, sum(~q & ~l), 2 * p.blank_samp);
    verifyEqual(tc, sum(q), numel(iq) - 2 * p.blank_samp);
    verifyFalse(tc, any(l), 'constant power yields no loud interval');
end

function test_mask_length_matches_input(tc)
    p = params();
    for n = [4001 20000 1]
        iq = ones(n, 1);
        [q, l] = get_gating_masks(iq, p.fs, p.window_ms, p.blank_ms);
        verifyEqual(tc, numel(q), n, sprintf('quiet mask length at n=%d', n));
        verifyEqual(tc, numel(l), n, sprintf('loud mask length at n=%d', n));
    end
end

%% BrundageSoOp.m gating enable guard

% Mirrors the predicate in BrundageSoOp.m. jsondecode maps JSON null to [],
% so the ~isempty term is what makes a null toggle read as "off".
function tf = gating_enabled(site)
    tf = isfield(site, 'gating') && ~isempty(site.gating) && ...
         isfield(site.gating, 'toggle') && isequal(site.gating.toggle, true);
end

function test_absent_or_off_gating_degrades(tc)
    verifyFalse(tc, gating_enabled(struct('site', struct())), 'no gating block');
    verifyFalse(tc, gating_enabled(struct('gating', [])),           'gating null');
    verifyFalse(tc, gating_enabled(struct('gating', struct())),     'no toggle field');
    verifyFalse(tc, gating_enabled(struct('gating', struct('toggle', false))), 'toggle false');
    verifyFalse(tc, gating_enabled(struct('gating', struct('toggle', []))),    'toggle null');
    verifyFalse(tc, gating_enabled(struct('gating', struct('toggle', 'true'))), 'toggle string');
    verifyTrue(tc,  gating_enabled(struct('gating', struct('toggle', true))),  'toggle true');
    verifyTrue(tc,  gating_enabled(struct('gating', struct('toggle', 1))),     'toggle JSON 1');
end

%% Shipped site configs

function test_shipped_configs_gating(tc)
    root = fileparts(which('soop_setup_paths'));
    for f = {'site_config.json', 'site_config_CSSL.json'}
        site = jsondecode(fileread(fullfile(root, f{1})));
        verifyTrue(tc, isfield(site, 'gating'), f{1});
        verifyEqual(tc, site.gating.toggle, false, [f{1} ' ships gating off']);
        verifyEqual(tc, gating_mode_check(site.gating.mode), 'quiet', f{1});
        verifyTrue(tc, isscalar(site.gating.window_ms) && isfinite(site.gating.window_ms) ...
                       && site.gating.window_ms > 0, [f{1} ' window_ms']);
        verifyTrue(tc, isscalar(site.gating.transition_ms) && isfinite(site.gating.transition_ms) ...
                       && site.gating.transition_ms > 0, [f{1} ' transition_ms']);
    end
end

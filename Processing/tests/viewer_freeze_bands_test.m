function tests = viewer_freeze_bands_test
% Tests for the L2: Candidates 'AboveFreezing' wet-snow bands: the pure
% freeze_spans helper (soop_viewer_util) plus the graphics assumptions the
% render relies on (xregion on yyaxis axes, mixed legend, MarkerSize
% mutation) exercised on an invisible figure.
% Run: matlab -batch "soop_setup_paths; addpath('tests'); runtests('viewer_freeze_bands_test')"
    tests = functiontests(localfunctions);
end


function setupOnce(tc)
    tc.TestData.U  = soop_viewer_util();
    tc.TestData.t0 = datetime(2026, 2, 1);
end

function t = mins(tc, m)
% Timestamps at the given minute offsets from the fixture day.
    t = tc.TestData.t0 + minutes(m(:));
end


% --------------------------------------------------------------- freeze_spans

function test_runs_and_padding(tc)
    % Contiguous > 0 runs, half-sample padded; separate runs stay separate.
    U = tc.TestData.U;
    t = mins(tc, 0:15:105);                    % 8 regular samples
    y = [-1; -1; 1; 1; 1; -1; 2; -1];
    sp = U.freeze_spans(t, y);
    verifyEqual(tc, sp, [t(3) - minutes(7.5), t(5) + minutes(7.5);
                         t(7) - minutes(7.5), t(7) + minutes(7.5)]);
end

function test_strict_threshold(tc)
    % Strictly > 0: a 0 degC sample is NOT above freezing; +eps is.
    U = tc.TestData.U;
    t = mins(tc, [0 15 30]);
    sp = U.freeze_spans(t, [0; eps; -eps]);
    verifyEqual(tc, sp, [t(2) - minutes(7.5), t(2) + minutes(7.5)]);
end

function test_invalid_sample_splits(tc)
    % A present-but-invalid sample (NaN or Inf) always breaks a band: the
    % invalid ROW is retained as a cold separator, not dropped (dropping it
    % would leave two warm neighbors that the gap rule alone would bridge).
    U = tc.TestData.U;
    t = mins(tc, [0 15 30]);
    for bad = [NaN, Inf, -Inf]
        sp = U.freeze_spans(t, [1; bad; 1]);
        verifyEqual(tc, size(sp), [2 2], sprintf('separator %g', bad));
        verifyEqual(tc, sp(1, 2), t(1) + minutes(7.5));
        verifyEqual(tc, sp(2, 1), t(3) - minutes(7.5));
    end
end

function test_gap_boundary(tc)
    % Sample gaps: exactly 1.5*dt does not split; anything greater does.
    U = tc.TestData.U;
    t_eq = mins(tc, [0 15 30 45 67.5]);        % median dt 15; last gap 22.5
    sp = U.freeze_spans(t_eq, ones(5, 1));
    verifyEqual(tc, size(sp), [1 2], 'gap == 1.5*dt must not split');
    t_gt = mins(tc, [0 15 30 45 69]);          % last gap 24 > 22.5
    sp = U.freeze_spans(t_gt, ones(5, 1));
    verifyEqual(tc, size(sp), [2 2], 'gap > 1.5*dt must split');
end

function test_sparse_cadence_capped(tc)
    % Two warm samples 6 h apart: the 1-hour cadence cap keeps the outage
    % from masquerading as the sampling interval — two narrow spans, never
    % one 6-hour band.
    U = tc.TestData.U;
    t = mins(tc, [0 360]);
    sp = U.freeze_spans(t, [1; 1]);
    verifyEqual(tc, size(sp), [2 2]);
    verifyLessThanOrEqual(tc, sp(1, 2) - sp(1, 1), hours(1) + seconds(1));
end

function test_duplicate_timestamps(tc)
    % Duplicates are kept in stable sort order; a cold duplicate splits.
    U = tc.TestData.U;
    t = mins(tc, [0 0 15]);
    sp = U.freeze_spans(t, [1; -1; 1]);
    verifyEqual(tc, size(sp), [2 2]);
    sp2 = U.freeze_spans(t, [1; 1; 1]);        % warm duplicates: one span
    verifyEqual(tc, size(sp2), [1 2]);
end

function test_unsorted_and_rowvec(tc)
    % Unsorted and row-vector inputs give the same sorted-column result.
    U = tc.TestData.U;
    t = mins(tc, 0:15:60);
    y = [-1; 1; 1; -1; 1];
    sp_ref = U.freeze_spans(t, y);
    ord = [4 1 5 2 3];
    sp = U.freeze_spans(reshape(t(ord), 1, []), reshape(y(ord), 1, []));
    verifyEqual(tc, sp, sp_ref);
end

function test_empty_cases(tc)
    % Every no-band case returns a 0x2 NaT (shape and type, not just empty).
    U = tc.TestData.U;
    for c = {U.freeze_spans(datetime.empty(0, 1), []), ...
             U.freeze_spans(mins(tc, [0 15]), [-1; 0]), ...
             U.freeze_spans(NaT(3, 1), [1; 1; 1]), ...
             U.freeze_spans([mins(tc, 0); NaT], [NaN; 1])}
        verifyEqual(tc, size(c{1}), [0 2]);
        verifyTrue(tc, isdatetime(c{1}));
    end
end

function test_single_sample_and_length_error(tc)
    U = tc.TestData.U;
    t1 = mins(tc, 0);
    sp = U.freeze_spans(t1, 1);                % dt fallback = 15 min
    verifyEqual(tc, sp, [t1 - minutes(7.5), t1 + minutes(7.5)]);
    verifyError(tc, @() U.freeze_spans(mins(tc, [0 15]), 1), ...
                'soop_viewer_util:freeze_spans:length');
end


% -------------------------------------------------- graphics assumptions

function test_xregion_yyaxis_layer_and_legend(tc)
    % The render's graphics contract: xregion works on yyaxis axes with
    % datetime x, honors Layer 'bottom', and joins a mixed explicit legend
    % with Line and ErrorBar handles.
    fig = figure('Visible', 'off');
    cleanup = onCleanup(@() close(fig));
    ax = axes(fig);
    yyaxis(ax, 'left');
    t0 = datetime(2026, 2, 1);
    hl = plot(ax, t0 + days(0:10), sin(0:10), '.');
    hr = xregion(ax, [t0 + days(2); t0 + days(6)], [t0 + days(3); t0 + days(8)], ...
                 'FaceColor', [1.0 0.55 0.10], 'FaceAlpha', 0.18, 'Layer', 'bottom');
    verifyNumElements(tc, hr, 2);              % one region per span pair
    verifyEqual(tc, char(hr(1).Layer), 'bottom');
    yyaxis(ax, 'right');
    he = errorbar(ax, t0 + days(0:5), 1:6, 0.1 * ones(1, 6), 'o-', 'MarkerSize', 4);
    lgd = legend([hl, he, hr(1)], {'phase', 'depth', 'wet snow'});
    verifyNumElements(tc, lgd.String, 3);
end

function test_markersize_mutation(tc)
    % The daily-filter marker bump mutates both handle types plot_series
    % can return (Line '.', ErrorBar 'o-').
    fig = figure('Visible', 'off');
    cleanup = onCleanup(@() close(fig));
    ax = axes(fig);
    hl = plot(ax, 1:5, 1:5, '.');
    m0 = hl.MarkerSize;
    hl.MarkerSize = hl.MarkerSize + 2;
    verifyEqual(tc, hl.MarkerSize, m0 + 2);
    he = errorbar(ax, 1:5, 1:5, ones(1, 5), 'o-', 'MarkerSize', 4);
    he.MarkerSize = he.MarkerSize + 2;
    verifyEqual(tc, he.MarkerSize, 6);
end

function tests = viewer_tod_filter_test
% Unit tests for the L2: Candidates daily time-of-day filter helpers in
% soop_viewer_util: parse_tod (input grammar) and tod_daily_idx
% (target-centered one-capture-per-day selection).
% Run: matlab -batch "soop_setup_paths; addpath('tests'); runtests('viewer_tod_filter_test')"
    tests = functiontests(localfunctions);
end


function setupOnce(tc)
    tc.TestData.U = soop_viewer_util();
end


% ---------------------------------------------------------------- parse_tod

function test_parse_accepts(tc)
    % Grammar: H, HH, HMM, HHMM, H:MM, HH:MM (hour 0-23, minute 0-59).
    U = tc.TestData.U;
    cases = {'0600', hours(6);        '06:00', hours(6)
             '6',    hours(6);        '600',   hours(6)
             '6:30', hours(6.5);      '23:59', hours(23) + minutes(59)
             '2359', hours(23) + minutes(59)
             '0',    hours(0);        '00:00', hours(0)
             '23',   hours(23);       '  0600  ', hours(6)};
    for k = 1:size(cases, 1)
        [dur, ok] = U.parse_tod(cases{k, 1});
        verifyTrue(tc, ok, sprintf('should accept %s', strtrim(cases{k, 1})));
        verifyEqual(tc, dur, cases{k, 2}, ...
            sprintf('wrong duration for %s', strtrim(cases{k, 1})));
    end
end

function test_parse_rejects(tc)
    % Out-of-range fields, malformed separators, signs/decimals, junk.
    U = tc.TestData.U;
    bad = {'', '24:00', '2400', '24', '0660', '23:60', '060', 'abc', ...
           '6.5', '-600', '+0600', '06:0', '06:000', '123456', '6 00', ...
           '6:', ':30', '0600x'};
    for k = 1:numel(bad)
        [~, ok] = U.parse_tod(bad{k});
        verifyFalse(tc, ok, sprintf('should reject "%s"', bad{k}));
    end
end


% ------------------------------------------------------------ tod_daily_idx

function test_nearest_per_day(tc)
    % Day 1 has 05:30 and 06:10 (06:10 wins: 10 min beats 30 min); day 2's
    % only capture is 18:00 (dropped, outside the window); day 3's single
    % 06:59 capture is kept (59 min).
    U = tc.TestData.U;
    t = datetime(2026, 1, [1 1 2 3]') + [hours(5) + minutes(30);
                                         hours(6) + minutes(10);
                                         hours(18);
                                         hours(6) + minutes(59)];
    [idx, tday] = U.tod_daily_idx(t, hours(6), hours(1));
    verifyEqual(tc, idx, [2; 4]);
    verifyEqual(tc, tday, datetime(2026, 1, [1; 3]));
end

function test_window_boundary(tc)
    % Exactly 1 h away is kept (<=); one minute past is dropped.
    U = tc.TestData.U;
    t = datetime(2026, 1, [1 2]') + [hours(7); hours(7) + minutes(1)];
    [idx, tday] = U.tod_daily_idx(t, hours(6), hours(1));
    verifyEqual(tc, idx, 1);
    verifyEqual(tc, tday, datetime(2026, 1, 1));
end

function test_cross_midnight(tc)
    % Target 23:30. Jan 2 00:15 is nearest to *Jan 1's* target instant
    % (45 min) and Jan 2 23:20 to Jan 2's (10 min): two captures sharing a
    % calendar date serve two different target days. Calendar-date grouping
    % would lose the Jan 1 point.
    U = tc.TestData.U;
    t = [datetime(2026, 1, 2) + hours(0) + minutes(15);
         datetime(2026, 1, 2) + hours(23) + minutes(20)];
    tgt = hours(23) + minutes(30);
    [idx, tday] = U.tod_daily_idx(t, tgt, hours(1));
    verifyEqual(tc, idx, [1; 2]);
    verifyEqual(tc, tday, datetime(2026, 1, [1; 2]));
end

function test_tie_keeps_first_row(tc)
    % 06:10 and 05:50 are both 10 min from 06:00; the earlier *row* (input
    % order, not clock order) wins deterministically.
    U = tc.TestData.U;
    t = datetime(2026, 1, 1) + [hours(6) + minutes(10);
                                hours(5) + minutes(50)];
    idx = U.tod_daily_idx(t, hours(6), hours(1));
    verifyEqual(tc, idx, 1);
end

function test_unsorted_input(tc)
    % Shuffled input: indices come back in original coordinates, ascending.
    U = tc.TestData.U;
    t = [datetime(2026, 1, 3) + hours(6) + minutes(20);   % day 3 winner
         datetime(2026, 1, 1) + hours(6) + minutes(5);    % day 1 winner
         datetime(2026, 1, 3) + hours(6) + minutes(40);
         datetime(2026, 1, 1) + hours(7) + minutes(30)];
    [idx, tday] = U.tod_daily_idx(t, hours(6), hours(1));
    verifyEqual(tc, idx, [1; 2]);
    verifyEqual(tc, tday, datetime(2026, 1, [3; 1]));   % aligned with idx
end

function test_duplicate_timestamps(tc)
    % Identical stamps: first original row wins.
    U = tc.TestData.U;
    t = datetime(2026, 1, 1) + hours(6) + [minutes(10); minutes(10)];
    idx = U.tod_daily_idx(t, hours(6), hours(1));
    verifyEqual(tc, idx, 1);
end

function test_nat_and_empty(tc)
    % Empty and all-NaT inputs return empty; mixed NaT rows are ignored.
    U = tc.TestData.U;
    [idx, tday] = U.tod_daily_idx(datetime.empty(0, 1), hours(6), hours(1));
    verifyEmpty(tc, idx);
    verifyEmpty(tc, tday);
    idx = U.tod_daily_idx(NaT(3, 1), hours(6), hours(1));
    verifyEmpty(tc, idx);
    t = [NaT; datetime(2026, 1, 1) + hours(6); NaT];
    idx = U.tod_daily_idx(t, hours(6), hours(1));
    verifyEqual(tc, idx, 2);
end

function test_zoned_input_rejected(tc)
    % Contract: naive wall-clock datetimes only (timeofday/dateshift diverge
    % from the displayed clock across DST for zoned datetimes).
    U = tc.TestData.U;
    t = datetime(2026, 1, 1, 6, 0, 0, 'TimeZone', 'America/Boise');
    verifyError(tc, @() U.tod_daily_idx(t, hours(6), hours(1)), ...
                'soop_viewer_util:tod_daily_idx:zoned');
end

function test_two_hourly_schedule_always_kept(tc)
    % The Brundage schedule captures every 2 h, so any target instant on a
    % fully covered day is at most 1 h from a capture — with the inclusive
    % boundary the day keeps exactly one row, whatever the target. (Two
    % days of data so late targets can bind day 1's just-past-midnight
    % neighbor, per the target-centered assignment.)
    U = tc.TestData.U;
    day = datetime(2026, 1, 1);
    t = day + hours(0:2:46)';   % Jan 1 00:00 .. Jan 2 22:00, every 2 h
    for tgt = [hours(0), hours(6), hours(7), hours(13), hours(23) + minutes(59)]
        [~, tday] = U.tod_daily_idx(t, tgt, hours(1));
        verifyEqual(tc, sum(tday == day), 1, ...
            sprintf('target %s should keep one row for day 1', char(tgt, 'hh:mm')));
    end
end

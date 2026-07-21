function tests = chain_session_test  %#ok<*NASGU> cfg fixtures are consumed inside evalc('compute_L2(cfg);') — invisible to the analyzer
% Test session-keyed chain-phase calibration and dependency invalidation.
% Covers session sentinels, metadata-only session_id patching, exact joins,
% chain_session, the NL-only angle(C_RDNS) estimator with full subtraction,
% stale-stamp rebuilds, and sigma0 invalidation.
%
% Stage tests run the production stages on tiny synthetic fixtures (real
% int16 captures for L1/calib, CSV-only fixtures for L2 — the chain join
% needs no raw data). All rng-seeded/deterministic.
%
% Run (from Processing/):
%   matlab -batch "soop_setup_paths; addpath('tests'); runtests('chain_session_test')"

    tests = functiontests(localfunctions);
end


% =========================================================================
% Per-test setup/teardown: keep parfor serial (no pool spin-up).
% =========================================================================
function setup(tc)
    tc.TestData.autopool = [];
    try
        ps = parallel.Settings;
        tc.TestData.autopool = ps.Pool.AutoCreate;
        ps.Pool.AutoCreate = false;
    catch
    end
end

function teardown(tc)
    try
        if ~isempty(tc.TestData.autopool)
            ps = parallel.Settings;
            ps.Pool.AutoCreate = tc.TestData.autopool;
        end
    catch
    end
end


% =========================================================================
% A. session_key sentinels
% =========================================================================
function test_session_key_shapes(tc)
    root = 'C:\data\root';
    verifyEqual(tc, session_key('C:\data\root', root), "legacy-flat");
    verifyEqual(tc, session_key('C:\data\root\', root), "legacy-flat");
    verifyEqual(tc, session_key('C:\data\root\20260712\031500', root), ...
                "20260712/031500");                       % '\' -> '/' canonical
    verifyEqual(tc, session_key('C:/data/root/20260712/031500/', root), ...
                "20260712/031500");                       % trailing sep tolerated
    verifyEqual(tc, session_key('C:\data\root\oddname', root), "unknown");
    verifyEqual(tc, session_key('C:\data\root\20260712\03150', root), "unknown");
    verifyEqual(tc, session_key('C:\data\root\20260712\031500\extra', root), "unknown");
    verifyEqual(tc, session_key('C:\other\place', root), "unknown");
end


% =========================================================================
% B. compute_L1: session_id creation and metadata-only patching
% =========================================================================
function test_l1_session_rows_and_patch(tc)
    cfg  = l1_cfg(tc);
    npts = floor(cfg.fs * cfg.Ti);
    [i0, q0, i1, q1] = gen_iq(npts * cfg.num_segs, 11);

    baseFlat = "UHF_20260101120000";
    baseRun  = "UHF_20260101130000";
    rund     = fullfile(cfg.data_dir, '20260101', '130000');
    mkdir(rund);
    write_capture(cfg.data_dir, baseFlat, i0, q0, i1, q1);
    write_capture(rund,         baseRun,  i0, q0, i1, q1);

    evalc('compute_L1(cfg);');
    T = readtable(fullfile(cfg.out_dir, 'BrundageSoOp_L1_sig.csv'), 'TextType', 'string');
    verifyEqual(tc, T.session_id(T.base_name == baseFlat), "legacy-flat");
    verifyEqual(tc, T.session_id(T.base_name == baseRun),  "20260101/130000");

    % Remove session_id, delete one capture, and duplicate another across
    % folders; the metadata-only patch must assign fail-closed sentinels.
    sig = fullfile(cfg.out_dir, 'BrundageSoOp_L1_sig.csv');
    T(:, 'session_id') = [];
    writetable(T, sig);
    delete(fullfile(char(cfg.data_dir), char(baseFlat) + "_ch0.dat"));
    delete(fullfile(char(cfg.data_dir), char(baseFlat) + "_ch1.dat"));
    rund2 = fullfile(cfg.data_dir, '20260101', '140000');
    mkdir(rund2);
    write_capture(rund2, baseRun, i0, q0, i1, q1);   % duplicate base name

    evalc('compute_L1(cfg);');
    T2 = readtable(sig, 'TextType', 'string');
    verifyEqual(tc, T2.session_id(T2.base_name == baseFlat), "unknown");  % off-disk
    verifyEqual(tc, T2.session_id(T2.base_name == baseRun),  "unknown");  % ambiguous
end


% =========================================================================
% C. compute_calib: per-capture mixed-layout run assignment + session_id
% =========================================================================
function test_calib_mixed_pairing_sessions(tc)
    cfg  = calib_cfg(tc);
    npts = floor(cfg.fs * cfg.Ti);
    n    = npts * cfg.num_segs;

    % Root-level NL and L captures 3 h apart belong to different gap runs and
    % must not pair. Two nested sessions 12 min apart (< the
    % 20-min gap) must remain separate runs and pair within themselves.
    % NL captures carry a strong ch0/ch1-common component (noise-diode
    % analogue), L captures independent noise — otherwise compute_calib's
    % P_NS ~ P_L degenerate guard rejects the pair.
    [ni0, nq0, ni1, nq1] = gen_nl_iq(n, 21);
    [li0, lq0, li1, lq1] = gen_l_iq(n, 22);
    write_capture(cfg.data_dir, "UHF__NL_20260101120000", ni0, nq0, ni1, nq1);
    write_capture(cfg.data_dir, "UHF__L_20260101150000",  li0, lq0, li1, lq1);
    r1 = fullfile(cfg.data_dir, '20260102', '100000');  mkdir(r1);
    r2 = fullfile(cfg.data_dir, '20260102', '101200');  mkdir(r2);
    write_capture(r1, "UHF__NL_20260102100000", ni0, nq0, ni1, nq1);
    write_capture(r1, "UHF__L_20260102100010",  li0, lq0, li1, lq1);
    write_capture(r2, "UHF__NL_20260102101200", ni0, nq0, ni1, nq1);
    write_capture(r2, "UHF__L_20260102101210",  li0, lq0, li1, lq1);

    evalc('compute_calib(cfg);');
    C = readtable(fullfile(cfg.out_dir, 'BrundageSoOp_calib.csv'), 'TextType', 'string');
    verifyEqual(tc, height(C), 2);                       % nested pairs only
    verifyEqual(tc, sort(C.session_id), ...
                sort(["20260102/100000"; "20260102/101200"]));

    % Remove session_id and rerun with no unprocessed pairs.
    oc = fullfile(cfg.out_dir, 'BrundageSoOp_calib.csv');
    C(:, 'session_id') = [];
    writetable(C, oc);
    evalc('compute_calib(cfg);');
    C2 = readtable(oc, 'TextType', 'string');
    verifyTrue(tc, ismember('session_id', C2.Properties.VariableNames));
    verifyEqual(tc, sort(C2.session_id), ...
                sort(["20260102/100000"; "20260102/101200"]));
end


% =========================================================================
% D. compute_L2 chain join (CSV fixtures, no raw data)
% =========================================================================
function test_l2_keyed_join_two_close_sessions(tc)
    d  = l2_dir(tc);
    t0 = datetime(2026, 1, 2, 10, 0, 0);
    % Two keyed sessions only 10 min apart (gap logic would merge them).
    cal = cal_rows([t0; t0 + minutes(10)], [30; -40], ...
                   ["20260102/100000"; "20260102/101000"]);
    sig = sig_rows([t0 + minutes(2); t0 + minutes(12)], ...
                   ["20260102/100000"; "20260102/101000"]);
    cfg = l2_fixture(d, sig, cal, t0);
    % Chain calibration always applies full subtraction without a reference knob.
    evalc('compute_L2(cfg);');

    L2 = readtable(fullfile(d, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    verifyEqual(tc, L2.phase_chain_deg, [30; -40], 'AbsTol', 1e-9);
    verifyEqual(tc, L2.chain_session, ["20260102/100000"; "20260102/101000"]);
    % Full per-session subtraction (ref = 0): cal - corr == -phase_chain, all
    % three domains.
    for c = {'phase_corr_cal_deg',        'phase_corr_deg';
             'phase_corr_cal_fd_deg',     'phase_corr_fd_deg';
             'phase_corr_cal_fd_muos_deg','phase_corr_fd_muos_deg'}'
        dlt = wrap180_local(L2.(c{1}) - L2.(c{2}));
        verifyEqual(tc, dlt, -L2.phase_chain_deg, 'AbsTol', 1e-9);
    end
    verifyTrue(tc, isfile(fullfile(d, 'BrundageSoOp_L2_chaincal_stamp.json')));
end

function test_l2_no_borrow_and_overflow_session(tc)
    d  = l2_dir(tc);
    t0 = datetime(2026, 1, 2, 10, 0, 0);
    % Session A healthy; session B's only calib pair is overflow-flagged;
    % session C has no calib at all. A legacy gap run sits nearby too.
    cal = cal_rows([t0; t0 + minutes(5); t0 + minutes(30)], [30; 77; 55], ...
                   ["20260102/100000"; "20260102/100500"; "legacy-flat"]);
    cal.overflow_flag(2) = 1;
    sig = sig_rows([t0 + minutes(1); t0 + minutes(6); t0 + minutes(8)], ...
                   ["20260102/100000"; "20260102/100500"; "20260102/100800"]);
    cfg = l2_fixture(d, sig, cal, t0);
    evalc('compute_L2(cfg);');

    L2 = readtable(fullfile(d, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    verifyEqual(tc, L2.phase_chain_deg(1), 30, 'AbsTol', 1e-9);
    verifyTrue(tc, isnan(L2.phase_chain_deg(2)));     % overflowed session: NaN,
    verifyTrue(tc, isnan(L2.phase_chain_deg(3)));     % absent session: NaN —
    % never the legacy run's 55; blank chain_session round-trips as <missing>
    verifyTrue(tc, ismissing(L2.chain_session(2)) || L2.chain_session(2) == "");
    verifyTrue(tc, ismissing(L2.chain_session(3)) || L2.chain_session(3) == "");
    % NaN chain phase propagates into all three calibrated phase domains.
    for c = {'phase_corr_cal_deg', 'phase_corr_cal_fd_deg', 'phase_corr_cal_fd_muos_deg'}
        verifyTrue(tc, all(isnan(L2.(c{1})([2 3]))));
        verifyTrue(tc, isfinite(L2.(c{1})(1)));
    end
end

function test_l2_legacy_tolerance_unknown_and_unsorted(tc)
    d  = l2_dir(tc);
    t0 = datetime(2026, 1, 2, 10, 0, 0);
    % Legacy gap runs at t0 and t0+3h (deliberately written UNSORTED); legacy
    % signals: within tolerance, just beyond tolerance (61 min), and rows
    % with unknown/whitespace provenance.
    cal = cal_rows([t0 + hours(3); t0], [20; 10], ["legacy-flat"; "legacy-flat"]);
    sig = sig_rows([t0 + minutes(30); t0 + minutes(61); t0 + minutes(5); t0 + minutes(6)], ...
                   ["legacy-flat"; "legacy-flat"; "unknown"; " "]);
    cfg = l2_fixture(d, sig, cal, t0);
    evalc('compute_L2(cfg);');

    L2 = readtable(fullfile(d, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    verifyEqual(tc, L2.phase_chain_deg(1), 10, 'AbsTol', 1e-9);   % nearest gap run
    verifyTrue(tc, startsWith(L2.chain_session(1), "gap:"));
    verifyTrue(tc, isnan(L2.phase_chain_deg(2)));                 % > 60 min
    verifyTrue(tc, isnan(L2.phase_chain_deg(3)));                 % unknown
    verifyTrue(tc, isnan(L2.phase_chain_deg(4)));                 % whitespace -> unknown
end

function test_l2_far_keyed_match_diagnostic(tc)
    d  = l2_dir(tc);
    t0 = datetime(2026, 1, 2, 10, 0, 0);
    cal = cal_rows(t0, 30, "20260102/100000");
    sig = sig_rows(t0 + hours(3), "20260102/100000");   % same session, 3 h away
    cfg = l2_fixture(d, sig, cal, t0);
    txt = evalc('compute_L2(cfg);');

    L2 = readtable(fullfile(d, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    verifyEqual(tc, L2.phase_chain_deg(1), 30, 'AbsTol', 1e-9);   % still matched
    verifySubstring(tc, txt, 'WARNING(chaincal-key)');            % but flagged
end

function test_l2_missing_session_columns_fail_closed(tc)
    % Calib CSV without session_id: chain cal disabled with a tagged warning.
    d  = l2_dir(tc);
    t0 = datetime(2026, 1, 2, 10, 0, 0);
    cal = cal_rows(t0, 30, "20260102/100000");
    cal(:, 'session_id') = [];
    sig = sig_rows(t0 + minutes(1), "20260102/100000");
    cfg = l2_fixture(d, sig, cal, t0);
    txt = evalc('compute_L2(cfg);');
    L2 = readtable(fullfile(d, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    verifyTrue(tc, all(isnan(L2.phase_chain_deg)));
    verifySubstring(tc, txt, 'WARNING(chaincal-prov)');

    % L1 CSV without session_id: every signal row treated as unknown.
    d2  = l2_dir(tc);
    cal2 = cal_rows(t0, 30, "20260102/100000");
    sig2 = sig_rows(t0 + minutes(1), "20260102/100000");
    sig2(:, 'session_id') = [];
    cfg2 = l2_fixture(d2, sig2, cal2, t0);
    txt2 = evalc('compute_L2(cfg2);');
    L22 = readtable(fullfile(d2, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    verifyTrue(tc, all(isnan(L22.phase_chain_deg)));
    verifySubstring(tc, txt2, 'WARNING(chaincal-prov)');
end

function test_l2_stamp_lifecycle(tc)
    d  = l2_dir(tc);
    t0 = datetime(2026, 1, 2, 10, 0, 0);
    % One keyed session with TWO pairs (circular mean of 30/40 = 35).
    cal = cal_rows([t0; t0 + minutes(2)], [30; 40], ...
                   ["20260102/100000"; "20260102/100000"]);
    sig = sig_rows(t0 + minutes(1), "20260102/100000");
    cfg = l2_fixture(d, sig, cal, t0);
    evalc('compute_L2(cfg);');
    L2 = readtable(fullfile(d, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    verifyEqual(tc, L2.phase_chain_deg(1), 35, 'AbsTol', 1e-9);

    % (a) An additional capture appends without an archive.
    sig2 = [sig; sig_rows(t0 + minutes(3), "20260102/100000")];
    write_csv_ts(fullfile(d, 'BrundageSoOp_L1_sig.csv'), sig2);
    evalc('compute_L2(cfg);');
    L2 = readtable(fullfile(d, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    verifyEqual(tc, height(L2), 2);
    verifyEmpty(tc, dir(fullfile(d, 'BrundageSoOp_L2_*stale*.csv')));

    % (b) Gap-min knob change: full rebuild (archive appears), sigma0
    % archived, deltas stay full subtraction in all three phase domains.
    fake_sigma0 = fullfile(d, 'BrundageSoOp_sigma0.csv');
    writetable(table(1, 'VariableNames', {'x'}), fake_sigma0);
    cfg_gap = cfg;  cfg_gap.chain_run_gap_min = 10;
    evalc('compute_L2(cfg_gap);');
    verifyNotEmpty(tc, dir(fullfile(d, 'BrundageSoOp_L2_chaincal_stale_*.csv')));
    verifyFalse(tc, isfile(fake_sigma0));
    verifyNotEmpty(tc, dir(fullfile(d, 'BrundageSoOp_sigma0_stale_*.csv')));
    L2 = readtable(fullfile(d, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    verifyEqual(tc, height(L2), 2);                    % full reprocess
    for c = {'phase_corr_cal_deg',        'phase_corr_deg';
             'phase_corr_cal_fd_deg',     'phase_corr_fd_deg';
             'phase_corr_cal_fd_muos_deg','phase_corr_fd_muos_deg'}'
        dlt = wrap180_local(L2.(c{1}) - L2.(c{2}));
        verifyEqual(tc, dlt, -L2.phase_chain_deg, 'AbsTol', 1e-9);
    end

    % (c) Late calib append to the SAME session (mean 35 -> 30): rebuild with
    % the new mean everywhere, not just on new rows.
    cal3 = cal_rows([t0; t0 + minutes(2); t0 + minutes(4)], [30; 40; 20], ...
                    repmat("20260102/100000", 3, 1));
    write_csv_ts(fullfile(d, 'BrundageSoOp_calib.csv'), cal3);
    evalc('compute_L2(cfg_gap);');
    L2 = readtable(fullfile(d, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    verifyEqual(tc, height(L2), 2);
    verifyEqual(tc, L2.phase_chain_deg, [30; 30], 'AbsTol', 1e-9);

    % (d) A join-tolerance knob change alone invalidates via the config stamp.
    cfg_tol = cfg_gap;  cfg_tol.chain_join_tol_min = 45;
    evalc('compute_L2(cfg_tol);');
    % Same-day rebuilds (b), (c), (d) must each keep a DISTINCT archive —
    % no overwritten/blocked recovery copies.
    arcs = dir(fullfile(d, 'BrundageSoOp_L2_chaincal_stale_*.csv'));
    verifyEqual(tc, numel(arcs), 3);
    verifyEqual(tc, numel(unique({arcs.name})), 3);
end

function test_l2_migration_lifecycle(tc)
% If L2 first runs without session_id, chain calibration is disabled and rows
% are NaN. Once both inputs gain session_id, L2 must detect usable calibration,
% rebuild, and repopulate those rows.
    d  = l2_dir(tc);
    t0 = datetime(2026, 1, 2, 10, 0, 0);
    cal = cal_rows(t0, 30, "20260102/100000");
    sig = sig_rows(t0 + minutes(1), "20260102/100000");
    cal_pre = cal;  cal_pre(:, 'session_id') = [];
    sig_pre = sig;  sig_pre(:, 'session_id') = [];
    cfg = l2_fixture(d, sig_pre, cal_pre, t0);
    evalc('compute_L2(cfg);');
    L2 = readtable(fullfile(d, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    verifyTrue(tc, all(isnan(L2.phase_chain_deg)));

    write_csv_ts(fullfile(d, 'BrundageSoOp_calib.csv'),  cal);   % v6 migration
    write_csv_ts(fullfile(d, 'BrundageSoOp_L1_sig.csv'), sig);
    evalc('compute_L2(cfg);');
    verifyNotEmpty(tc, dir(fullfile(d, 'BrundageSoOp_L2_chaincal_stale_*.csv')));
    L2 = readtable(fullfile(d, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    verifyEqual(tc, height(L2), 1);
    verifyEqual(tc, L2.phase_chain_deg(1), 30, 'AbsTol', 1e-9);
    verifyEqual(tc, L2.chain_session(1), "20260102/100000");
end

function test_l2_new_calib_and_sid_repair(tc)
% (a) First calib run appearing for an already-written unmatched keyed
% signal must trigger a rebuild (not remain an ignorable "extra run").
% (b) Repairing an L1 session_id must recompute that row's association.
    d  = l2_dir(tc);
    t0 = datetime(2026, 1, 2, 10, 0, 0);
    sig = sig_rows(t0 + minutes(1), "20260102/100000");
    cfg = l2_fixture(d, sig, cal_rows(datetime.empty(0,1), [], strings(0,1)), t0);
    delete(fullfile(d, 'BrundageSoOp_calib.csv'));         % no calib at all yet
    evalc('compute_L2(cfg);');
    L2 = readtable(fullfile(d, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    verifyTrue(tc, isnan(L2.phase_chain_deg(1)));

    cal = cal_rows([t0; t0 + minutes(30)], [30; -70], ...
                   ["20260102/100000"; "20260102/103000"]);
    write_csv_ts(fullfile(d, 'BrundageSoOp_calib.csv'), cal);
    evalc('compute_L2(cfg);');                             % (a) newly usable calib
    L2 = readtable(fullfile(d, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    verifyEqual(tc, L2.phase_chain_deg(1), 30, 'AbsTol', 1e-9);
    verifyEqual(tc, L2.chain_session(1), "20260102/100000");

    sig2 = sig;  sig2.session_id(1) = "20260102/103000";   % (b) provenance repair
    write_csv_ts(fullfile(d, 'BrundageSoOp_L1_sig.csv'), sig2);
    evalc('compute_L2(cfg);');
    L2 = readtable(fullfile(d, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    verifyEqual(tc, L2.phase_chain_deg(1), -70, 'AbsTol', 1e-9);
    verifyEqual(tc, L2.chain_session(1), "20260102/103000");
end

function test_l2_malformed_and_backslash_keys(tc)
% CSV-level sentinel hygiene: matching malformed values must NOT be chain-
% calibrated (fail closed + tagged warning); a Windows-separator key must be
% canonicalized and still match its slash-form counterpart.
    d  = l2_dir(tc);
    t0 = datetime(2026, 1, 2, 10, 0, 0);
    cal = cal_rows([t0; t0 + minutes(10)], [30; 40], ...
                   ["bad-key"; "20260102/101000"]);
    sig = sig_rows([t0 + minutes(1); t0 + minutes(11)], ...
                   ["bad-key"; "20260102\101000"]);
    cfg = l2_fixture(d, sig, cal, t0);
    txt = evalc('compute_L2(cfg);');
    L2 = readtable(fullfile(d, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    verifyTrue(tc, isnan(L2.phase_chain_deg(1)));          % bad-key both sides
    verifySubstring(tc, txt, 'malformed');
    verifyEqual(tc, L2.phase_chain_deg(2), 40, 'AbsTol', 1e-9);  % '\' -> '/'
    verifyEqual(tc, L2.chain_session(2), "20260102/101000");
end

function test_l2_schema_upgrade_rebuild(tc)
    % An L2 CSV with phase_chain_deg but no chain_session is archived once and
    % fully rebuilt.
    d  = l2_dir(tc);
    t0 = datetime(2026, 1, 2, 10, 0, 0);
    cal = cal_rows(t0, 30, "20260102/100000");
    sig = sig_rows(t0 + minutes(1), "20260102/100000");
    cfg = l2_fixture(d, sig, cal, t0);
    evalc('compute_L2(cfg);');
    old = readtable(fullfile(d, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    old(:, 'chain_session') = [];                       % simulate pre-v6 schema
    writetable(old, fullfile(d, 'BrundageSoOp_L2.csv'));
    delete(fullfile(d, 'BrundageSoOp_L2_chaincal_stamp.json'));
    evalc('compute_L2(cfg);');
    verifyNotEmpty(tc, dir(fullfile(d, 'BrundageSoOp_L2_no_chainsession_*.csv')));
    L2 = readtable(fullfile(d, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    verifyEqual(tc, height(L2), 1);
    verifyTrue(tc, ismember('chain_session', L2.Properties.VariableNames));
end


function test_l2_stamp_v1_to_v3_migration(tc)
% A reference-bearing dependency stamp is incompatible with the current stamp
% regardless of its stored value. It forces one rebuild; the rewritten stamp
% omits the reference field and permits later appends.
    d  = l2_dir(tc);
    t0 = datetime(2026, 1, 2, 10, 0, 0);
    cal = cal_rows(t0, 30, "20260102/100000");
    sig = sig_rows(t0 + minutes(1), "20260102/100000");
    cfg = l2_fixture(d, sig, cal, t0);
    evalc('compute_L2(cfg);');

    % Overwrite the stamp with matching knobs/runs plus a reference field.
    sp  = fullfile(d, 'BrundageSoOp_L2_chaincal_stamp.json');
    st  = jsondecode(fileread(sp));
    v1  = struct('algo_version', 1, 'chain_phase_ref_deg', 5, ...   % nonzero:
                 'chain_run_gap_min', st.chain_run_gap_min, ...     % the risky
                 'chain_join_tol_min', st.chain_join_tol_min, ...   % legacy case
                 'runs', st.runs);
    fid = fopen(sp, 'w');  fwrite(fid, jsonencode(v1));  fclose(fid);

    evalc('compute_L2(cfg);');
    verifyEqual(tc, numel(dir(fullfile(d, 'BrundageSoOp_L2_chaincal_stale_*.csv'))), 1);
    L2 = readtable(fullfile(d, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    verifyEqual(tc, height(L2), 1);
    for c = {'phase_corr_cal_deg',        'phase_corr_deg';
             'phase_corr_cal_fd_deg',     'phase_corr_fd_deg';
             'phase_corr_cal_fd_muos_deg','phase_corr_fd_muos_deg'}'
        dlt = wrap180_local(L2.(c{1}) - L2.(c{2}));
        verifyEqual(tc, dlt, -L2.phase_chain_deg, 'AbsTol', 1e-9);
    end
    st2 = jsondecode(fileread(sp));
    verifyEqual(tc, st2.algo_version, 3);
    verifyFalse(tc, isfield(st2, 'chain_phase_ref_deg'));

    % Appends resume under the rewritten stamp: one new capture, no new
    % archive, full subtraction on every row.
    sig2 = [sig; sig_rows(t0 + minutes(3), "20260102/100000")];
    write_csv_ts(fullfile(d, 'BrundageSoOp_L1_sig.csv'), sig2);
    evalc('compute_L2(cfg);');
    verifyEqual(tc, numel(dir(fullfile(d, 'BrundageSoOp_L2_chaincal_stale_*.csv'))), 1);
    L2 = readtable(fullfile(d, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    verifyEqual(tc, height(L2), 2);
    for c = {'phase_corr_cal_deg',        'phase_corr_deg';
             'phase_corr_cal_fd_deg',     'phase_corr_fd_deg';
             'phase_corr_cal_fd_muos_deg','phase_corr_fd_muos_deg'}'
        dlt = wrap180_local(L2.(c{1}) - L2.(c{2}));
        verifyEqual(tc, dlt, -L2.phase_chain_deg, 'AbsTol', 1e-9);
    end
end

function test_l2_chain_nl_only_estimator(tc)
% A nonzero C_RDL term must not affect the NL-only estimator: phase_chain_deg
% and all calibrated phase domains must use the C_RDNS phase (30 deg), not
% angle(e^{i30} - 0.5 e^{i120}) (~3.4 deg).
    d  = l2_dir(tc);
    t0 = datetime(2026, 1, 2, 10, 0, 0);
    cal = cal_rows_leak(t0, 30, 1, 0.5, 120, "20260102/100000");
    sig = sig_rows(t0 + minutes(2), "20260102/100000");
    cfg = l2_fixture(d, sig, cal, t0);
    evalc('compute_L2(cfg);');
    L2 = readtable(fullfile(d, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    verifyEqual(tc, L2.phase_chain_deg, 30, 'AbsTol', 1e-9);
    nsl = rad2deg(angle(exp(1i*deg2rad(30)) - 0.5*exp(1i*deg2rad(120))));
    verifyGreaterThan(tc, abs(wrap180_local(30 - nsl)), 5, ...
        'fixture must discriminate the two estimators');
    for c = {'phase_corr_cal_deg',        'phase_corr_deg';
             'phase_corr_cal_fd_deg',     'phase_corr_fd_deg';
             'phase_corr_cal_fd_muos_deg','phase_corr_fd_muos_deg'}'
        dlt = wrap180_local(L2.(c{1}) - L2.(c{2}));
        verifyEqual(tc, dlt, -30, 'AbsTol', 1e-9);
    end
end

function test_l2_chain_no_crdl_columns(tc)
% The NL-only estimator must not require the C_RDL columns at all: a calib
% CSV without them still chain-calibrates.
    d  = l2_dir(tc);
    t0 = datetime(2026, 1, 2, 10, 0, 0);
    cal = removevars(cal_rows(t0, 25, "20260102/100000"), ...
                     {'C_RDL_amp', 'C_RDL_phase_deg'});
    sig = sig_rows(t0 + minutes(2), "20260102/100000");
    cfg = l2_fixture(d, sig, cal, t0);
    evalc('compute_L2(cfg);');
    L2 = readtable(fullfile(d, 'BrundageSoOp_L2.csv'), 'TextType', 'string');
    verifyEqual(tc, L2.phase_chain_deg, 25, 'AbsTol', 1e-9);
    verifyEqual(tc, wrap180_local(L2.phase_corr_cal_deg - L2.phase_corr_deg), ...
                -25, 'AbsTol', 1e-9);
end

function test_l2_chain_equal_weight_and_wrap(tc)
% (a) Equal-weight reduction: session A pairs at 0 deg (amp 1) and 90 deg
% (amp 100) must average to 45 deg — amplitude weighting would give ~90.
% (b) Wrap edge: session B pairs at +179/-179 deg average to 180 deg, and
% the applied (wrapped) delta stays consistent.
    d  = l2_dir(tc);
    t0 = datetime(2026, 1, 2, 10, 0, 0);
    kA = "20260102/100000";  kB = "20260102/110000";
    cal = [cal_rows_leak([t0; t0 + minutes(1)], [0; 90], [1; 100], 0, 0, [kA; kA]); ...
           cal_rows([t0 + minutes(60); t0 + minutes(61)], [179; -179], [kB; kB])];
    sig = sig_rows([t0 + minutes(2); t0 + minutes(62)], [kA; kB]);
    cfg = l2_fixture(d, sig, cal, t0);
    evalc('compute_L2(cfg);');
    L2 = sortrows(readtable(fullfile(d, 'BrundageSoOp_L2.csv'), ...
                            'TextType', 'string'), 'timestamp');
    verifyEqual(tc, L2.phase_chain_deg(1), 45, 'AbsTol', 1e-9);
    verifyEqual(tc, wrap180_local(L2.phase_chain_deg(2) - 180), 0, 'AbsTol', 1e-9);
    for c = {'phase_corr_cal_deg',        'phase_corr_deg';
             'phase_corr_cal_fd_deg',     'phase_corr_fd_deg';
             'phase_corr_cal_fd_muos_deg','phase_corr_fd_muos_deg'}'
        dlt = wrap180_local(L2.(c{1}) - L2.(c{2}));
        verifyEqual(tc, wrap180_local(dlt + L2.phase_chain_deg), [0; 0], ...
                    'AbsTol', 1e-9);
    end
end

function test_l2_chain_degenerate_policy(tc)
% Fail-closed policy: (a) nonfinite/zero-amplitude pairs are
% excluded, so a session with no usable pair joins as NaN; (b) exactly
% opposed pairs leave a ~zero circular-mean resultant — NaN, never
% atan2(0,0) = 0 masquerading as a valid phase. A healthy control session
% still calibrates.
    d  = l2_dir(tc);
    t0 = datetime(2026, 1, 2, 10, 0, 0);
    kA = "20260102/100000";  kB = "20260102/110000";  kC = "20260102/120000";
    cal = [cal_rows_leak([t0; t0 + minutes(1)], [10; NaN], [0; 1], 0, 0, [kA; kA]); ...  % amp 0 + NaN phase
           cal_rows([t0 + minutes(60); t0 + minutes(61)], [0; 180], [kB; kB]); ...       % opposed pair
           cal_rows(t0 + minutes(120), 30, kC)];                                         % healthy control
    sig = sig_rows([t0 + minutes(2); t0 + minutes(62); t0 + minutes(122)], ...
                   [kA; kB; kC]);
    cfg = l2_fixture(d, sig, cal, t0);
    out = evalc('compute_L2(cfg);');
    % A keyed session that matches but carries NaN must not make any reported
    % association count negative.
    verifyEmpty(tc, regexp(out, '-\d+ (keyed|legacy)', 'once'), ...
                'negative association count in the chain-cal summary');
    L2 = sortrows(readtable(fullfile(d, 'BrundageSoOp_L2.csv'), ...
                            'TextType', 'string'), 'timestamp');
    verifyTrue(tc, isnan(L2.phase_chain_deg(1)), 'no-usable-pair session');
    verifyTrue(tc, isnan(L2.phase_corr_cal_deg(1)));
    verifyTrue(tc, isnan(L2.phase_chain_deg(2)), 'zero-resultant session');
    verifyTrue(tc, isnan(L2.phase_corr_cal_deg(2)));
    verifyEqual(tc, L2.phase_chain_deg(3), 30, 'AbsTol', 1e-9);
    verifyEqual(tc, wrap180_local(L2.phase_corr_cal_deg(3) - L2.phase_corr_deg(3)), ...
                -30, 'AbsTol', 1e-9);
end

function test_l2_stamp_v2_to_v3_stale_content(tc)
% A stale product with NS-L-derived chain values and a stale stamp must rebuild
% exactly once, archiving L2 and sigma0. The leak term makes stale and current
% values distinct, proving numerical replacement rather than a stamp-only gate.
    d  = l2_dir(tc);
    t0 = datetime(2026, 1, 2, 10, 0, 0);
    cal = cal_rows_leak(t0, 30, 1, 0.5, 120, "20260102/100000");
    sig = sig_rows(t0 + minutes(2), "20260102/100000");
    cfg = l2_fixture(d, sig, cal, t0);
    evalc('compute_L2(cfg);');
    out_csv = fullfile(d, 'BrundageSoOp_L2.csv');
    sp      = fullfile(d, 'BrundageSoOp_L2_chaincal_stamp.json');

    % Install stale NS-L chain columns/stamp and a sigma0 product to invalidate.
    nsl = rad2deg(angle(exp(1i*deg2rad(30)) - 0.5*exp(1i*deg2rad(120))));
    L2  = readtable(out_csv, 'TextType', 'string');
    L2.phase_chain_deg(:) = nsl;
    for c = {'phase_corr_cal_deg',        'phase_corr_deg';
             'phase_corr_cal_fd_deg',     'phase_corr_fd_deg';
             'phase_corr_cal_fd_muos_deg','phase_corr_fd_muos_deg'}'
        L2.(c{1}) = wrap180_local(L2.(c{2}) - nsl);
    end
    write_csv_ts(out_csv, L2);
    st = jsondecode(fileread(sp));
    st.algo_version = 2;
    fid = fopen(sp, 'w');  fwrite(fid, jsonencode(st));  fclose(fid);
    writetable(table(1, 'VariableNames', {'placeholder'}), ...
               fullfile(d, 'BrundageSoOp_sigma0.csv'));

    evalc('compute_L2(cfg);');
    verifyEqual(tc, numel(dir(fullfile(d, 'BrundageSoOp_L2_chaincal_stale_*.csv'))), 1);
    verifyEqual(tc, numel(dir(fullfile(d, 'BrundageSoOp_sigma0_stale_*.csv'))), 1);
    verifyFalse(tc, isfile(fullfile(d, 'BrundageSoOp_sigma0.csv')));
    L2b = readtable(out_csv, 'TextType', 'string');
    verifyEqual(tc, L2b.phase_chain_deg, 30, 'AbsTol', 1e-9);
    for c = {'phase_corr_cal_deg',        'phase_corr_deg';
             'phase_corr_cal_fd_deg',     'phase_corr_fd_deg';
             'phase_corr_cal_fd_muos_deg','phase_corr_fd_muos_deg'}'
        dlt = wrap180_local(L2b.(c{1}) - L2b.(c{2}));
        verifyEqual(tc, dlt, -30, 'AbsTol', 1e-9);
    end
    st3 = jsondecode(fileread(sp));
    verifyEqual(tc, st3.algo_version, 3);

    % Append under the current stamp without archiving either product again.
    sig2 = [sig; sig_rows(t0 + minutes(3), "20260102/100000")];
    write_csv_ts(fullfile(d, 'BrundageSoOp_L1_sig.csv'), sig2);
    evalc('compute_L2(cfg);');
    verifyEqual(tc, numel(dir(fullfile(d, 'BrundageSoOp_L2_chaincal_stale_*.csv'))), 1);
    verifyEqual(tc, numel(dir(fullfile(d, 'BrundageSoOp_sigma0_stale_*.csv'))), 1);
    verifyEqual(tc, height(readtable(out_csv)), 2);
end

function test_l2_stamp_v2_version_gate_only(tc)
% Isolate the algorithm-stamp gate: stored associations already equal the
% current result because C_RDL=0, so the stale stamp alone must force exactly
% one rebuild. Appends then proceed under the rewritten stamp.
    d  = l2_dir(tc);
    t0 = datetime(2026, 1, 2, 10, 0, 0);
    cal = cal_rows(t0, 30, "20260102/100000");
    sig = sig_rows(t0 + minutes(2), "20260102/100000");
    cfg = l2_fixture(d, sig, cal, t0);
    evalc('compute_L2(cfg);');
    sp = fullfile(d, 'BrundageSoOp_L2_chaincal_stamp.json');
    st = jsondecode(fileread(sp));
    st.algo_version = 2;
    fid = fopen(sp, 'w');  fwrite(fid, jsonencode(st));  fclose(fid);

    evalc('compute_L2(cfg);');
    verifyEqual(tc, numel(dir(fullfile(d, 'BrundageSoOp_L2_chaincal_stale_*.csv'))), 1);
    st3 = jsondecode(fileread(sp));
    verifyEqual(tc, st3.algo_version, 3);
    out_csv = fullfile(d, 'BrundageSoOp_L2.csv');
    L2 = readtable(out_csv, 'TextType', 'string');
    verifyEqual(tc, L2.phase_chain_deg, 30, 'AbsTol', 1e-9);

    sig2 = [sig; sig_rows(t0 + minutes(3), "20260102/100000")];
    write_csv_ts(fullfile(d, 'BrundageSoOp_L1_sig.csv'), sig2);
    evalc('compute_L2(cfg);');
    verifyEqual(tc, numel(dir(fullfile(d, 'BrundageSoOp_L2_chaincal_stale_*.csv'))), 1);
    verifyEqual(tc, height(readtable(out_csv)), 2);
end


% =========================================================================
% Fixture helpers
% =========================================================================
function cfg = l1_cfg(tc)
% Tiny compute_L1 cfg (mirrors sigma0_pipeline_test): npts = 1000, 2 segs.
    d    = tempname;   mkdir(d);
    data = tempname;   mkdir(data);
    tc.addTeardown(@() rmdir_safe(d));
    tc.addTeardown(@() rmdir_safe([d '_notch']));
    tc.addTeardown(@() rmdir_safe(data));

    cfg = struct();
    cfg.data_dir     = data;
    cfg.out_dir      = d;
    cfg.fs           = 1e5;
    cfg.Ti           = 0.01;                     % npts = 1000
    cfg.num_segs     = 2;
    cfg.peak_lag     = 0;
    cfg.lag_half_win = 50;
    cfg.min_bytes    = 1000*2*4;
    cfg.batch_size   = 200;
    cfg.use_gpu      = false;
    cfg.freq_hz      = 370e6;
    cfg.rfi_methods  = {'none'};
    cfg.rfi_bands    = [];
    cfg.muos_bands   = 1e6 * [369.97 370.03];
end

function cfg = calib_cfg(tc)
% compute_calib on the same tiny geometry.
    cfg = l1_cfg(tc);
    cfg.T_load_K     = 303;
    cfg.rfi_bands_nl = zeros(0, 2);
    cfg.rfi_bands_l  = zeros(0, 2);
end

function d = l2_dir(tc)
    d = tempname;   mkdir(d);
    tc.addTeardown(@() rmdir_safe(d));
end

function cfg = l2_fixture(d, sig, cal, t0)
% Write the three CSVs compute_L2 reads and return its minimal cfg. The
% elevation table spans t0-1h .. t0+5h (covers every fixture timestamp).
    write_csv_ts(fullfile(d, 'BrundageSoOp_L1_sig.csv'), sig);
    write_csv_ts(fullfile(d, 'BrundageSoOp_calib.csv'),  cal);
    et = (t0 - hours(1)) + hours((0:0.5:6)');
    n  = numel(et);
    ELEV = table(et, repmat(40, n, 1), repmat(180, n, 1), repmat(37000, n, 1), ...
                 'VariableNames', {'timestamp', 'elevation_deg', 'azimuth_deg', 'range_km'});
    elev_csv = fullfile(d, 'elev.csv');
    write_csv_ts(elev_csv, ELEV);

    cfg = struct();
    cfg.out_dir    = d;
    cfg.elev_table = elev_csv;
    cfg.tower_h_m  = 3.02;
    cfg.freq_hz    = 370e6;
end

function T = sig_rows(ts, sids)
% Minimal L1 signal rows for compute_L2 (phases chosen distinct per domain).
    ts = ts(:);  n = numel(ts);
    T = table(ts, "UHF_" + string(ts, 'yyyyMMddHHmmss'), ...
              repmat(100, n, 1), repmat(10, n, 1), repmat(110, n, 1), ...
              repmat(120, n, 1), zeros(n, 1), string(sids(:)), ...
              'VariableNames', {'timestamp', 'base_name', 'peak_phase_deg', ...
              'snr_db', 'peak_phase_deg_fd', 'peak_phase_deg_fd_muos', ...
              'overflow_flag', 'session_id'});
end

function T = cal_rows(ts, ph_deg, sids)
% Calib rows whose NL-only chain estimator angle(C_RDNS) is exactly ph_deg.
% C_RDL columns are kept at zero for CSV realism; the estimator ignores them.
    ts = ts(:);  ph = ph_deg(:);  n = numel(ts);
    T = table(ts, ones(n, 1), ph, zeros(n, 1), zeros(n, 1), zeros(n, 1), ...
              string(sids(:)), ...
              'VariableNames', {'timestamp', 'C_RDNS_amp', 'C_RDNS_phase_deg', ...
              'C_RDL_amp', 'C_RDL_phase_deg', 'overflow_flag', 'session_id'});
end

function T = cal_rows_leak(ts, ph_ns_deg, amp_ns, amp_l, ph_l_deg, sids)
% Calib rows with explicit C_RDNS amplitude and a (possibly nonzero) C_RDL
% "leak" term. Scalar arguments broadcast; vectors are per-row. Varying C_RDL
% verifies that the NL-only estimator depends only on C_RDNS.
    ts = ts(:);  n = numel(ts);
    ex = @(v) v(:) .* ones(n, 1);
    T = table(ts, ex(amp_ns), ex(ph_ns_deg), ex(amp_l), ex(ph_l_deg), ...
              zeros(n, 1), string(sids(:)), ...
              'VariableNames', {'timestamp', 'C_RDNS_amp', 'C_RDNS_phase_deg', ...
              'C_RDL_amp', 'C_RDL_phase_deg', 'overflow_flag', 'session_id'});
end

function write_csv_ts(path, T)
    if ismember('timestamp', T.Properties.VariableNames) && isdatetime(T.timestamp)
        T.timestamp.Format = 'yyyy-MM-dd HH:mm:ss';
    end
    writetable(T, path);
end

function y = wrap180_local(x)
    y = mod(x + 180, 360) - 180;
end

function rmdir_safe(dd)
    if isfolder(dd), rmdir(dd, 's'); end
end

function [i0, q0, i1, q1] = gen_iq(nsamp, seed)
    rng(seed);
    i0 = int16(randi([-2000 2000], nsamp, 1));
    q0 = int16(randi([-2000 2000], nsamp, 1));
    i1 = int16(randi([-2000 2000], nsamp, 1));
    q1 = int16(randi([-2000 2000], nsamp, 1));
end

function [i0, q0, i1, q1] = gen_nl_iq(nsamp, seed)
% NL-state analogue: strong ch0/ch1-common component (the "noise diode")
% plus small independent noise per channel.
    rng(seed);
    ci = randi([-1500 1500], nsamp, 1);
    cq = randi([-1500 1500], nsamp, 1);
    i0 = int16(ci + randi([-100 100], nsamp, 1));
    q0 = int16(cq + randi([-100 100], nsamp, 1));
    i1 = int16(ci + randi([-100 100], nsamp, 1));
    q1 = int16(cq + randi([-100 100], nsamp, 1));
end

function [i0, q0, i1, q1] = gen_l_iq(nsamp, seed)
% L-state analogue: independent noise per channel (terminated load).
    rng(seed);
    i0 = int16(randi([-300 300], nsamp, 1));
    q0 = int16(randi([-300 300], nsamp, 1));
    i1 = int16(randi([-300 300], nsamp, 1));
    q1 = int16(randi([-300 300], nsamp, 1));
end

function write_capture(dir_, base, i0, q0, i1, q1)
    write_ch(fullfile(dir_, char(base) + "_ch0.dat"), i0, q0);
    write_ch(fullfile(dir_, char(base) + "_ch1.dat"), i1, q1);
end

function write_ch(path, I, Q)
    n = numel(I);
    buf = zeros(2*n, 1, 'int16');
    buf(1:2:end) = I;
    buf(2:2:end) = Q;
    fid = fopen(path, 'w');
    fwrite(fid, buf, 'int16');
    fclose(fid);
end

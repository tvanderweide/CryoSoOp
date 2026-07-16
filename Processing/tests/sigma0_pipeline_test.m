function tests = sigma0_pipeline_test
% Production-stage tests for compute_L1 (channel powers, RFI-operator
% consistency, schema migration / incremental recovery) and soop_run_pipeline
% dispatch — the compute-path coverage accepted in disposition 8 that the pure
% sigma0_geometry_test suite does not exercise.
%
% All fixtures are tiny (npts = floor(fs*Ti) = 1000, 2 segments) and rng-seeded
% so the suite stays fast and deterministic. Every test writes a real int16
% ch0/ch1 capture pair and runs the production compute_L1, then checks its
% output against an independent hand computation (Parseval / Hann / segment
% average, and the rfi_excise operator itself for the notch method).
%
% Parallel note: setup() disables automatic parpool creation so compute_L1's
% parfor runs serially in the client (no pool spawned) — this keeps runtime
% tight AND lets the dispatch test assert that a sigma0-only pipeline run starts
% no pool.
%
% Run (from Processing/):
%   matlab -batch "soop_setup_paths; addpath('tests'); runtests('sigma0_pipeline_test')"

    tests = functiontests(localfunctions);
end


% =========================================================================
% Per-test setup/teardown: keep parfor from spawning a pool.
% =========================================================================
function setup(tc)
    tc.TestData.autopool = [];
    try
        ps = parallel.Settings;
        tc.TestData.autopool = ps.Pool.AutoCreate;
        ps.Pool.AutoCreate = false;              % parfor runs serially, no pool
    catch
        % Parallel Toolbox absent — parfor is already a serial for-loop.
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
% A. compute_L1 channel-power correctness ('none' method)
% =========================================================================
function test_L1_channel_power_none(tc)
% Two synthetic pairs (B = 2*A). Assert compute_L1's pow_ch0_fd / pow_ch0_fd_muos
% / pow_ch1_* equal the hand-computed windowed Parseval values (RelTol 1e-10),
% that doubling the int16 amplitudes quadruples every power (ADC^2 scaling), and
% that the MUOS columns use the same rfi_excise band mask compute_L1 uses.
    [cfg, d] = l1_cfg(tc);
    npts = floor(cfg.fs*cfg.Ti);  ns = cfg.num_segs;
    win  = hann_local(npts);
    mask = rfi_excise().band_mask(cfg.muos_bands, cfg.freq_hz, cfg.fs, npts);

    [ai0,aq0,ai1,aq1] = gen_iq(npts*ns, 101);
    baseA = "UHF_20260101120000";
    baseB = "UHF_20260101130000";
    write_capture(cfg.data_dir, baseA, ai0, aq0, ai1, aq1);
    write_capture(cfg.data_dir, baseB, 2*ai0, 2*aq0, 2*ai1, 2*aq1);  % 2x amplitude

    compute_L1(cfg);

    T = readtable(fullfile(d, 'BrundageSoOp_L1_sig.csv'), 'TextType', 'string');
    verifyEqual(tc, height(T), 2);
    A = T(T.base_name == baseA, :);
    B = T(T.base_name == baseB, :);

    % Hand-computed powers for pair A (direct = ch0, reflected = ch1).
    chA0 = double(ai0) + 1i*double(aq0);
    chA1 = double(ai1) + 1i*double(aq1);
    [p0, p0m] = expected_pow(chA0, win, npts, ns, mask);
    [p1, p1m] = expected_pow(chA1, win, npts, ns, mask);

    verifyEqual(tc, A.pow_ch0_fd,      p0,  'RelTol', 1e-10);
    verifyEqual(tc, A.pow_ch0_fd_muos, p0m, 'RelTol', 1e-10);
    verifyEqual(tc, A.pow_ch1_fd,      p1,  'RelTol', 1e-10);
    verifyEqual(tc, A.pow_ch1_fd_muos, p1m, 'RelTol', 1e-10);

    % ADC^2 scaling: doubling the samples quadruples every power.
    verifyEqual(tc, B.pow_ch0_fd,      4*p0,  'RelTol', 1e-10);
    verifyEqual(tc, B.pow_ch0_fd_muos, 4*p0m, 'RelTol', 1e-10);
    verifyEqual(tc, B.pow_ch1_fd,      4*p1,  'RelTol', 1e-10);
    verifyEqual(tc, B.pow_ch1_fd_muos, 4*p1m, 'RelTol', 1e-10);

    % MUOS is a strict sub-band of the full band.
    verifyLessThan(tc, A.pow_ch0_fd_muos, A.pow_ch0_fd);
end


% =========================================================================
% B. compute_L1 notch operator consistency ('none' + 'notch_interp')
% =========================================================================
function test_L1_notch_operator_consistency(tc)
% With rfi_methods = {'none','notch_interp'} and a non-empty in-band rfi_bands,
% the notch dir's powers must equal the hand computation with the SAME
% rfi_excise prepare/apply operator (operator-consistency, not a re-derivation),
% and the 'none' dir must be unchanged from the no-excision computation.
    [cfg, d] = l1_cfg(tc);
    cfg.rfi_methods = {'none', 'notch_interp'};
    cfg.rfi_bands   = 1e6 * [369.98 370.00];     % in-band RFI notch
    npts = floor(cfg.fs*cfg.Ti);  ns = cfg.num_segs;
    win  = hann_local(npts);
    mask = rfi_excise().band_mask(cfg.muos_bands, cfg.freq_hz, cfg.fs, npts);

    [i0,q0,i1,q1] = gen_iq(npts*ns, 202);
    base = "UHF_20260101120000";
    write_capture(cfg.data_dir, base, i0, q0, i1, q1);

    compute_L1(cfg);

    none_csv  = fullfile(d, 'BrundageSoOp_L1_sig.csv');
    notch_csv = fullfile([d '_notch'], 'BrundageSoOp_L1_sig.csv');
    verifyTrue(tc, isfile(none_csv)  && isfile(notch_csv), 'both method dirs expected');
    Tn = readtable(none_csv,  'TextType', 'string');
    Tx = readtable(notch_csv, 'TextType', 'string');

    ch0 = double(i0) + 1i*double(q0);
    ch1 = double(i1) + 1i*double(q1);

    % 'none' dir == no-excision expectation.
    [p0, p0m] = expected_pow(ch0, win, npts, ns, mask);
    verifyEqual(tc, Tn.pow_ch0_fd,      p0,  'RelTol', 1e-10);
    verifyEqual(tc, Tn.pow_ch0_fd_muos, p0m, 'RelTol', 1e-10);

    % 'notch' dir == expectation built with rfi_excise's OWN prepare/apply.
    [q0e, q0me] = expected_pow_notch(ch0, win, npts, ns, mask, cfg);
    [q1e, q1me] = expected_pow_notch(ch1, win, npts, ns, mask, cfg);
    verifyEqual(tc, Tx.pow_ch0_fd,      q0e,  'RelTol', 1e-10);
    verifyEqual(tc, Tx.pow_ch0_fd_muos, q0me, 'RelTol', 1e-10);
    verifyEqual(tc, Tx.pow_ch1_fd,      q1e,  'RelTol', 1e-10);
    verifyEqual(tc, Tx.pow_ch1_fd_muos, q1me, 'RelTol', 1e-10);

    % The notch actually changed the in-band energy (lower than 'none').
    verifyLessThan(tc, Tx.pow_ch0_fd, Tn.pow_ch0_fd);
end


% =========================================================================
% C. Schema migration + interrupted-recovery
% =========================================================================
function test_L1_migration_chanpow(tc)
% A sig CSV that HAS peak_phase_deg_fd but LACKS the four pow columns is archived
% (_pre_chanpow_<stamp>) and the season reprocessed so the regenerated CSV has
% all four pow columns.
    [cfg, d] = l1_cfg(tc);
    write_gen(cfg.data_dir, "UHF_20260101120000", cfg, 11);
    write_gen(cfg.data_dir, "UHF_20260101130000", cfg, 12);

    compute_L1(cfg);                             % valid full-schema CSV
    csv = fullfile(d, 'BrundageSoOp_L1_sig.csv');
    T0  = readtable(csv, 'TextType', 'string');
    n0  = height(T0);

    % Drop the four pow columns -> pre-channel-power ("old") schema.
    T_old = drop_cols(T0, {'pow_ch0_fd','pow_ch0_fd_muos','pow_ch1_fd','pow_ch1_fd_muos'});
    writetable(T_old, csv);

    compute_L1(cfg);                             % should migrate + reprocess

    arch = dir(fullfile(d, 'BrundageSoOp_L1_sig_pre_chanpow_*.csv'));
    verifyEqual(tc, numel(arch), 1);
    verifyMatches(tc, arch(1).name, 'BrundageSoOp_L1_sig_pre_chanpow_\d{8}_\d{6}\.csv');
    T1 = readtable(csv, 'TextType', 'string');
    verifyTrue(tc, has_pow_cols(T1));
    verifyEqual(tc, height(T1), n0);
end

function test_L1_migration_partial_schema(tc)
% A PARTIAL channel-power schema (only pow_ch0_fd present) still counts as
% missing -> archived and reprocessed to the full four columns.
    [cfg, d] = l1_cfg(tc);
    write_gen(cfg.data_dir, "UHF_20260101120000", cfg, 21);

    compute_L1(cfg);
    csv = fullfile(d, 'BrundageSoOp_L1_sig.csv');
    T0  = readtable(csv, 'TextType', 'string');

    % Keep only pow_ch0_fd of the four pow columns.
    T_part = drop_cols(T0, {'pow_ch0_fd_muos','pow_ch1_fd','pow_ch1_fd_muos'});
    writetable(T_part, csv);

    compute_L1(cfg);

    arch = dir(fullfile(d, 'BrundageSoOp_L1_sig_pre_chanpow_*.csv'));
    verifyEqual(tc, numel(arch), 1, 'partial schema should still archive');
    verifyTrue(tc, has_pow_cols(readtable(csv, 'TextType', 'string')));
end

function test_L1_migration_mixed_methods(tc)
% Mixed method dirs: base dir OLD schema, notch dir NEW schema. Only the base
% dir is archived + reprocessed; the up-to-date notch dir is left untouched.
    [cfg, d] = l1_cfg(tc);
    cfg.rfi_methods = {'none', 'notch_interp'};
    cfg.rfi_bands   = 1e6 * [369.98 370.00];
    write_gen(cfg.data_dir, "UHF_20260101120000", cfg, 31);

    compute_L1(cfg);                             % both dirs valid + up to date
    base_csv  = fullfile(d, 'BrundageSoOp_L1_sig.csv');
    notch_csv = fullfile([d '_notch'], 'BrundageSoOp_L1_sig.csv');

    % Corrupt ONLY the base dir (drop pow columns).
    Tb = drop_cols(readtable(base_csv, 'TextType', 'string'), ...
                   {'pow_ch0_fd','pow_ch0_fd_muos','pow_ch1_fd','pow_ch1_fd_muos'});
    writetable(Tb, base_csv);

    compute_L1(cfg);

    base_arch  = dir(fullfile(d,            'BrundageSoOp_L1_sig_pre_*.csv'));
    notch_arch = dir(fullfile([d '_notch'], 'BrundageSoOp_L1_sig_pre_*.csv'));
    verifyEqual(tc, numel(base_arch),  1, 'base dir should be archived');
    verifyEqual(tc, numel(notch_arch), 0, 'up-to-date notch dir must not archive');
    % Both dirs end with the full four-column schema.
    verifyTrue(tc, has_pow_cols(readtable(base_csv,  'TextType', 'string')));
    verifyTrue(tc, has_pow_cols(readtable(notch_csv, 'TextType', 'string')));
end

function test_L1_interrupted_recovery(tc)
% Incremental recovery: after a valid full-schema CSV, dropping the last row
% (as a killed mid-append run would) is repaired by re-running — the missing
% pair is reprocessed and appended, with NO archive (schema already complete).
    [cfg, d] = l1_cfg(tc);
    write_gen(cfg.data_dir, "UHF_20260101120000", cfg, 41);
    write_gen(cfg.data_dir, "UHF_20260101130000", cfg, 42);

    compute_L1(cfg);
    csv = fullfile(d, 'BrundageSoOp_L1_sig.csv');
    T0  = readtable(csv, 'TextType', 'string');
    verifyEqual(tc, height(T0), 2);

    % Simulate a truncated last append: drop the last row and re-run.
    writetable(T0(1:end-1, :), csv);
    compute_L1(cfg);

    T1 = readtable(csv, 'TextType', 'string');
    verifyEqual(tc, height(T1), 2, 'missing pair should be re-appended');
    verifyEqual(tc, sort(T1.base_name), sort(T0.base_name));
    verifyEqual(tc, numel(dir(fullfile(d, 'BrundageSoOp_L1_sig_pre_*.csv'))), 0, ...
        'incremental append must NOT archive');
end


% =========================================================================
% D. Pipeline dispatch smoke (run_sigma0 only)
% =========================================================================
function test_pipeline_dispatch_sigma0_only(tc)
% soop_run_pipeline with only run_sigma0 = true runs compute_sigma0 once per
% method dir (output CSVs in both the base and _notch dirs) and starts NO
% parpool (the pool block only fires for L1/calib/snr/rfi).
    verifyEmpty(tc, gcp('nocreate'), 'precondition: no pool before the pipeline');

    d = tempname;  mkdir(d);  tc.addTeardown(@() rmdir_safe(d));
    notch_d = [d '_notch'];  mkdir(notch_d);  tc.addTeardown(@() rmdir_safe(notch_d));

    elev_path = fullfile(d, 'muos_elev.csv');
    t0 = datetime(2026,1,1,0,0,0);
    write_sigma0_inputs(d,       t0);
    write_sigma0_inputs(notch_d, t0);
    write_csv_ts(elev_path, elev_tbl(t0));

    cfg = struct();
    cfg.out_dir     = d;
    cfg.rfi_methods = {'none', 'notch_interp'};
    cfg.use_gpu     = false;
    cfg.freq_hz     = 370e6;
    cfg.fs          = 2e6;
    cfg.Ti          = 0.001;
    cfg.num_segs    = 2;
    cfg.tower_h_m   = 6.096;
    cfg.capture_tz  = 'UTC';
    cfg.elev_table  = elev_path;
    cfg.muos_bands  = 1e6 * [369.5 370.5];

    toggles = struct('run_L1', false, 'run_calib', false, 'run_snr', false, ...
                     'run_satid', false, 'run_L2', false, 'run_rfi', false, ...
                     'run_sigma0', true);

    soop_run_pipeline(cfg, toggles);

    verifyTrue(tc, isfile(fullfile(d,       'BrundageSoOp_sigma0.csv')), ...
        'compute_sigma0 did not run in the base method dir');
    verifyTrue(tc, isfile(fullfile(notch_d, 'BrundageSoOp_sigma0.csv')), ...
        'compute_sigma0 did not run in the notch method dir');
    verifyEmpty(tc, gcp('nocreate'), 'sigma0-only pipeline must not start a pool');
end


% =========================================================================
% Local helpers
% =========================================================================
function [cfg, d] = l1_cfg(tc)
% Minimal compute_L1 cfg over a fresh temp data/out dir pair. npts = 1000, two
% segments; an in-band single-block muos_bands; overflow_file omitted (rows get
% overflow_flag = 0 with a warning). Teardown removes the dirs (incl. _notch).
    d    = tempname;   mkdir(d);
    data = tempname;   mkdir(data);
    tc.addTeardown(@() rmdir_safe(d));
    tc.addTeardown(@() rmdir_safe([d '_notch']));   % created only if notch method runs
    tc.addTeardown(@() rmdir_safe(data));

    cfg = struct();
    cfg.data_dir     = data;
    cfg.out_dir      = d;
    cfg.fs           = 1e5;
    cfg.Ti           = 0.01;                     % npts = 1000
    cfg.num_segs     = 2;
    cfg.peak_lag     = 0;
    cfg.lag_half_win = 50;
    cfg.min_bytes    = 1000*2*4;                 % npts*num_segs complex int16 (bytes)
    cfg.batch_size   = 200;
    cfg.use_gpu      = false;
    cfg.freq_hz      = 370e6;
    cfg.rfi_methods  = {'none'};
    cfg.rfi_bands    = [];
    cfg.muos_bands   = 1e6 * [369.97 370.03];    % in-band (fs = 100 kHz)
end

function rmdir_safe(dd)
    if isfolder(dd), rmdir(dd, 's'); end
end

function [i0,q0,i1,q1] = gen_iq(nsamp, seed)
% Deterministic int16 I/Q for a ch0/ch1 pair, amplitude well inside the sc16
% range (|.| <= 1000) so a 2x scaling test never clips.
    if nargin < 2, seed = 1; end
    rng(seed);
    amp = 1000;
    i0 = int16(round(amp*(2*rand(nsamp,1)-1)));
    q0 = int16(round(amp*(2*rand(nsamp,1)-1)));
    i1 = int16(round(amp*(2*rand(nsamp,1)-1)));
    q1 = int16(round(amp*(2*rand(nsamp,1)-1)));
end

function write_gen(dir_, base, cfg, seed)
% Generate + write one pair sized to npts*num_segs samples per channel (so it
% clears the cfg.min_bytes size gate) for the tests that don't need the raw I/Q.
    nsamp = floor(cfg.fs*cfg.Ti) * cfg.num_segs;
    [i0,q0,i1,q1] = gen_iq(nsamp, seed);
    write_capture(dir_, base, i0, q0, i1, q1);
end

function write_capture(dir_, base, i0, q0, i1, q1)
% Write an interleaved-I/Q int16 ch0/ch1 pair named <base>_ch0.dat/_ch1.dat.
    write_ch(fullfile(dir_, char(base) + "_ch0.dat"), i0, q0);
    write_ch(fullfile(dir_, char(base) + "_ch1.dat"), i1, q1);
end

function write_ch(path, I, Q)
% File layout [I0 Q0 I1 Q1 ...] int16, matching compute_L1's read_channel.
    n = numel(I);
    buf = zeros(2*n, 1, 'int16');
    buf(1:2:end) = I;
    buf(2:2:end) = Q;
    fid = fopen(path, 'w');
    fwrite(fid, buf, 'int16');
    fclose(fid);
end

function [pfd, pmuos] = expected_pow(ch, win, npts, n_segs, mask)
% Hand-computed windowed band powers matching compute_L1:
%   P_avg = (1/n_segs) sum_seg |fft(win.*seg)|^2 ; pow = sum(P_avg)/npts^2.
    Psum = zeros(npts, 1);
    for s = 1:n_segs
        xs   = ch((s-1)*npts + (1:npts)) .* win;
        Psum = Psum + abs(fft(xs)).^2;
    end
    Pavg  = Psum / n_segs;
    pfd   = sum(Pavg)       / npts^2;
    pmuos = sum(Pavg(mask)) / npts^2;
end

function [pfd, pmuos] = expected_pow_notch(ch, win, npts, n_segs, mask, cfg)
% As expected_pow, but with the RFI-excision operator applied to each segment's
% spectrum using rfi_excise's OWN prepare/apply (operator-consistency).
    E = rfi_excise();
    P = E.prepare(cfg, npts);
    Psum = zeros(npts, 1);
    for s = 1:n_segs
        F  = fft(ch((s-1)*npts + (1:npts)) .* win);
        Fm = E.apply(F, 'notch_interp', P);
        Psum = Psum + abs(Fm).^2;
    end
    Pavg  = Psum / n_segs;
    pfd   = sum(Pavg)       / npts^2;
    pmuos = sum(Pavg(mask)) / npts^2;
end

function w = hann_local(npts)
% Hanning window matching compute_L1 / numpy.hanning(npts).
    n = (0:npts-1)';
    w = 0.5 * (1 - cos(2*pi*n / (npts-1)));
end

function T = drop_cols(T, cols)
    T = T(:, ~ismember(T.Properties.VariableNames, cols));
end

function tf = has_pow_cols(T)
    tf = all(ismember({'pow_ch0_fd','pow_ch0_fd_muos','pow_ch1_fd','pow_ch1_fd_muos'}, ...
                      T.Properties.VariableNames));
end

function write_sigma0_inputs(dir_, t0)
% Write a clean 6-capture L1/L2/calib fixture (fd_muos family) into dir_ so
% compute_sigma0 produces an output CSV there.
    off_h = (0:5)' * 0.4;
    N = numel(off_h);
    t = t0 + hours(off_h);
    bn = "cap" + string((1:N)');
    L1 = table(t, bn, repmat(1000,N,1), repmat(1e6,N,1), repmat(1e5,N,1), ...
        'VariableNames', {'timestamp','base_name','peak_amplitude_fd_muos', ...
                          'pow_ch0_fd_muos','pow_ch1_fd_muos'});
    L2 = table(t, bn, repmat(40,N,1), linspace(0,60,N)', ...
        'VariableNames', {'timestamp','base_name','theta_deg','phase_corr_cal_fd_muos_deg'});
    CAL = table(t, repmat(100,N,1), repmat(50,N,1), ones(N,1), zeros(N,1), ...
        'VariableNames', {'timestamp','G_De','G_Re','P_DN','overflow_flag'});
    write_csv_ts(fullfile(dir_, 'BrundageSoOp_L1_sig.csv'), L1);
    write_csv_ts(fullfile(dir_, 'BrundageSoOp_L2.csv'),     L2);
    write_csv_ts(fullfile(dir_, 'BrundageSoOp_calib.csv'),  CAL);
end

function ELEV = elev_tbl(t0)
    et = t0 + hours((-1:0.5:5)');
    n  = numel(et);
    ELEV = table(et, repmat(40,n,1), repmat(180,n,1), repmat(37000,n,1), ...
        'VariableNames', {'timestamp','elevation_deg','azimuth_deg','range_km'});
end

function write_csv_ts(path, T)
% Write a fixture table with the ISO timestamp format the stages parse on read.
    if ismember('timestamp', T.Properties.VariableNames) && isdatetime(T.timestamp)
        T.timestamp.Format = 'yyyy-MM-dd HH:mm:ss';
    end
    writetable(T, path);
end

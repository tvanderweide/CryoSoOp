function compute_L2(cfg)
% L2: remove the satellite-elevation geometric phase from the L1 series.
%
% Model (theory doc / ElevCorr): the direct-vs-reflected path difference
% is 2*h*sin(theta), so the geometric phase is
%     phi_geom(t) = (4*pi*h / lambda) * sin(theta(t))     [converted to deg]
% and the corrected observable is wrap180(phase_raw - phi_geom). As snow
% accumulates, the residual corrected phase tracks the snow-induced path
% change instead of satellite motion.
%
% Inputs: cfg.out_dir/BrundageSoOp_L1_sig.csv (L1 products), cfg.elev_table
% (elevation CSV for the CONFIRMED satellite — make_muos_elevation.py; run
% compare_sat_candidates first if the satellite is still unconfirmed),
% cfg.tower_h_m, cfg.freq_hz, cfg.capture_tz.
%
% Output: cfg.out_dir/BrundageSoOp_L2.csv — one row per L1 capture:
%   timestamp, base_name, theta_deg, az_deg, phase_raw_deg, phase_geom_deg,
%   phase_corr_deg, snr_db (carried through for thresholding), plus the
%   frequency-domain variants phase_raw_fd_deg / phase_corr_fd_deg (full band)
%   and phase_raw_fd_muos_deg / phase_corr_fd_muos_deg (MUOS sub-channels). The
%   geometric correction is shared; only the L1 phase differs across variants.
%
% Chain-phase calibration columns (schema 2026-07-17, session-keyed):
% phase_chain_deg is the per-UHD-session receiver-chain differential phase
% from the same product dir's calib CSV, using the correlated-baseline-
% cancelled estimator angle(C_RDNS - C_RDL) — the NL and L states share the
% injection path AND a correlated inter-channel baseline (measured
% rho_DRL ~ 0.2), so the complex difference cancels the baseline and isolates
% the noise-diode path. Sessions come from the schema-v6 session_id sentinels
% (lib/session_key.m): run-folder-keyed captures join their own session's
% calib run by EXACT identity (no time limit — elapsed time is diagnostic
% only); "legacy-flat" captures keep the historical nearest-gap-run join
% within chain_join_tol_min; "unknown" provenance and keyed captures with no
% same-session calib get NaN (never a neighbor's phase). chain_session
% records the association per row. phase_corr_cal_deg (+_fd/_fd_muos)
% = wrap180(phase_corr* - phase_chain_deg): FULL per-session subtraction,
% gr-doa-style common-reference zeroing at the injection plane, with no
% reference constant (chain_phase_ref_deg retired 2026-07-17 — ignored if a
% caller still sets it; the -81.4/0 anchor history:
% docs/config-reference.md#chain-cal-knobs). The chain phase is treated as
% FREQUENCY-FLAT across the sinc/fd/fd_muos domains (accepted 2026-07-17 —
% see the note at the application site below).
%
% Incremental: appends only captures not already in the L2 CSV; a schema
% change (new az_deg / fd / chain-cal / chain_session columns) archives the
% whole CSV and reprocesses all captures (cheap — just interpolation), so
% the appended rows stay column-aligned. Chain-cal dependency gate (checked
% BEFORE the incremental filter): the config/algorithm stamp
% (BrundageSoOp_L2_chaincal_stamp.json) must match AND every existing row's
% freshly recomputed chain association (phase + session) must equal what it
% has stored — so config/reference changes, shifted run means, newly USABLE
% calibration (e.g. after the v6 migration), and repaired session_id values
% all force a full rebuild; a rebuild also renames any sigma0 product aside
% (_stale_*). Captures outside the elevation table's time span get theta =
% NaN and are skipped with a message (extend the table rather than
% extrapolating).
%
% Timezone: cfg.capture_tz names the timebase of the capture filename
% stamps; the elevation table is UTC. Legacy 2025-26 data used the Pi's
% LOCAL clock ('America/Boise', verified via timedatectl 2026-06-12) and
% the conversion below handles MST/MDT including the March DST change.
% cryosoop builds from 2026-07 on stamp UTC in code — capture_tz "UTC"
% makes to_utc an exact identity. If cfg.capture_tz is absent,
% timestamps are assumed to already be UTC.
%

    sig_csv = fullfile(cfg.out_dir, 'BrundageSoOp_L1_sig.csv');
    out_csv = fullfile(cfg.out_dir, 'BrundageSoOp_L2.csv');

    if ~isfile(sig_csv)
        fprintf('[L2] %s not found — run compute_L1 first.\n', sig_csv);
        return;
    end
    if ~isfield(cfg, 'elev_table') || ~isfile(cfg.elev_table)
        fprintf(['[L2] Elevation table not found (cfg.elev_table) — run ' ...
                 'make_muos_elevation.py for the confirmed satellite.\n']);
        return;
    end

    T = readtable(sig_csv, 'TextType', 'string');
    if ~isdatetime(T.timestamp)
        T.timestamp = datetime(T.timestamp, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
    end

    % Exclude overflow-flagged captures: UHD sample drops break inter-channel
    % phase coherence and corrupt the phase observable.
    if ismember('overflow_flag', T.Properties.VariableNames)
        n_ovf = sum(T.overflow_flag ~= 0);
        if n_ovf > 0
            fprintf('[L2] Excluding %d overflow-flagged captures from phase series.\n', n_ovf);
        end
        T = T(T.overflow_flag == 0, :);
    else
        fprintf(['[L2] WARNING: overflow_flag column absent from %s — all captures ' ...
                 'included. Re-run compute_L1 to add overflow flags.\n'], sig_csv);
    end

    % --- Chain-cal inputs, computed up front: the dependency gate below must
    %     see the run table BEFORE the incremental existing-base filter. ---
    % Chain-cal knobs, both overridable from cfg (docs/config-reference.md#chain-cal-knobs).
    % There is NO reference knob: the per-session chain phase is subtracted in
    % full (chain_phase_ref_deg retired 2026-07-17; the field is ignored if a
    % caller still sets it).
    chain_gap_min = getfield_default(cfg, 'chain_run_gap_min',  20);
    chain_tol_min = getfield_default(cfg, 'chain_join_tol_min', 60);
    R = chain_phase_runs(fullfile(cfg.out_dir, 'BrundageSoOp_calib.csv'), chain_gap_min);
    stamp_path = fullfile(cfg.out_dir, 'BrundageSoOp_L2_chaincal_stamp.json');
    % algo_version 2 (2026-07-17): the no-reference stamp schema — v1 stamps
    % (which carried chain_phase_ref_deg) mismatch and rebuild once.
    stamp_now  = struct('algo_version', 2, ...
                        'chain_run_gap_min',  chain_gap_min, ...
                        'chain_join_tol_min', chain_tol_min, ...
                        'runs', runs_struct(R));

    % --- Chain-phase join, computed for EVERY capture up front ---
    % The incremental gate below compares these fresh associations against
    % the stored rows, so a change in what any existing row WOULD get —
    % newly usable calibration, a repaired session_id, a shifted run mean —
    % forces a rebuild instead of leaving stale values behind.
    [phase_chain, chain_session] = chain_join(T, R, chain_tol_min, cfg.out_dir);

    % Incremental + schema upkeep (see header) — skip captures already in the
    % L2 CSV only when (a) the CSV is current-schema, (b) the chain-cal
    % config/algorithm stamp is unchanged, and (c) every existing row's
    % freshly recomputed chain association (phase + session, NaN-safe)
    % matches what it has stored. Anything else archives the CSV, renames any
    % sigma0 product aside, and reprocesses all captures (cheap).
    if isfile(out_csv)
        prev = readtable(out_csv, 'TextType', 'string');
        pv   = prev.Properties.VariableNames;
        if ~ismember('chain_session', pv)
            if ismember('phase_chain_deg', pv)
                tag = "_no_chainsession_";
                why = 'the chain_session / session-keyed schema (2026-07-17)';
            elseif ismember('phase_corr_fd_deg', pv)
                tag = "_no_chaincal_";
                why = 'the chain-phase calibration columns';
            elseif ismember('az_deg', pv)
                tag = "_no_fd_";
                why = 'the frequency-domain phase columns';
            else
                tag = "_no_az_";
                why = 'az_deg';
            end
            archived = archive_name(out_csv, tag);
            movefile(out_csv, archived);
            fprintf('[L2] Existing CSV predates %s — archived to %s; reprocessing all captures.\n', ...
                    why, archived);
            archive_sigma0(cfg.out_dir);
        elseif ~chain_stamp_config_matches(stamp_path, stamp_now) || ...
               ~chain_assoc_matches(prev, T, phase_chain, chain_session)
            archived = archive_name(out_csv, "_chaincal_stale_");
            movefile(out_csv, archived);
            fprintf(['[L2] Chain-cal dependency changed (config/reference, algorithm, ' ...
                     'or the association an existing row would now get) — archived ' ...
                     'to %s; reprocessing all captures.\n'], archived);
            archive_sigma0(cfg.out_dir);
        else
            keep = ~ismember(T.base_name, prev.base_name);
            T             = T(keep, :);
            phase_chain   = phase_chain(keep);
            chain_session = chain_session(keep);
        end
    end
    if isempty(T)
        fprintf('[L2] No new captures to correct.\n');
        return;
    end

    E = readtable(cfg.elev_table, 'TextType', 'string');
    if ~isdatetime(E.timestamp)
        E.timestamp = datetime(E.timestamp, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
    end

    % Capture clock -> UTC, then interpolate elevation/azimuth at capture times.
    t_utc = to_utc(T.timestamp, cfg);
    theta = interp1(E.timestamp, E.elevation_deg, t_utc, 'linear', NaN);
    % Azimuth from the same ephemeris table. Linear interpolation is valid
    % because the GEO satellite's azimuth varies only a few degrees per day and
    % never crosses the 0/360 wrap from this site.
    if ismember('azimuth_deg', E.Properties.VariableNames)
        az = interp1(E.timestamp, E.azimuth_deg, t_utc, 'linear', NaN);
    else
        az = nan(height(T), 1);
        fprintf('[L2] WARNING: azimuth_deg absent from %s — az_deg will be NaN.\n', ...
                cfg.elev_table);
    end

    ok = isfinite(theta);
    if any(~ok)
        fprintf('[L2] %d captures outside the elevation table span — skipped.\n', ...
                sum(~ok));
    end
    T = T(ok, :);
    theta = theta(ok);
    az = az(ok);
    phase_chain = phase_chain(ok);
    chain_session = chain_session(ok);
    if isempty(T)
        fprintf('[L2] No captures within the elevation table span.\n');
        return;
    end

    lambda_m   = 299792458 / cfg.freq_hz;
    phase_geom = (4*pi * cfg.tower_h_m / lambda_m) * (180/pi) .* sind(theta);
    phase_corr = wrap180(T.peak_phase_deg - phase_geom);

    % Frequency-domain phase variants (added alongside the sinc phase_corr_deg).
    % The geometric correction is identical (geometry-only); only the L1 phase
    % differs. NaN-filled if compute_L1 has not yet written the fd columns.
    if ~ismember('peak_phase_deg_fd', T.Properties.VariableNames)
        fprintf(['[L2] WARNING: L1 lacks peak_phase_deg_fd — fd / freq_muos columns ' ...
                 'will be NaN. Re-run compute_L1 for the frequency-domain phase.\n']);
    end
    [phase_raw_fd,      phase_corr_fd]      = corr_variant(T, 'peak_phase_deg_fd',      phase_geom);
    [phase_raw_fd_muos, phase_corr_fd_muos] = corr_variant(T, 'peak_phase_deg_fd_muos', phase_geom);

    % --- Receiver chain-phase calibration application ---
    % phase_chain / chain_session were computed for the FULL capture set by
    % chain_join() before the incremental gate (and filtered alongside T), so
    % here they are simply applied.
    % SIGN: compute_L1 and compute_calib share the D.*conj(R) convention
    % (unified 2026-07-06), so subtracting the calib chain phase removes the
    % receiver-chain differential from the signal phase directly, IN FULL —
    % the corrected phase is zeroed at the calibration injection reference
    % plane using only the capture's own session. There is no reference
    % constant (chain_phase_ref_deg retired 2026-07-17; history in
    % docs/config-reference.md#chain-cal-knobs).
    % FREQUENCY-FLAT ASSUMPTION (accepted 2026-07-17): one full-band, lag-zero
    % chain phase is applied to all three phase domains (sinc / fd / fd_muos).
    % Revisit via the nl_peak_lag / l_peak_lag diagnostics if a differential
    % group delay or band-dependent chain response is ever suspected; known
    % caveat — the notch method's state-specific NL/L RFI operators degrade the
    % baseline cancellation (~0.5 vs ~0.1 deg season scatter), accepted.
    corr_cal         = wrap180(phase_corr         - phase_chain);
    corr_cal_fd      = wrap180(phase_corr_fd      - phase_chain);
    corr_cal_fd_muos = wrap180(phase_corr_fd_muos - phase_chain);

    out = table(T.timestamp, T.base_name, theta, az, T.peak_phase_deg, ...
                wrap180(phase_geom), phase_corr, T.snr_db, ...
                phase_raw_fd, phase_corr_fd, phase_raw_fd_muos, phase_corr_fd_muos, ...
                phase_chain, corr_cal, corr_cal_fd, corr_cal_fd_muos, ...
                chain_session, ...
                'VariableNames', {'timestamp', 'base_name', 'theta_deg', 'az_deg', ...
                'phase_raw_deg', 'phase_geom_deg', 'phase_corr_deg', 'snr_db', ...
                'phase_raw_fd_deg', 'phase_corr_fd_deg', ...
                'phase_raw_fd_muos_deg', 'phase_corr_fd_muos_deg', ...
                'phase_chain_deg', 'phase_corr_cal_deg', ...
                'phase_corr_cal_fd_deg', 'phase_corr_cal_fd_muos_deg', ...
                'chain_session'});

    if isfile(out_csv)
        writetable(out, out_csv, 'WriteMode', 'append', 'WriteVariableNames', false);
    else
        % Fresh (rebuild) writes go through a temp file + rename so an
        % interrupted rebuild leaves only the archive, never a torn CSV.
        tmp = strrep(out_csv, '.csv', '_build_tmp.csv');
        writetable(out, tmp);
        movefile(tmp, out_csv);
    end
    % Record the chain-cal dependency state the rows above were computed from
    % (checked against a recomputation before the next incremental append).
    write_chain_stamp(stamp_path, stamp_now);
    fprintf('[L2] %d captures corrected (theta %.2f-%.2f deg) → %s\n', ...
            height(out), min(theta), max(theta), out_csv);
end


% =========================================================================
function y = wrap180(x)
    y = mod(x + 180, 360) - 180;
end

function [raw, corr] = corr_variant(T, col, phase_geom)
% L1 phase column `col` and its elevation-corrected wrap180(col - phase_geom),
% sharing the geometry-only phase_geom. NaN-filled if `col` is absent (L1 not
% yet reprocessed for the frequency-domain phase).
    if ismember(col, T.Properties.VariableNames)
        raw  = T.(col);
        corr = wrap180(raw - phase_geom);
    else
        raw  = nan(height(T), 1);
        corr = nan(height(T), 1);
    end
end


function R = chain_phase_runs(calib_csv, gap_min)
% Per-run receiver-chain differential phase from the calib CSV, using the
% correlated-baseline-cancelled estimator angle(C_RDNS - C_RDL). The NL and L
% states share the injection path and a correlated inter-channel baseline
% (measured rho_DRL ~ 0.2: receiver-internal common-mode leakage and/or
% shared-load correlated noise), so the complex difference cancels that
% baseline and isolates the noise-diode path (assumes the baseline is
% stationary between the paired NL and L captures).
%
% Run identity (session-keyed, 2026-07-17): pairs with a run-folder session
% key form one run per exact key (one cryosoop folder == one UHD session);
% "legacy-flat" pairs are grouped by >gap_min time gaps with run key
% "gap:<mean time>"; "unknown"-provenance pairs are EXCLUDED (fail closed).
% Overflow-flagged pairs are excluded. Each run reduces to an equal-weight
% circular mean, timestamped at the run's mean capture time (capture-local,
% same timebase as the L1 rows).
%
% Returns table R with columns: key (string), t (datetime), ph (deg),
% n (pair count) — empty if the CSV or its required columns are missing.
    R = table(strings(0, 1), datetime.empty(0, 1), zeros(0, 1), zeros(0, 1), ...
              'VariableNames', {'key', 't', 'ph', 'n'});
    if ~isfile(calib_csv), return; end
    C = readtable(calib_csv, 'TextType', 'string');
    need = {'timestamp', 'C_RDNS_amp', 'C_RDNS_phase_deg', ...
            'C_RDL_amp', 'C_RDL_phase_deg'};
    if ~all(ismember(need, C.Properties.VariableNames)), return; end
    if ~ismember('session_id', C.Properties.VariableNames)
        fprintf(['[L2] WARNING(chaincal-prov): calib CSV has no session_id ' ...
                 'column — chain calibration disabled (NaN columns). Re-run ' ...
                 'compute_calib (schema v6 migration) with cfg.data_dir reachable.\n']);
        return;
    end
    if ~isdatetime(C.timestamp)
        C.timestamp = datetime(C.timestamp, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
    end
    if ismember('overflow_flag', C.Properties.VariableNames)
        C = C(C.overflow_flag == 0, :);
    end
    [C.session_id, n_bad] = norm_sentinels(C.session_id);
    if n_bad > 0
        fprintf(['[L2] WARNING(chaincal-prov): %d calib pair(s) with malformed ' ...
                 'session_id treated as unknown.\n'], n_bad);
    end
    n_unk = sum(C.session_id == "unknown");
    if n_unk > 0
        fprintf(['[L2] WARNING(chaincal-prov): %d calib pair(s) with unknown ' ...
                 'session provenance excluded from chain cal.\n'], n_unk);
    end
    C = sortrows(C(C.session_id ~= "unknown", :), 'timestamp');
    if isempty(C), return; end
    z  = C.C_RDNS_amp .* exp(1i * deg2rad(C.C_RDNS_phase_deg)) ...
       - C.C_RDL_amp  .* exp(1i * deg2rad(C.C_RDL_phase_deg));
    zu = z ./ max(abs(z), eps);    % unit vectors -> equal-weight circular mean
    % Keyed sessions: one run per exact key.
    km = C.session_id ~= "legacy-flat";
    if any(km)
        [keys, ~, kg] = unique(C.session_id(km));
        Rk = run_reduce(kg, zu(km), C.timestamp(km));
        Rk.key = keys;
        R = [R; Rk(:, {'key', 't', 'ph', 'n'})];
    end
    % Legacy-flat: chronological gap split, key "gap:<mean time>".
    lm = ~km;
    if any(lm)
        tl  = C.timestamp(lm);
        lg  = cumsum([true; diff(tl) > minutes(gap_min)]);
        Rg  = run_reduce(lg, zu(lm), tl);
        Rg.key = "gap:" + string(Rg.t, 'yyyy-MM-dd HH:mm:ss');
        R = [R; Rg(:, {'key', 't', 'ph', 'n'})];
    end
    R = sortrows(R, 't');
end


function Rr = run_reduce(grp, zu, ts)
% Equal-weight circular mean + mean time + pair count per run group.
    n  = accumarray(grp, 1);
    ph = rad2deg(atan2(accumarray(grp, imag(zu)), accumarray(grp, real(zu))));
    t  = datetime(accumarray(grp, posixtime(ts)) ./ n, 'ConvertFrom', 'posixtime');
    Rr = table(t, ph, n, 'VariableNames', {'t', 'ph', 'n'});
end


function s = session_sentinels(T)
% Normalized session sentinels for the L1 signal rows; a missing column means
% the CSV predates schema v6 -> every row "unknown" (chain cal fails closed).
    if ~ismember('session_id', T.Properties.VariableNames)
        fprintf(['[L2] WARNING(chaincal-prov): L1 CSV has no session_id column ' ...
                 '— chain calibration disabled (NaN columns). Re-run compute_L1 ' ...
                 '(schema v6 migration) with cfg.data_dir reachable.\n']);
        s = repmat("unknown", height(T), 1);
        return;
    end
    [s, n_bad] = norm_sentinels(T.session_id);
    if n_bad > 0
        fprintf(['[L2] WARNING(chaincal-prov): %d signal row(s) with malformed ' ...
                 'session_id treated as unknown.\n'], n_bad);
    end
end


function [s, n_bad] = norm_sentinels(raw)
% Canonicalize persisted session sentinels (schema v6) on the CSV read path:
% trim, '\' -> '/', case-normalize the reserved sentinels, and validate the
% "<YYYYMMDD>/<HHMMSS>" run-key shape. Anything else is malformed and fails
% closed to "unknown" — session_key.m guarantees canonical values at write
% time, but hand-edited or foreign CSVs must not be trusted as keys.
    s = strtrim(string(raw));
    s = strrep(s, '\', '/');
    s(ismissing(s) | s == "") = "unknown";
    s(strcmpi(s, "legacy-flat")) = "legacy-flat";
    s(strcmpi(s, "unknown"))     = "unknown";
    keyish = ~ismember(s, ["legacy-flat", "unknown"]);
    okkey  = ~cellfun(@isempty, regexp(cellstr(s), '^\d{8}/\d{6}$', 'once'));
    bad    = keyish & ~okkey(:);
    n_bad  = sum(bad);
    s(bad) = "unknown";
end


function runs = runs_struct(R)
% Chain-run table -> plain struct array for the JSON dependency stamp.
    runs = struct('key', {}, 't', {}, 'ph_deg', {}, 'n', {});
    for k = 1:height(R)
        runs(k).key    = char(R.key(k));
        runs(k).t      = char(string(R.t(k), 'yyyy-MM-dd HH:mm:ss'));
        runs(k).ph_deg = R.ph(k);
        runs(k).n      = R.n(k);
    end
end


function [phase_chain, chain_session] = chain_join(T, R, chain_tol_min, out_dir)
% Session-keyed chain-phase join over the FULL capture table (2026-07-17).
% Signal rows with a run-folder session key join their own UHD session's
% calib run by exact identity — same session is definitionally correct, so
% elapsed time is a diagnostic only. "legacy-flat" rows keep the historical
% nearest-gap-run join within chain_tol_min. "unknown" provenance and keyed
% rows with no same-session calib get NaN — never a neighboring session's
% phase (borrowing across sessions would contradict the session-constant
% offset model this correction rests on).
    sig_sid = session_sentinels(T);
    phase_chain   = nan(height(T), 1);
    chain_session = repmat("", height(T), 1);
    is_gap_run = startsWith(R.key, "gap:");
    Rk = R(~is_gap_run, :);
    Rg = R(is_gap_run,  :);
    is_keyed_sig  = ~ismember(sig_sid, ["legacy-flat", "unknown"]);
    is_legacy_sig = sig_sid == "legacy-flat";
    % Exact-identity join for keyed rows.
    [tf, loc] = ismember(sig_sid, Rk.key);
    tf = tf & is_keyed_sig;
    phase_chain(tf)   = Rk.ph(loc(tf));
    chain_session(tf) = Rk.key(loc(tf));
    tmatch = NaT(height(T), 1);
    tmatch(tf) = Rk.t(loc(tf));
    far = tf & abs(T.timestamp - tmatch) > minutes(chain_tol_min);
    if any(far)
        fprintf(['[L2] WARNING(chaincal-key): %d keyed capture(s) matched their ' ...
                 'session calib run > %d min away — check run-folder integrity.\n'], ...
                sum(far), chain_tol_min);
    end
    % Legacy nearest-gap-run join (time-tolerance gated), gap runs only.
    li = find(is_legacy_sig);
    if ~isempty(li) && ~isempty(Rg)
        if height(Rg) == 1
            idx = ones(numel(li), 1);
        else
            idx = interp1(Rg.t, 1:height(Rg), T.timestamp(li), 'nearest', 'extrap');
        end
        okc = abs(T.timestamp(li) - Rg.t(idx)) <= minutes(chain_tol_min);
        phase_chain(li(okc))   = Rg.ph(idx(okc));
        chain_session(li(okc)) = Rg.key(idx(okc));
    end
    if isempty(R)
        fprintf(['[L2] Chain-phase cal: no usable calib runs in %s — ' ...
                 'phase_chain_deg columns are NaN.\n'], out_dir);
    else
        fprintf(['[L2] Chain-phase cal: %d keyed + %d legacy capture(s) matched ' ...
                 'across %d calib runs; %d keyed unmatched, %d unknown provenance ' ...
                 '(NaN). Full per-session subtraction.\n'], sum(tf), ...
                sum(~isnan(phase_chain)) - sum(tf), height(R), ...
                sum(is_keyed_sig & ~tf), sum(sig_sid == "unknown"));
    end
end


function ok = chain_stamp_config_matches(stamp_path, stamp_now)
% True only if the stored dependency stamp exists, parses, and agrees on the
% algorithm version + chain config. algo_version 2 is the no-reference stamp
% schema (2026-07-17): v1 stamps carried chain_phase_ref_deg and mismatch
% here, forcing the correct one-time rebuild. Calibration-content and
% provenance changes are caught separately by chain_assoc_matches, which
% compares every existing row's freshly recomputed association directly (a
% run-table proxy comparison proved unsafe: it could not see newly USABLE
% calibration — empty-runs stamps or added runs satisfying previously
% unmatched rows).
    ok = false;
    if ~isfile(stamp_path), return; end
    try
        old = jsondecode(fileread(stamp_path));
    catch
        return;
    end
    for f = {'algo_version', 'chain_run_gap_min', 'chain_join_tol_min'}
        if ~isfield(old, f{1}) || ~isnumeric(old.(f{1})) || ~isscalar(old.(f{1})), return; end
    end
    if old.algo_version ~= stamp_now.algo_version, return; end
    if old.chain_run_gap_min  ~= stamp_now.chain_run_gap_min,  return; end
    if old.chain_join_tol_min ~= stamp_now.chain_join_tol_min, return; end
    ok = true;
end


function ok = chain_assoc_matches(prev, T, phase_chain, chain_session)
% True only if every already-written row's freshly recomputed chain
% association equals what it has stored: same phase (NaN == NaN, else 1e-6
% deg) and same chain_session. A prev row whose base_name is no longer in
% the current (overflow-filtered) capture table also fails — its provenance
% changed. This is the dependency check that catches newly usable
% calibration, late-added pairs shifting a session mean, and repaired
% session_id values.
    ok = false;
    [tf, loc] = ismember(prev.base_name, T.base_name);
    if ~all(tf), return; end
    new_ph = phase_chain(loc);
    old_ph = prev.phase_chain_deg;
    ph_ok  = (isnan(old_ph) & isnan(new_ph)) | (abs(old_ph - new_ph) <= 1e-6);
    if ~all(ph_ok), return; end
    old_cs = string(prev.chain_session);
    old_cs(ismissing(old_cs)) = "";
    if ~all(old_cs == chain_session(loc)), return; end
    ok = true;
end


function p = archive_name(out_csv, tag)
% Collision-resistant archive path: date+time stamp, then _2, _3, ... if a
% same-second archive of the same kind already exists (never overwrite an
% earlier recovery copy).
    ds = string(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
    p = strrep(out_csv, '.csv', tag + ds + ".csv");
    k = 1;
    while isfile(p)
        k = k + 1;
        p = strrep(out_csv, '.csv', tag + ds + "_" + k + ".csv");
    end
end


function write_chain_stamp(stamp_path, stamp_now)
% Persist the dependency stamp atomically (temp file + rename).
    txt = jsonencode(stamp_now);
    tmp = [stamp_path '.tmp'];
    fid = fopen(tmp, 'w');
    fwrite(fid, txt);
    fclose(fid);
    movefile(tmp, stamp_path);
end


function archive_sigma0(out_dir)
% A rebuilt L2 invalidates any sigma0 product built from it (compute_sigma0
% consumes the chain-calibrated phase); rename it aside using the same
% _stale_ convention as compute_sigma0's own stale-output guard.
    s0 = fullfile(out_dir, 'BrundageSoOp_sigma0.csv');
    if isfile(s0)
        stale = archive_name(s0, "_stale_");
        movefile(s0, stale);
        fprintf(['[L2] Chain-cal rebuild invalidates the sigma0 product — ' ...
                 'renamed %s -> %s; re-run compute_sigma0.\n'], s0, stale);
    end
end


function v = getfield_default(s, name, default)
% cfg field with fallback when absent/empty (same helper as compute_calib).
    if isfield(s, name) && ~isempty(s.(name)), v = s.(name); else, v = default; end
end

function t_utc = to_utc(t, cfg)
% Convert naive capture timestamps (cfg.capture_tz timebase) to naive UTC.
% Declaring the zone keeps the clock face; switching to UTC converts the
% instant (MST/MDT and the March DST change handled automatically for
% legacy local-clock seasons; exact identity when capture_tz is 'UTC',
% the setting for UTC-stamped cryosoop data).
    if isfield(cfg, 'capture_tz') && ~isempty(cfg.capture_tz)
        t.TimeZone = cfg.capture_tz;
        t.TimeZone = 'UTC';
        t.TimeZone = '';
    end
    t_utc = t;
end

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
% Chain-phase calibration columns (schema 2026-07-04): phase_chain_deg is the
% per-run receiver-chain differential phase from the same product dir's calib
% CSV, using the leak-cancelled estimator angle(C_RDNS - C_RDL) — the NL and L
% states share the injection path AND the receiver-internal common-mode leak,
% so the complex difference cancels the leak (and the small common-load term)
% and isolates the noise-diode path. phase_corr_cal_deg (+_fd/_fd_muos
% variants) = wrap180(phase_corr* - (phase_chain_deg - cfg.chain_phase_ref_deg)).
% SIGN: compute_L1 and compute_calib now share the D.*conj(R) convention
% (unified 2026-07-06), so the calib chain series is the NEGATION of the old
% R.*conj(D) series; the chain term SUBTRACTS and cfg.chain_phase_ref_deg is
% -81.4, so the APPLIED correction stays numerically identical to the pre-
% unification pipeline (the two sign flips cancel). The season chain phase is
% stable to ~0.1-0.5 deg (2025-26 season, checked 2026-07-04), so this
% correction is monitoring/insurance: it absorbs any future chain-phase step
% (UHD/firmware/hardware change) without touching the existing columns.
% Chain-cal knobs (chain_run_gap_min, chain_join_tol_min, chain_phase_ref_deg)
% and the -81.4 deg reference provenance: docs/config-reference.md#chain-cal-knobs.
%
% Incremental: appends only captures not already in the L2 CSV; a schema
% change (new az_deg / fd / chain-cal columns) archives the whole CSV and
% reprocesses all captures (cheap — just interpolation), so the appended
% rows stay column-aligned. Captures outside the elevation table's time
% span get theta = NaN and are skipped with a message (extend the table
% rather than extrapolating).
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

    % Incremental + schema upkeep (see header) — skip captures already in the
    % L2 CSV; a schema change archives and reprocesses the whole file.
    if isfile(out_csv)
        prev = readtable(out_csv, 'TextType', 'string');
        pv   = prev.Properties.VariableNames;
        if ismember('phase_chain_deg', pv)
            T = T(~ismember(T.base_name, prev.base_name), :);
        elseif ismember('phase_corr_fd_deg', pv)
            stamp = string(datetime('now', 'Format', 'yyyyMMdd'));
            archived = strrep(out_csv, '.csv', "_no_chaincal_" + stamp + ".csv");
            movefile(out_csv, archived);
            fprintf(['[L2] Existing CSV predates the chain-phase calibration ' ...
                     'columns — archived to %s; reprocessing all captures.\n'], archived);
        elseif ismember('az_deg', pv)
            stamp = string(datetime('now', 'Format', 'yyyyMMdd'));
            archived = strrep(out_csv, '.csv', "_no_fd_" + stamp + ".csv");
            movefile(out_csv, archived);
            fprintf(['[L2] Existing CSV predates the frequency-domain phase ' ...
                     'columns — archived to %s; reprocessing all captures.\n'], archived);
        else
            stamp = string(datetime('now', 'Format', 'yyyyMMdd'));
            archived = strrep(out_csv, '.csv', "_no_az_" + stamp + ".csv");
            movefile(out_csv, archived);
            fprintf(['[L2] Existing CSV predates az_deg — archived to %s; ' ...
                     'reprocessing all captures.\n'], archived);
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

    % --- Receiver chain-phase calibration (leak-cancelled NS - L estimator) ---
    % Chain-cal knobs, all overridable from cfg (docs/config-reference.md#chain-cal-knobs):
    chain_gap_min = getfield_default(cfg, 'chain_run_gap_min',   20);
    chain_tol_min = getfield_default(cfg, 'chain_join_tol_min',  60);
    chain_ref_deg = getfield_default(cfg, 'chain_phase_ref_deg', -81.4);
    [t_chain, ph_run] = chain_phase_runs( ...
        fullfile(cfg.out_dir, 'BrundageSoOp_calib.csv'), chain_gap_min);
    phase_chain = nan(height(T), 1);
    if ~isempty(t_chain)
        if isscalar(t_chain)
            idx = ones(height(T), 1);
        else
            idx = interp1(t_chain, 1:numel(t_chain), T.timestamp, 'nearest', 'extrap');
        end
        okc = abs(T.timestamp - t_chain(idx)) <= minutes(chain_tol_min);
        phase_chain(okc) = ph_run(idx(okc));
        fprintf(['[L2] Chain-phase cal: %d/%d captures matched to %d calib runs ' ...
                 '(ref %.1f deg).\n'], sum(okc), height(T), numel(t_chain), chain_ref_deg);
    else
        fprintf(['[L2] Chain-phase cal: no usable calib CSV in %s — ' ...
                 'phase_chain_deg columns are NaN.\n'], cfg.out_dir);
    end
    % SIGN: compute_L1 and compute_calib now share the D.*conj(R) convention
    % (unified 2026-07-06), so the calib chain series is the negation of the old
    % R.*conj(D) series. The chain term therefore SUBTRACTS (with the negated
    % chain_ref_deg = -81.4) so the applied correction is numerically identical
    % to the previous pipeline (both sign flips cancel). chain_phase_runs reads
    % C_RDNS/C_RDL straight from the calib CSV, so it inherits the v5 convention
    % automatically — no code change there.
    d_chain          = phase_chain - chain_ref_deg;
    corr_cal         = wrap180(phase_corr         - d_chain);
    corr_cal_fd      = wrap180(phase_corr_fd      - d_chain);
    corr_cal_fd_muos = wrap180(phase_corr_fd_muos - d_chain);

    out = table(T.timestamp, T.base_name, theta, az, T.peak_phase_deg, ...
                wrap180(phase_geom), phase_corr, T.snr_db, ...
                phase_raw_fd, phase_corr_fd, phase_raw_fd_muos, phase_corr_fd_muos, ...
                phase_chain, corr_cal, corr_cal_fd, corr_cal_fd_muos, ...
                'VariableNames', {'timestamp', 'base_name', 'theta_deg', 'az_deg', ...
                'phase_raw_deg', 'phase_geom_deg', 'phase_corr_deg', 'snr_db', ...
                'phase_raw_fd_deg', 'phase_corr_fd_deg', ...
                'phase_raw_fd_muos_deg', 'phase_corr_fd_muos_deg', ...
                'phase_chain_deg', 'phase_corr_cal_deg', ...
                'phase_corr_cal_fd_deg', 'phase_corr_cal_fd_muos_deg'});

    if isfile(out_csv)
        writetable(out, out_csv, 'WriteMode', 'append', 'WriteVariableNames', false);
    else
        writetable(out, out_csv);
    end
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


function [t_run, ph_run] = chain_phase_runs(calib_csv, gap_min)
% Per-run receiver-chain differential phase from the calib CSV, using the
% leak-cancelled estimator angle(C_RDNS - C_RDL). The NL and L states share
% the injection path and the receiver-internal common-mode leak, so the
% complex difference cancels the leak (and the small common-load term) and
% isolates the noise-diode path. Overflow-flagged pairs are excluded; pairs
% are grouped into runs by >gap_min gaps and reduced to a circular mean per
% run, timestamped at the run's mean capture time (Pi-local, same timebase
% as the L1 rows). Empty outputs if the CSV or its columns are missing.
    t_run  = datetime.empty(0, 1);
    ph_run = [];
    if ~isfile(calib_csv), return; end
    C = readtable(calib_csv, 'TextType', 'string');
    need = {'timestamp', 'C_RDNS_amp', 'C_RDNS_phase_deg', ...
            'C_RDL_amp', 'C_RDL_phase_deg'};
    if ~all(ismember(need, C.Properties.VariableNames)), return; end
    if ~isdatetime(C.timestamp)
        C.timestamp = datetime(C.timestamp, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
    end
    if ismember('overflow_flag', C.Properties.VariableNames)
        C = C(C.overflow_flag == 0, :);
    end
    C = sortrows(C, 'timestamp');
    if isempty(C), return; end
    z = C.C_RDNS_amp .* exp(1i * deg2rad(C.C_RDNS_phase_deg)) ...
      - C.C_RDL_amp  .* exp(1i * deg2rad(C.C_RDL_phase_deg));
    grp = cumsum([true; diff(C.timestamp) > minutes(gap_min)]);
    n   = accumarray(grp, 1);
    zu  = z ./ max(abs(z), eps);   % unit vectors -> equal-weight circular mean
    ph_run = rad2deg(atan2(accumarray(grp, imag(zu)), accumarray(grp, real(zu))));
    t_run  = datetime(accumarray(grp, posixtime(C.timestamp)) ./ n, ...
                      'ConvertFrom', 'posixtime');
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

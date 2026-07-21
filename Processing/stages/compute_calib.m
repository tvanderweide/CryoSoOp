function compute_calib(cfg)
% Calibration pipeline from NL (noise+load) and L (load-only) captures.
% Implements IIP-SoOpSAR-processing-equations-v8.md Section 2.1, Eqs. 23-40.
%
% Groups captures by run folder or, for a flat layout, by time gap; the k-th NL
% pairs with the k-th L chronologically. An overflowed L is replaced by the
% nearest clean L in its run when possible; otherwise the flagged pair is kept.
%
% GPIO calibration states (set by BeagleBone Black):
%   UHF__NL_*  — noise + load injected (GPIO 0,0,0)
%   UHF__L_*   — load only             (GPIO 0,0,1)
%
% File format: same per-channel pair convention as the signal files —
%   UHF__NL_YYYYMMDDHHMMSS_ch0.dat (direct) / _ch1.dat (reflected),
%   each one channel of interleaved I/Q int16.
%
% Gains are in raw ADC-units^2/W (absolute scale arbitrary); what matters
% for stability monitoring is their consistency over time. rho_DRL and
% rho_DRNS are dimensionless and unaffected by scale.
%
% Cross-correlation convention: C_RDL and C_RDNS use D.*conj(R)
% (direct = ch0, reflected = ch1), matching compute_L1.
%
% Output: cfg.out_dir/BrundageSoOp_calib.csv (appended per batch — an
% interrupted run resumes from the last completed batch). Columns include
% rho_DRL, rho_DRNS, SNR_DNS (Eq. 39a), SNR_RNS (Eq. 39b), P_NS,
% overflow_flag, nl_peak_lag, l_peak_lag, n_samps_nl, n_samps_l, and
% session_id. session_id is the run key used by the L2 chain-calibration join.
%
% overflow_flag (0/1): set if either file in the NL/L pair was flagged by
% find_overflows (cfg.overflow_file); such pairs' rho_DRL/rho_DRNS are
% unreliable. The viewer excludes flagged rows from all plots.
%

    % --- Configure RFI methods and output directories ---
    % cfg.rfi_apply_calib gates whether calibration is excised; when false the
    % calibration is computed once (unexcised) into the base dir only.
    methods = cellstr(getfield_default(cfg, 'rfi_methods', {'none'}));
    if ~getfield_default(cfg, 'rfi_apply_calib', true)
        methods = {'none'};
    end
    E_rfi     = rfi_excise();
    apply_rfi = E_rfi.apply;
    nM        = numel(methods);
    out_calib = cell(nM, 1);
    for mi = 1:nM
        out_calib{mi} = fullfile(E_rfi.method_out_dir(cfg.out_dir, methods{mi}), ...
                                 'BrundageSoOp_calib.csv');
    end

    % --- Load overflow base names (find_overflows output) ---
    if isfield(cfg, 'overflow_file') && isfile(cfg.overflow_file)
        of_lines = strtrim(splitlines(fileread(cfg.overflow_file)));
        overflow_set = of_lines(strlength(of_lines) > 0);
        fprintf('[calib] Overflow list loaded: %d flagged captures from %s\n', ...
                numel(overflow_set), cfg.overflow_file);
    else
        overflow_set = strings(0, 1);
        if ~isfield(cfg, 'overflow_file')
            fprintf(['[calib] WARNING: cfg.overflow_file not set — overflow_flag will ' ...
                     'be 0 for all rows.\n']);
        else
            fprintf(['[calib] WARNING: overflow file not found (%s) — overflow_flag will ' ...
                     'be 0 for all rows.\n'], cfg.overflow_file);
        end
    end

    % --- Find NL and L captures ---
    % 'UHF__NL_2*' does not match 'UHF__NLs_*' (small sets) — after the
    % literal 'UHF__NL_' the next character must be a year-leading '2'. '**'
    % covers both run folders and captures stored directly in cfg.data_dir.
    nl_ch0 = dir(fullfile(cfg.data_dir, '**', 'UHF__NL_2*_ch0.dat'));
    l_ch0  = dir(fullfile(cfg.data_dir, '**', 'UHF__L_2*_ch0.dat'));

    if isempty(nl_ch0) || isempty(l_ch0)
        fprintf('[calib] No calibration pairs found (NL ch0: %d, L ch0: %d) in %s\n', ...
                numel(nl_ch0), numel(l_ch0), cfg.data_dir);
        return;
    end

    nl_bases = string(erase({nl_ch0.name}', '_ch0.dat'));
    l_bases  = string(erase({l_ch0.name}',  '_ch0.dat'));

    % --- Assign UHD session identity ---
    % Run-folder captures use a validated "<YYYYMMDD>/<HHMMSS>" key; captures
    % at the data root use "legacy-flat". Ambiguous bases use "unknown" and
    % fail closed in the L2 chain-calibration join.
    dr        = dir(cfg.data_dir);
    root_fold = string(dr(1).folder);          % data_dir as dir() spells it
    nl_sids   = arrayfun(@(h) session_key(h.folder, root_fold), nl_ch0);
    l_sids    = arrayfun(@(h) session_key(h.folder, root_fold), l_ch0);
    [map_b, map_s, n_ambig] = base_sid_map([nl_bases; l_bases], [nl_sids; l_sids]);
    if n_ambig > 0
        fprintf(['[calib] WARNING(session-key): %d capture base name(s) appear in ' ...
                 'more than one session folder — their rows get session_id ' ...
                 '"unknown" (excluded from chain cal).\n'], n_ambig);
    end

    % --- Validate each method's schema and collect processed NL bases ---
    done_nl = cell(nM, 1);
    for mi = 1:nM
        done_nl{mi} = strings(0, 1);
        oc = out_calib{mi};
        if ~isfile(oc), continue; end
        try
            prev = readtable(oc, 'TextType', 'string');
        catch ME
            error(['compute_calib: could not read existing %s (%s). ' ...
                   'If a previous run was killed mid-append, the last line ' ...
                   'may be truncated — inspect and remove it, then re-run.'], ...
                   oc, ME.message);
        end
        if ismember('n_samps_nl', prev.Properties.VariableNames)
            % Required sample-count fields are present; continue incrementally.
            done_nl{mi} = prev.nl_base;
        elseif ismember('nl_peak_lag', prev.Properties.VariableNames)
            % Missing sample counts identify phase-incompatible output;
            % archive it and recompute every pair.
            stamp = string(datetime('now', 'Format', 'yyyyMMdd'));
            archived = strrep(oc, '.csv', "_v4_" + stamp + ".csv");
            movefile(oc, archived);
            fprintf(['[calib] %s is schema v4 (no n_samps_nl) — archived to %s; ' ...
                     'reprocessing under v5. NOTE: v5 unifies the convention to ' ...
                     'D.*conj(R); C_RDL_phase_deg / C_RDNS_phase_deg negate vs ' ...
                     'the archived v4 values.\n'], oc, archived);
        elseif ismember('SNR_DNS', prev.Properties.VariableNames)
            stamp = string(datetime('now', 'Format', 'yyyyMMdd'));
            archived = strrep(oc, '.csv', "_v3_" + stamp + ".csv");
            movefile(oc, archived);
            fprintf(['[calib] %s is schema v3 (no nl_peak_lag) — ' ...
                     'archived to %s; reprocessing under v5.\n'], oc, archived);
        elseif ismember('rho_DRNS', prev.Properties.VariableNames)
            stamp = string(datetime('now', 'Format', 'yyyyMMdd'));
            archived = strrep(oc, '.csv', "_v2_" + stamp + ".csv");
            movefile(oc, archived);
            fprintf(['[calib] %s is schema v2 (no SNR_DNS) — ' ...
                     'archived to %s; reprocessing under v5.\n'], oc, archived);
        else
            stamp = string(datetime('now', 'Format', 'yyyyMMdd'));
            archived = strrep(oc, '.csv', "_v1_" + stamp + ".csv");
            movefile(oc, archived);
            fprintf(['[calib] %s is schema v1 (no rho_DRNS) — ' ...
                     'archived to %s; reprocessing under v5.\n'], oc, archived);
        end
    end

    % --- Add overflow_flag to append-incompatible CSVs from capture metadata ---
    for mi = 1:nM
        oc = out_calib{mi};
        if ~isfile(oc), continue; end
        try
            existing = readtable(oc, 'TextType', 'string');
            if ~ismember('overflow_flag', existing.Properties.VariableNames)
                if ~isempty(overflow_set)
                    nl_flagged = ismember(existing.nl_base, overflow_set);
                    l_flagged  = ismember(existing.l_base,  overflow_set);
                    existing.overflow_flag = uint8(nl_flagged | l_flagged);
                    n_flagged = sum(existing.overflow_flag);
                else
                    existing.overflow_flag = zeros(height(existing), 1, 'uint8');
                    n_flagged = 0;
                end
                writetable(existing, oc);
                fprintf('[calib] Patched %s with overflow_flag column (%d rows flagged).\n', ...
                        oc, n_flagged);
            end
        catch ME
            fprintf('[calib] WARNING: could not patch overflow_flag into %s: %s\n', ...
                    oc, ME.message);
        end
    end

    % --- Add session_id to append-incompatible CSVs from capture metadata ---
    % NL and L must map to the same session; missing, ambiguous, or mismatched
    % pairs become "unknown" and fail closed in L2. Replace atomically and stop
    % on failure before appending any rows.
    for mi = 1:nM
        oc = out_calib{mi};
        if ~isfile(oc), continue; end
        try
            existing = readtable(oc, 'TextType', 'string');
            if ~ismember('session_id', existing.Properties.VariableNames)
                nl_s = sid_of(existing.nl_base, map_b, map_s);
                l_s  = sid_of(existing.l_base,  map_b, map_s);
                sid  = nl_s;
                sid(nl_s ~= l_s) = "unknown";
                existing.session_id = sid;
                tmp = strrep(oc, '.csv', '_patch_tmp.csv');   % writetable needs a .csv extension
                writetable(existing, tmp);
                chk = readtable(tmp, 'TextType', 'string');   % validate before replacing
                assert(height(chk) == height(existing) && ...
                       isequal(chk.Properties.VariableNames, existing.Properties.VariableNames), ...
                       'row/column mismatch after patch write');
                movefile(tmp, oc);
                fprintf(['[calib] Patched %s with session_id (schema v6): %d keyed, ' ...
                         '%d legacy-flat, %d unknown row(s).\n'], oc, ...
                        sum(sid ~= "legacy-flat" & sid ~= "unknown"), ...
                        sum(sid == "legacy-flat"), sum(sid == "unknown"));
            end
        catch ME
            error(['compute_calib: could not patch session_id into %s (%s). ' ...
                   'Refusing to append v6 rows to an unmigrated CSV.'], oc, ME.message);
        end
    end

    % --- Group captures into runs and rank-pair NL with L ---
    % Run folders define sessions. Root-level captures are split at gaps longer
    % than 20 min, safely below the approximately 2 h calibration cadence.
    % Observed run spans are <=~120 s for 4NL+4L and <=~35 s for 2NL+2L.
    run_gap_sec = 20*60;   % flat-layout run split (s)

    nl_ts = base_timestamps(nl_bases);
    l_ts  = base_timestamps(l_bases);

    % Merge NL+L into one capture list: type flag, source index (into
    % nl_ch0/l_ch0), timestamp, and containing folder.
    all_isnl = [true(numel(nl_bases), 1); false(numel(l_bases), 1)];
    all_idx  = [(1:numel(nl_bases))';   (1:numel(l_bases))'];
    all_ts   = [nl_ts;                  l_ts];
    all_fold = [string({nl_ch0.folder}'); string({l_ch0.folder}')];

    % Defensive: drop captures whose 14-digit stamp did not parse (NaT) — they
    % cannot be time-ordered or paired.
    bad_ts = isnat(all_ts);
    if any(bad_ts)
        fprintf('[calib] %d cal capture(s) have an unparseable timestamp — skipped.\n', ...
                sum(bad_ts));
        all_isnl(bad_ts) = []; all_idx(bad_ts) = [];
        all_ts(bad_ts)   = []; all_fold(bad_ts) = [];
    end

    % Assign runs per capture so folder and flat layouts can coexist. Each
    % non-root folder is one UHD session; root captures use the gap split.
    is_root = (all_fold == root_fold);
    run_id  = zeros(numel(all_ts), 1);
    if any(~is_root)
        [~, ~, fid] = unique(all_fold(~is_root));   % one run per folder
        run_id(~is_root) = fid;
    end
    n_fold_runs = max([run_id; 0]);
    ri = find(is_root);
    if ~isempty(ri)
        [rts, so] = sort(all_ts(ri));
        ri = ri(so);
        run_id(ri) = n_fold_runs + cumsum([1; seconds(diff(rts)) > run_gap_sec]);
    end

    jobs = struct('nl', {}, 'l', {}, 'nl_base', {}, 'l_base', {}, 'session_id', {});
    job_needed = false(0, nM);   % which methods each job still needs
    for r = reshape(unique(run_id), 1, [])
        in_run = (run_id == r);
        % Session sentinel for this run (all members share one folder by
        % construction: folder-keyed runs trivially, gap runs are all root).
        sid_r  = session_key(all_fold(find(in_run, 1)), root_fold);
        nl_sel = find(in_run &  all_isnl);
        l_sel  = find(in_run & ~all_isnl);
        % Chronological order within the run.
        [~, o] = sort(all_ts(nl_sel));  nl_sel = nl_sel(o);
        [~, o] = sort(all_ts(l_sel));   l_sel  = l_sel(o);

        nPair = min(numel(nl_sel), numel(l_sel));
        if numel(nl_sel) ~= numel(l_sel)
            fprintf(['[calib] Run has %d NL / %d L cal capture(s) — pairing %d; ' ...
                     '%d leftover capture(s) unpaired (skipped).\n'], ...
                     numel(nl_sel), numel(l_sel), nPair, ...
                     abs(numel(nl_sel) - numel(l_sel)));
        end

        % L overflow status within this run (for the clean-fallback below).
        l_over_run = ismember(l_bases(all_idx(l_sel)), overflow_set);

        for k = 1:nPair
            i = all_idx(nl_sel(k));   % index into nl_ch0
            need = false(1, nM);
            for mi = 1:nM, need(mi) = ~ismember(nl_bases(i), done_nl{mi}); end
            if ~any(need), continue; end   % all methods already have this NL

            % Rank-matched L; if it is overflowed and a clean L exists in the
            % run, substitute the nearest-in-time clean one. If every L in the
            % run is overflowed keep the rank L (the row is written and flagged
            % by process_calib_pair).
            jk = k;
            if l_over_run(k) && any(~l_over_run)
                clean_k = find(~l_over_run);
                [~, nn] = min(abs(all_ts(l_sel(clean_k)) - all_ts(nl_sel(k))));
                jk = clean_k(nn);
            end
            j = all_idx(l_sel(jk));   % index into l_ch0

            jobs(end+1) = struct('nl', nl_ch0(i), 'l', l_ch0(j), ...
                                 'nl_base', nl_bases(i), 'l_base', l_bases(j), ...
                                 'session_id', sid_r); %#ok<AGROW>
            job_needed(end+1, :) = need; %#ok<AGROW>
        end
    end

    if isempty(jobs)
        fprintf('[calib] No new calibration pairs (all %d method(s) up to date).\n', nM);
        return;
    end
    fprintf('[calib] %d new calibration pair(s) across %d method(s).\n', numel(jobs), nM);

    for mi = 1:nM
        dm = fileparts(out_calib{mi});
        if ~isfolder(dm), mkdir(dm); end
    end
    if ~isfield(cfg, 'batch_size'), cfg.batch_size = 200; end

    % --- RFI excision operators are built per-capture inside the worker
    %     (calibration captures vary in length), so only the method list and
    %     the apply handle are broadcast here. ---

    % --- Batched processing with per-batch CSV appends ---
    n_jobs    = numel(jobs);
    n_batches = ceil(n_jobs / cfg.batch_size);
    t_start   = tic;

    for b = 1:n_batches
        bi = (b-1)*cfg.batch_size + 1 : min(b*cfg.batch_size, n_jobs);
        batch = jobs(bi);
        nb    = numel(batch);
        rows  = cell(nb, 1);

        ovf_set = overflow_set;   % broadcast to parfor workers
        parfor k = 1:nb
            rows{k} = process_calib_pair(batch(k), cfg, ovf_set, methods, apply_rfi);
        end

        % rows{k} is a 1xnM cell (one calib row per method, or [] if skipped);
        % append each method only for the batch jobs it still needs.
        for mi = 1:nM
            sel   = job_needed(bi, mi);
            vals  = cellfun(@(rk) rk{mi}, rows(sel), 'UniformOutput', false);
            valid = vals(~cellfun(@isempty, vals));
            if ~isempty(valid)
                T = struct2table(vertcat(valid{:}));
                if isfile(out_calib{mi})
                    writetable(T, out_calib{mi}, 'WriteMode', 'append', 'WriteVariableNames', false);
                else
                    writetable(T, out_calib{mi});
                end
            end
        end
        fprintf('[calib] Batch %d/%d done — %d/%d pairs, %.1f min elapsed.\n', ...
                b, n_batches, min(b*cfg.batch_size, n_jobs), n_jobs, toc(t_start)/60);
    end

    fprintf('[calib] Complete. Results → %s\n', strjoin(string(out_calib), ', '));
end


% =========================================================================
function rows = process_calib_pair(job, cfg, overflow_set, methods, apply_rfi)
% Compute Eqs. 23–40 for one NL–L pair and each RFI method.
% rows follows methods order; unreadable or degenerate products remain empty.
%
% Excision is done in the frequency domain: the lag-0 products (Eqs. 24-27) are
% formed directly from the excised spectra via Parseval —
% mean(e_d.*conj(e_r)) == sum(F_Dm.*conj(F_Rm))/N^2 — so no ifft round-trip is
% needed. 'none' uses the raw signals without an FFT. Cross-correlations use
% D.*conj(R) (direct = ch0, reflected = ch1), matching compute_L1.
%
% Variables follow theory doc notation:
%   E_DNS, E_RNS — noise+load signals, direct (D) and reflected (R) channels
%   E_DL,  E_RL  — load-only signals

    nMeth = numel(methods);
    rows  = cell(1, nMeth);

    % Physical constants.
    k_B = 1.380649e-23;  % Boltzmann constant (J/K)
    B   = cfg.fs;        % noise bandwidth = sample rate (Hz)
    P_L = k_B * cfg.T_load_K * B;   % load thermal noise power (Eq. 28)

    % Read both captures once (direct = ch0, reflected = ch1).
    [E_DNS, E_RNS, ok_nl] = read_capture(job.nl, job.nl_base, cfg.min_bytes);
    if ~ok_nl, return; end
    [E_DL, E_RL, ok_l] = read_capture(job.l, job.l_base, cfg.min_bytes);
    if ~ok_l, return; end

    % Record exact complex-sample counts after matching channel lengths.
    n_samps_nl = numel(E_DNS);
    n_samps_l  = numel(E_DL);

    % Excision operators + spectra (only when a non-none method is requested).
    % Per-calibration-state bands: NL captures use cfg.rfi_bands_nl, L uses
    % cfg.rfi_bands_l (rfi_prepare_bands swaps cfg.rfi_bands per state; an empty
    % list for a state -> pass-through, so that state runs unexcised).
    Pn = []; Pl = []; F_DNS = []; F_RNS = []; F_DL = []; F_RL = [];
    if any(~strcmp(methods, 'none'))
        bands_nl = getfield_default(cfg, 'rfi_bands_nl', zeros(0,2));
        bands_l  = getfield_default(cfg, 'rfi_bands_l',  zeros(0,2));
        Pn = rfi_prepare_bands(cfg, bands_nl, numel(E_DNS));
        Pl = rfi_prepare_bands(cfg, bands_l,  numel(E_DL));
        F_DNS = fft(E_DNS);  F_RNS = fft(E_RNS);
        F_DL  = fft(E_DL);   F_RL  = fft(E_RL);
    end

    % Timestamp + overflow flag (shared across methods).
    tok = regexp(job.nl_base, '\d{14}', 'match', 'once');
    if strlength(tok) == 14
        ts = datetime(tok, 'InputFormat', 'yyyyMMddHHmmss');
    else
        ts = NaT;
    end
    ts.Format = 'yyyy-MM-dd HH:mm:ss';
    ovf = uint8(ismember(job.nl_base, overflow_set) || ismember(job.l_base, overflow_set));

    % --- Measured peak-lag diagnostic (Signal-style windowed xcorr argmax) ---
    % Integer lag of max |cross-corr(direct, reflected)| over +-lag_half_win,
    % computed exactly as compute_L1 does for signal captures, for the NL and L
    % captures separately and per RFI method. Calibration carries no sky signal,
    % so this isolates the instrumental ch0/ch1 delay. Diagnostic only.
    % Per-state excision operators (same per-state bands as the calibration
    % path above), so the lag diagnostic excises NL/L with their own bands.
    npts_l    = floor(cfg.fs * cfg.Ti);
    bands_nl  = getfield_default(cfg, 'rfi_bands_nl', zeros(0,2));
    bands_l   = getfield_default(cfg, 'rfi_bands_l',  zeros(0,2));
    P_lag_nl  = rfi_prepare_bands(cfg, bands_nl, npts_l);
    P_lag_l   = rfi_prepare_bands(cfg, bands_l,  npts_l);
    nl_lags = peak_lags_all(E_DNS, E_RNS, npts_l, cfg.num_segs, cfg.lag_half_win, methods, apply_rfi, P_lag_nl);
    l_lags  = peak_lags_all(E_DL,  E_RL,  npts_l, cfg.num_segs, cfg.lag_half_win, methods, apply_rfi, P_lag_l);

    for mi = 1:nMeth
        m = methods{mi};
        % Cross-correlations at lag=0 and channel powers (Eqs. 24–27) use
        % D.*conj(R) (direct = ch0, reflected = ch1). 'none' uses the raw time
        % series; excised methods form the same products by Parseval:
        % mean(e_d.*conj(e_r)) == sum(F_Dm.*conj(F_Rm))/N^2) with no ifft
        % round-trip.
        if strcmp(m, 'none')
            C_RDNS = mean(E_DNS .* conj(E_RNS));   % Eq. 25 (D.*conj(R))
            P_DNS  = mean(abs(E_DNS).^2);
            P_RNS  = mean(abs(E_RNS).^2);
            C_RDL  = mean(E_DL  .* conj(E_RL));    % Eq. 27 (D.*conj(R))
            P_DL   = mean(abs(E_DL).^2);
            P_RL   = mean(abs(E_RL).^2);
        else
            F_DNSm = apply_rfi(F_DNS, m, Pn);  F_RNSm = apply_rfi(F_RNS, m, Pn);
            F_DLm  = apply_rfi(F_DL,  m, Pl);  F_RLm  = apply_rfi(F_RL,  m, Pl);
            n_ns = numel(E_DNS);  n_l = numel(E_DL);
            C_RDNS = sum(F_DNSm .* conj(F_RNSm)) / n_ns^2;   % Eq. 25 (D.*conj(R))
            P_DNS  = sum(abs(F_DNSm).^2) / n_ns^2;
            P_RNS  = sum(abs(F_RNSm).^2) / n_ns^2;
            C_RDL  = sum(F_DLm  .* conj(F_RLm))  / n_l^2;    % Eq. 27 (D.*conj(R))
            P_DL   = sum(abs(F_DLm).^2) / n_l^2;
            P_RL   = sum(abs(F_RLm).^2) / n_l^2;
        end

        % Noise source power (Eq. 31): P_NS = |C_RDNS / C_RDL| * P_L
        if abs(C_RDL) < eps
            fprintf('[calib] C_RDL ~ 0 for %s (%s) — skipped.\n', job.nl_base, m);
            continue;
        end
        P_NS = (abs(C_RDNS) / abs(C_RDL)) * P_L;

        % Per-channel gains (Eq. 34).
        denom = P_NS - P_L;
        if abs(denom) < eps
            fprintf('[calib] P_NS ~ P_L for %s (%s) — degenerate, skipped.\n', job.nl_base, m);
            continue;
        end
        G_De = (P_DNS - P_DL) / denom;   % Eq. 34a
        G_Re = (P_RNS - P_RL) / denom;   % Eq. 34b

        P_DN = P_DL - G_De * P_L;        % Eq. 36a
        P_RN = P_RL - G_Re * P_L;        % Eq. 36b

        SNR_DL  = (G_De * P_L)  / max(P_DN, eps);   % Eq. 37
        SNR_RL  = (G_Re * P_L)  / max(P_RN, eps);
        SNR_DNS = (G_De * P_NS) / max(P_DN, eps);   % Eq. 39
        SNR_RNS = (G_Re * P_NS) / max(P_RN, eps);

        rho_DRL  = abs(C_RDL)  / sqrt(P_DL  * P_RL);    % Eq. 38
        rho_DRNS = abs(C_RDNS) / sqrt(P_DNS * P_RNS);

        % Keep append-patched fields at the end of the table schema.
        row = struct();
        row.timestamp        = ts;
        row.nl_base          = job.nl_base;
        row.l_base           = job.l_base;
        row.C_RDL_amp        = abs(C_RDL);
        row.C_RDL_phase_deg  = angle(C_RDL) * (180/pi);
        row.C_RDNS_amp       = abs(C_RDNS);
        row.C_RDNS_phase_deg = angle(C_RDNS) * (180/pi);
        row.P_DL             = P_DL;
        row.P_RL             = P_RL;
        row.P_DNS            = P_DNS;
        row.P_RNS            = P_RNS;
        row.G_De             = G_De;
        row.G_Re             = G_Re;
        row.P_DN             = P_DN;
        row.P_RN             = P_RN;
        row.rho_DRL          = rho_DRL;
        row.rho_DRNS         = rho_DRNS;
        row.SNR_DL           = SNR_DL;
        row.SNR_RL           = SNR_RL;
        row.P_NS             = P_NS;
        row.SNR_DNS          = SNR_DNS;
        row.SNR_RNS          = SNR_RNS;
        row.overflow_flag    = ovf;
        row.nl_peak_lag      = nl_lags(mi);   % measured NL ch0xch1 argmax lag (samples)
        row.l_peak_lag       = l_lags(mi);    % measured L ch0xch1 argmax lag (samples)
        row.n_samps_nl       = n_samps_nl;    % complex samples read from NL capture
        row.n_samps_l        = n_samps_l;     % complex samples read from L capture
        row.session_id       = job.session_id; % Keep last to match metadata-only patches.
        rows{mi} = row;
    end
end


% =========================================================================
function [ch0, ch1, ok] = read_capture(f_ch0, base_name, min_bytes)
% Read both channels of a calibration capture (ch0/ch1 file pair).
% Each file is one channel of interleaved I/Q int16.
    ch0 = [];
    ch1 = [];
    ok  = false;

    ch0_path = fullfile(f_ch0.folder, f_ch0.name);
    ch1_path = fullfile(f_ch0.folder, base_name + "_ch1.dat");

    d1 = dir(ch1_path);
    if isempty(d1)
        fprintf('[calib] Missing ch1 file for %s — skipped.\n', base_name);
        return;
    end
    if f_ch0.bytes < min_bytes || d1.bytes < min_bytes
        fprintf('[calib] %s below size gate (%d / %d bytes) — skipped.\n', ...
                base_name, f_ch0.bytes, d1.bytes);
        return;
    end

    ch0 = read_channel(ch0_path);
    ch1 = read_channel(ch1_path);
    n   = min(numel(ch0), numel(ch1));
    ch0 = ch0(1:n);
    ch1 = ch1(1:n);
    ok  = n > 0;
end


% =========================================================================
function ch = read_channel(filepath)
% Read a full single-channel sc16 file: [I0, Q0, I1, Q1, ...] int16.
% Returns a complex double column vector.
    fid = fopen(filepath, 'rb');
    raw = fread(fid, [2, Inf], '*int16');  % row 1 = I, row 2 = Q
    fclose(fid);
    ch = double(raw(1,:)).' + 1j * double(raw(2,:)).';
end


% =========================================================================
function ts = base_timestamps(bases)
% Extract datetime from base names containing 14-digit YYYYMMDDHHMMSS.
    ts = NaT(numel(bases), 1);
    for i = 1:numel(bases)
        m = regexp(bases(i), '\d{14}', 'match', 'once');
        if strlength(m) == 14
            ts(i) = datetime(m, 'InputFormat', 'yyyyMMddHHmmss');
        end
    end
end


% =========================================================================
function lags = peak_lags_all(ch0, ch1, npts, num_segs, lag_half_win, methods, apply_rfi, P)
% Integer argmax lag (samples) of the Hann-windowed, segment-averaged
% cross-correlation R = fftshift(ifft(F0.*conj(F1)))/npts over +-lag_half_win,
% one value per RFI method. F0/F1 are computed once per segment and each
% method's excision is applied before the cross-spectrum. ch0 = direct and
% ch1 = reflected, matching compute_L1. Returns NaN without a full segment.
    nMeth  = numel(methods);
    lags   = nan(1, nMeth);
    n_segs = min(floor(min(numel(ch0), numel(ch1)) / npts), num_segs);
    if n_segs == 0, return; end
    npos = (0:npts-1)';
    win  = 0.5 * (1 - cos(2*pi*npos / (npts-1)));   % Hann window, matching compute_L1
    R = repmat({zeros(npts, 1)}, 1, nMeth);
    for s = 1:n_segs
        i1 = (s-1)*npts + 1;  i2 = s*npts;
        F0 = fft(ch0(i1:i2) .* win);
        F1 = fft(ch1(i1:i2) .* win);
        for mi = 1:nMeth
            F0m   = apply_rfi(F0, methods{mi}, P);
            F1m   = apply_rfi(F1, methods{mi}, P);
            R{mi} = R{mi} + fftshift(ifft(F0m .* conj(F1m))) / npts;
        end
    end
    center = npts/2 + 1;
    idx    = (center - lag_half_win):(center + lag_half_win);
    for mi = 1:nMeth
        [~, j]   = max(abs(R{mi}(idx)));
        lags(mi) = idx(j) - center;
    end
end


% =========================================================================
function v = getfield_default(s, name, default)
% cfg field with a fallback when absent/empty.
    if isfield(s, name) && ~isempty(s.(name)), v = s.(name); else, v = default; end
end


% =========================================================================
function [ub, us, n_ambig] = base_sid_map(bases, sids)
% Map each unique base to a session sentinel; duplicates across sessions are
% ambiguous and map to "unknown".
    [ub, ~, ic] = unique(bases);
    us = strings(size(ub));
    for k = 1:numel(ub)
        s = unique(sids(ic == k));
        if isscalar(s), us(k) = s; else, us(k) = "unknown"; end
    end
    n_ambig = sum(arrayfun(@(k) numel(unique(sids(ic == k))) > 1, (1:numel(ub))'));
end


function s = sid_of(bases, map_b, map_s)
% Look up persisted bases; captures absent from disk map to "unknown".
    s = repmat("unknown", numel(bases), 1);
    [tf, loc] = ismember(bases, map_b);
    s(tf) = map_s(loc(tf));
end

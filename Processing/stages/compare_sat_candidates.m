function compare_sat_candidates(cfg)
% Identify which MUOS satellite the Brundage receiver tracks.
%
% Applies every candidate satellite's geometric phase correction to the
% full-season L1 phase and scores the result: the RIGHT satellite's
% correction REMOVES the diurnal oscillation (elevation-driven path
% change); a wrong satellite's correction ADDS a spurious one.
%
% Inputs (in cfg.out_dir):
%   BrundageSoOp_L1_sig.csv     — season L1 products
%   muos_elevation_<norad>.csv  — one per candidate (make_muos_elevation.py)
%
% Score = median over days of the within-day circular std of corrected
% phase, using only rows with snr_db >= cfg.snr_threshold. Reported for
% the full season AND for the early dry-season window (Dec-Jan), where
% geometry should dominate — spring melt-freeze adds a REAL diurnal phase
% signal that the correction must not be blamed for.
%
% Outputs (cfg.out_dir):
%   sat_candidate_comparison.png   — stacked corrected-phase time series
%   sat_candidates_corrected.csv   — per-candidate corrected phase columns
%                                    (interactive view: 'L2: Candidate
%                                    comparison' in BrundageSoOp_viewer). Each
%                                    candidate also gets corr_<norad>_fd and
%                                    corr_<norad>_fd_muos (frequency-domain phase,
%                                    full band + MUOS sub-bands), plus
%                                    phase_raw_fd_deg / phase_raw_fd_muos_deg.
%
% Note: cfg.capture_tz names the capture-stamp timebase; elevation tables
% are UTC. Legacy 2025-26 data used the Pi's LOCAL clock ('America/Boise',
% verified via timedatectl 2026-06-12; conversion handles MST/MDT incl.
% the March DST change). UTC-era cryosoop data uses capture_tz "UTC"
% (identity). If cfg.capture_tz is absent, timestamps are assumed UTC.
%

    if ~isfield(cfg, 'snr_threshold'), cfg.snr_threshold = 10; end

    sig_csv = fullfile(cfg.out_dir, 'BrundageSoOp_L1_sig.csv');
    if ~isfile(sig_csv)
        fprintf('[sat-id] %s not found — run compute_L1 first.\n', sig_csv);
        return;
    end
    % Elevation tables are a stable season input in cfg.elev_dir (decoupled from
    % the per-run out_dir); fall back to out_dir for back-compatibility.
    if isfield(cfg, 'elev_dir') && ~isempty(cfg.elev_dir)
        elev_dir = cfg.elev_dir;
    else
        elev_dir = cfg.out_dir;
    end
    cands = dir(fullfile(elev_dir, 'muos_elevation_*.csv'));
    if isempty(cands)
        fprintf('[sat-id] No muos_elevation_*.csv in %s — run make_muos_elevation.py.\n', ...
                elev_dir);
        return;
    end

    % --- L1 rows above the SNR gate ---
    T = readtable(sig_csv, 'TextType', 'string');
    if ~isdatetime(T.timestamp)
        T.timestamp = datetime(T.timestamp, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
    end
    T = T(isfinite(T.snr_db) & T.snr_db >= cfg.snr_threshold, :);
    T = sortrows(T, 'timestamp');
    t_utc = to_utc(T.timestamp, cfg);
    fprintf('[sat-id] %d captures at SNR >= %g dB.\n', height(T), cfg.snr_threshold);

    lambda_m = 299792458 / cfg.freq_hz;
    k_phase  = (4*pi * cfg.tower_h_m / lambda_m) * (180/pi);  % deg per unit sin(theta)

    % Frequency-domain L1 phase (full band + MUOS sub-bands), scored with the
    % same geometric correction. NaN if compute_L1 has not written the fd
    % columns yet (re-run compute_L1 for the frequency-domain phase).
    has_fd   = ismember('peak_phase_deg_fd',      T.Properties.VariableNames);
    has_muos = ismember('peak_phase_deg_fd_muos', T.Properties.VariableNames);
    if has_fd,   ph_fd   = T.peak_phase_deg_fd;      else, ph_fd   = nan(height(T), 1); end
    if has_muos, ph_muos = T.peak_phase_deg_fd_muos; else, ph_muos = nan(height(T), 1); end

    out = table(T.timestamp, T.base_name, T.snr_db, T.peak_phase_deg, ph_fd, ph_muos, ...
                'VariableNames', {'timestamp', 'base_name', 'snr_db', 'phase_raw_deg', ...
                'phase_raw_fd_deg', 'phase_raw_fd_muos_deg'});

    % --- Score each candidate + the no-correction baseline ---
    dry = T.timestamp >= datetime(2025,12,1) & T.timestamp < datetime(2026,2,1);
    names  = "raw (no correction)";
    s_full = day_score(T.timestamp, T.peak_phase_deg);
    s_dry  = day_score(T.timestamp(dry), T.peak_phase_deg(dry));
    series = {T.peak_phase_deg};
    s_dry_fd   = day_score(T.timestamp(dry), ph_fd(dry));     % index 1 = raw baseline
    s_dry_muos = day_score(T.timestamp(dry), ph_muos(dry));

    % NORAD -> common name, the two geometrically viable from Brundage
    % (per the antenna pointing analysis).
    norad_names = containers.Map({'38093','41622'}, {'MUOS-1','MUOS-5'});

    for i = 1:numel(cands)
        nid = regexp(cands(i).name, '\d+', 'match', 'once');
        if ~isKey(norad_names, nid)
            fprintf('[sat-id] Skipping %s (not in candidate list).\n', cands(i).name);
            continue;
        end

        E = readtable(fullfile(cands(i).folder, cands(i).name), 'TextType', 'string');
        if ~isdatetime(E.timestamp)
            E.timestamp = datetime(E.timestamp, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
        end
        theta = interp1(E.timestamp, E.elevation_deg, t_utc, 'linear', NaN);
        if all(isnan(theta))
            fprintf('[sat-id] %s does not overlap the capture epoch — skipped.\n', ...
                    cands(i).name);
            continue;
        end
        corr = wrap180(T.peak_phase_deg - k_phase * sind(theta));

        names(end+1)  = norad_names(nid);                        %#ok<AGROW>
        s_full(end+1) = day_score(T.timestamp, corr);            %#ok<AGROW>
        s_dry(end+1)  = day_score(T.timestamp(dry), corr(dry));  %#ok<AGROW>
        series{end+1} = corr;                                    %#ok<AGROW>
        out.("corr_" + nid) = corr;

        % Frequency-domain corrections (same geometry), scored in parallel so a
        % change to the satellite-ID conclusion is visible.
        if has_fd
            corr_fd = wrap180(ph_fd - k_phase * sind(theta));
            out.("corr_" + nid + "_fd") = corr_fd;
            s_dry_fd(end+1) = day_score(T.timestamp(dry), corr_fd(dry));  %#ok<AGROW>
        else
            s_dry_fd(end+1) = NaN;  %#ok<AGROW>
        end
        if has_muos
            corr_muos = wrap180(ph_muos - k_phase * sind(theta));
            out.("corr_" + nid + "_fd_muos") = corr_muos;
            s_dry_muos(end+1) = day_score(T.timestamp(dry), corr_muos(dry));  %#ok<AGROW>
        else
            s_dry_muos(end+1) = NaN;  %#ok<AGROW>
        end
    end

    % --- Report ---
    fprintf('\n[sat-id] Median within-day circular std of phase (deg) — lower is better:\n');
    fprintf('  %-22s %12s %14s\n', 'candidate', 'full season', 'Dec-Jan (dry)');
    for i = 1:numel(names)
        fprintf('  %-22s %12.1f %14.1f\n', names(i), s_full(i), s_dry(i));
    end
    [~, best] = min(s_dry(2:end));
    fprintf('[sat-id] Dry-season winner (sinc): %s\n', names(best+1));
    if has_fd && numel(s_dry_fd) > 1
        [~, bfd] = min(s_dry_fd(2:end));
        fprintf('[sat-id] Dry-season winner (fd): %s   [dry std sinc %.1f vs fd %.1f deg]\n', ...
                names(bfd+1), s_dry(best+1), s_dry_fd(bfd+1));
    end
    if has_muos && numel(s_dry_muos) > 1
        [~, bmu] = min(s_dry_muos(2:end));
        fprintf('[sat-id] Dry-season winner (freq_muos): %s   [dry std %.1f deg]\n', ...
                names(bmu+1), s_dry_muos(bmu+1));
    end
    fprintf('\n');

    % --- Stacked time-series figure ---
    fig = figure('Visible', 'off', 'Position', [60 60 1100 220*numel(names)]);
    tl = tiledlayout(fig, numel(names), 1, 'TileSpacing', 'compact');
    for i = 1:numel(names)
        ax = nexttile(tl);
        plot(ax, T.timestamp, series{i}, '.', 'MarkerSize', 2);
        ylim(ax, [-180 180]);  yticks(ax, -180:90:180);  grid(ax, 'on');
        title(ax, names(i));
    end
    xlabel(tl, 'Date');  ylabel(tl, 'Phase (deg)');
    fig_out = fullfile(cfg.out_dir, 'sat_candidate_comparison.png');
    saveas(fig, fig_out);
    close(fig);

    csv_out = fullfile(cfg.out_dir, 'sat_candidates_corrected.csv');
    writetable(out, csv_out);
    fprintf('[sat-id] Saved %s and %s\n', fig_out, csv_out);
end


% =========================================================================
function s = day_score(t, phase_deg)
% Median over days of the within-day circular std (deg).
    if isempty(t), s = NaN; return; end
    grp = findgroups(dateshift(t, 'start', 'day'));
    sd  = splitapply(@circ_std_deg, phase_deg, grp);
    s   = median(sd, 'omitnan');
end

function sd = circ_std_deg(deg)
    z  = mean(exp(1i * deg2rad(deg)), 'omitnan');
    sd = rad2deg(sqrt(-2 * log(max(abs(z), eps))));
end

function y = wrap180(x)
    y = mod(x + 180, 360) - 180;
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

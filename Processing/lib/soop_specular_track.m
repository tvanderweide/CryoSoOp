function [series, meta] = soop_specular_track(cfg, WX, norad, pinned_day, t0, t1, h_mode)
% soop_specular_track  Within-day specular-point track preparation (pure, no UI).
%
% Computes the locus of specular points x_sp = h/tan(e) over ONE day for a
% single satellite, in local ENU meters about the antenna. Flat, horizontal
% reflector assumed (same model as the Fresnel footprint; no DEM). This is the
% data half of the viewer's 'Radar Cal: specular track' display, split out so
% day selection, timezone handling, and snow interpolation are testable
% without a uifigure.
%
% INPUTS
%   cfg         needs elev_dir, tower_h_m; optional capture_tz (elevation
%               tables are UTC; outputs are in the capture timebase, tz-less)
%   WX          weather table (timestamp, depth_m) or empty; capture timebase
%   norad       numeric NORAD id -> <elev_dir>/muos_elevation_<norad>.csv
%   pinned_day  datetime date to pin the track to, or NaT for auto selection
%   t0, t1      top date-range bounds (may be -Inf/+Inf datetimes)
%   h_mode      'fixed h' | 'snow h' | 'both'
%
% DAY SELECTION
%   Pinned: that calendar day (rendered even if the table only partly covers
%   it; meta.complete=false and meta.cov_* report the actual coverage).
%   NaT: the LAST day inside [t0,t1) (clamped to the table span) whose table
%   coverage is COMPLETE: first row <= day_start+TOL and last row >=
%   day_end-TOL with TOL = 30 min (duration-based, so DST 23/25-h local days
%   pass). No complete day -> empty series + meta.msg.
%
% SNOW SERIES ('snow h' / 'both')
%   h(t) = tower_h_m - depth_m(t), depth linearly interpolated at the track
%   epochs from unique weather timestamps, NO extrapolation (production
%   compute_sigma0 semantics). Epochs with missing/non-positive h get NaN
%   E/N (plots break there rather than bridging gaps); the variant is dropped
%   only when no valid epoch remains (reason in meta.snow_msg).
%
% OUTPUTS
%   series  struct array (0..2 entries), fields:
%             label   'fixed h' | 'snow h'
%             t       datetime column (capture timebase, tz-less)
%             hour    fractional hours since local midnight (color axis)
%             E, N    specular-point ENU meters about the antenna (NaN=invalid)
%             h_m     per-epoch reflector height used (NaN=invalid)
%             n_valid number of finite E/N epochs
%   meta    day (midnight datetime), day_pinned, auto_day, complete,
%           cov_start/cov_end (actual row coverage), n_rows, el_min_table
%           (min positive table elevation, for the season-worst-case map
%           extent), msg ('' or why series is empty), snow_msg ('' or why the
%           snow variant was dropped)
    TOL_MIN = 30;   % day-completeness tolerance at each day edge (minutes)

    series = struct('label', {}, 't', {}, 'hour', {}, 'E', {}, 'N', {}, ...
                    'h_m', {}, 'n_valid', {});
    meta = struct('day', NaT, 'day_pinned', false, 'auto_day', false, ...
                  'complete', false, 'cov_start', NaT, 'cov_end', NaT, ...
                  'n_rows', 0, 'el_min_table', NaN, 'msg', '', 'snow_msg', '');

    % --- Elevation table (UTC) -> capture timebase --------------------------
    etab = fullfile(cfg.elev_dir, sprintf('muos_elevation_%d.csv', norad));
    if ~isfile(etab)
        meta.msg = sprintf('Elevation table not found: %s', etab);
        return;
    end
    try
        E_tab = readtable(etab);
    catch err
        meta.msg = sprintf('Could not read %s (%s).', etab, err.message);
        return;
    end
    need = {'timestamp', 'elevation_deg', 'azimuth_deg'};
    if ~all(ismember(need, E_tab.Properties.VariableNames))
        meta.msg = sprintf('%s lacks timestamp/elevation_deg/azimuth_deg.', etab);
        return;
    end
    tt = E_tab.timestamp;
    if ~isdatetime(tt), tt = datetime(string(tt)); end
    if isfield(cfg, 'capture_tz') && ~isempty(cfg.capture_tz) ...
            && ~strcmp(cfg.capture_tz, 'UTC')
        tt.TimeZone = 'UTC';
        tt.TimeZone = cfg.capture_tz;
        tt.TimeZone = '';
    end
    el = E_tab.elevation_deg;
    az = E_tab.azimuth_deg;
    fin = isfinite(el) & isfinite(az) & ~isnat(tt);
    if ~any(fin)
        meta.msg = sprintf('%s has no finite elevation/azimuth rows.', etab);
        return;
    end
    meta.el_min_table = min(el(fin & el > 0));

    % --- Day selection -------------------------------------------------------
    tol = minutes(TOL_MIN);
    if ~isnat(pinned_day)
        day0 = dateshift(datetime(pinned_day), 'start', 'day');
        meta.day_pinned = true;
    else
        % Clamp the (possibly infinite) range bounds to the table span, then
        % walk candidate days newest-first until one is COMPLETE.
        tmin = min(tt(fin));  tmax = max(tt(fin));
        t0e = max(t0, tmin);  t1e = min(t1, tmax + seconds(1));
        in_rng = fin & tt >= t0e & tt < t1e;
        if ~any(in_rng)
            meta.msg = 'No elevation-table rows in the selected date range.';
            return;
        end
        cand = unique(dateshift(tt(in_rng), 'start', 'day'), 'sorted');
        day0 = NaT;
        for ci = numel(cand):-1:1
            d0 = cand(ci);  d1 = d0 + caldays(1);
            trows = tt(fin & tt >= d0 & tt < d1);
            if ~isempty(trows) && min(trows) <= d0 + tol && max(trows) >= d1 - tol
                day0 = d0;
                break;
            end
        end
        if isnat(day0)
            meta.msg = ['No COMPLETE day in the selected range (the table ' ...
                        'starts/ends mid-day at its UTC endpoints) — pin a ' ...
                        'date to draw a partial track.'];
            return;
        end
        meta.auto_day = true;
    end
    day1 = day0 + caldays(1);
    meta.day = day0;

    keep = fin & tt >= day0 & tt < day1;
    if ~any(keep)
        meta.msg = sprintf('No elevation-table rows on %s.', ...
                           string(day0, 'yyyy-MM-dd'));
        return;
    end
    td = tt(keep);  eld = el(keep);  azd = az(keep);
    meta.n_rows    = numel(td);
    meta.cov_start = min(td);
    meta.cov_end   = max(td);
    meta.complete  = meta.cov_start <= day0 + tol && meta.cov_end >= day1 - tol;

    % --- Reflector-height variants ------------------------------------------
    hs = {};  hl = {};
    if any(strcmp(h_mode, {'fixed h', 'both'}))
        hs{end+1} = repmat(cfg.tower_h_m, numel(td), 1);
        hl{end+1} = 'fixed h';
    end
    if any(strcmp(h_mode, {'snow h', 'both'}))
        h_snow = nan(numel(td), 1);
        if ~isempty(WX) && all(ismember({'timestamp', 'depth_m'}, ...
                                        WX.Properties.VariableNames)) ...
                && any(isfinite(WX.depth_m))
            % Production compute_sigma0 semantics: keep EVERY unique-timestamp
            % row as an interpolation node, NaN depths included, so an invalid
            % SNOdar block poisons its intervals (NaN through the block, line
            % breaks) instead of being bridged by its finite neighbors.
            wok = ~isnat(WX.timestamp);
            [wt, iu] = unique(WX.timestamp(wok));
            wd = WX.depth_m(wok);  wd = wd(iu);
            if numel(wt) >= 2
                depth_i = interp1(wt, wd, td, 'linear', NaN);      % no extrap
            else
                depth_i = nan(numel(td), 1);
                depth_i(td == wt) = wd;
            end
            h_snow = cfg.tower_h_m - depth_i;
        end
        h_snow(~isfinite(h_snow) | h_snow <= 0) = NaN;
        if any(isfinite(h_snow))
            hs{end+1} = h_snow;  hl{end+1} = 'snow h';
        else
            meta.snow_msg = ['snow h unavailable: no SNOdar depth covering ' ...
                             'this day (or h - depth <= 0)'];
        end
    end
    if isempty(hs)
        if ~isempty(meta.snow_msg)
            meta.msg = [meta.snow_msg, ' — try the fixed h selection.'];
        else
            meta.msg = 'No reflector-height variant selected.';
        end
        return;
    end

    % --- Specular-point ENU per epoch ---------------------------------------
    H = sigma0_math();
    hour_d = hours(td - day0);          % fractional local hours since midnight
    for hi = 1:numel(hs)
        h_v = hs{hi};
        h_v(eld <= 0) = NaN;            % below-horizon epochs are invalid
        x  = H.spec_offset(h_v, eld);   % NaN h propagates
        Ee = x .* sind(azd);
        Nn = x .* cosd(azd);
        series(end+1) = struct('label', hl{hi}, 't', td, 'hour', hour_d, ...
            'E', Ee, 'N', Nn, 'h_m', h_v, ...
            'n_valid', sum(isfinite(Ee) & isfinite(Nn)));            %#ok<AGROW>
    end
    if all([series.n_valid] == 0)
        series = series([]);
        meta.msg = sprintf('No valid specular-point epochs on %s.', ...
                           string(day0, 'yyyy-MM-dd'));
    end
end

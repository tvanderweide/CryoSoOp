function n = find_overflows(in_path, out_path, opts)
% Extract overflow-affected capture base names, from either the cryosoop
% per-run events.csv logs OR a legacy UHD stdout capture log.
%
% Usage:
%   find_overflows('...\<DATA_ROOT>', '...\Static\overflow_timestamps.txt')
%       (auto -> events mode: directory of cryosoop per-run subfolders)
%   find_overflows('...\<run>\events.csv', '...\overflow_timestamps.txt')
%       (auto -> events mode: a single events.csv)
%   find_overflows('...\Setup\sdr_capture.log', '...\overflow_timestamps.txt')
%       (auto -> log mode: a legacy UHD rx_samples_to_file stdout log)
%   find_overflows(..., struct('mode','events','count_events',{{'O','S','RINGFULL'}}))
% Returns the number of unique flagged captures.
%
% opts (optional struct):
%   opts.mode         'auto' (default) | 'log' | 'events'. Auto picks events
%                     when in_path is a directory or a *.csv file, else log.
%   opts.count_events events that mark a capture as overflowed, default
%                     {'O','S'} (the in-/out-of-sequence RX overflows — the
%                     same scientific meaning as the legacy log flag). Opt in
%                     to device-side gap drops or host-side ring drops by
%                     adding 'GAP'/'NEGGAP'/'RINGFULL'.
%
% ---- events.csv format (cryosoop; see DataCollection/README.md "Output contract") ----
% Header: wall_iso,host_unix_us,device_time_s,event,band_hz,ant_pair,chan,value,detail
% The 4th field is the event code; the LAST field is `detail`. A capture emits
% a FILE_WRITTEN row at the end of its write, whose detail is the capture base
% name `<prefix><stamp>` (NO _chN.dat suffix) — exactly the base compute_L1 /
% compute_calib key on. Any O/S (or opted-in) event logged since the previous
% FILE_WRITTEN flags the capture that FILE_WRITTEN closes. cryosoop writes one
% events.csv per run under <DATA_ROOT>/<YYYYMMDD>/<HHMMSS>/; a directory input
% aggregates over every **/events.csv beneath it.
%
% ---- legacy UHD stdout log (rx_samples_to_file, one process per capture) ----
%   Creating file....
%   /mnt/snowData/SDR/Data/<base>.dat
%   ... device setup, streaming ...
%   Got an overflow indication. Please do the following: <- if overflow
%   Done!
% UHD prints the overflow banner once per capture process, so one match = one
% overflowed capture (samples drop mid-stream but the file stays above the size
% gate, so these are NOT in rejected_sig.csv).
%
% Output: unique base names (e.g. UHF_20251231041025), one per line. Read by
% BrundageSoOp_viewer (Data-availability red bars) and compute_snr.

    if nargin < 3 || isempty(opts), opts = struct(); end
    mode         = getopt(opts, 'mode', 'auto');
    count_events = string(getopt(opts, 'count_events', {'O', 'S'}));

    if strcmpi(mode, 'auto')
        mode = detect_mode(in_path);
    end

    switch lower(mode)
        case 'events'
            flagged = collect_events(in_path, count_events);
        case 'log'
            flagged = collect_log(in_path);
        otherwise
            error('find_overflows: unknown mode ''%s'' (use auto|log|events).', mode);
    end

    flagged = unique(flagged);
    n = numel(flagged);
    write_flagged(out_path, flagged);
    fprintf('[find_overflows] %s mode: %d unique overflowed captures -> %s\n', ...
            lower(mode), n, out_path);
end


% =========================================================================
function mode = detect_mode(in_path)
% Auto: a directory or a *.csv file is events; anything else is a log.
    if isfolder(in_path)
        mode = 'events';
        return;
    end
    [~, ~, ext] = fileparts(char(in_path));
    if strcmpi(ext, '.csv')
        mode = 'events';
    else
        mode = 'log';
    end
end


% =========================================================================
function flagged = collect_events(in_path, count_events)
% Aggregate flagged base names over one events.csv, or every **/events.csv
% beneath a directory (cryosoop per-run layout).
    if isfolder(in_path)
        files = dir(fullfile(in_path, '**', 'events.csv'));
        if isempty(files)
            fprintf('[find_overflows] No events.csv found under %s.\n', in_path);
            paths = strings(0, 1);
        else
            paths = fullfile(string({files.folder}'), string({files.name}'));
        end
    else
        paths = string(in_path);
    end
    flagged = strings(0, 1);
    for p = reshape(paths, 1, [])
        flagged = [flagged; collect_events_file(p, count_events)]; %#ok<AGROW>
    end
end


% =========================================================================
function flagged = collect_events_file(csv_path, count_events)
% Scan one events.csv: flag the capture a FILE_WRITTEN closes if any counted
% event (O/S by default) was logged since the previous FILE_WRITTEN.
    flagged = strings(0, 1);
    fid = fopen(csv_path, 'r');
    if fid < 0
        warning('find_overflows:openEvents', 'cannot open %s — skipped.', csv_path);
        return;
    end
    closer = onCleanup(@() fclose(fid));

    pending = false;   % a counted event seen since the last FILE_WRITTEN
    fgetl(fid);        % discard header row
    line = fgetl(fid);
    while ischar(line)
        if ~isempty(strtrim(line))
            % Split on commas: event codes and base names never contain commas,
            % and detail (the only possibly-quoted field) is last, so field 4
            % (event) and parts(end) (detail) are both safe with a plain split.
            parts = split(string(line), ',');
            if numel(parts) >= 4
                event = strtrim(parts(4));
                if event == "FILE_WRITTEN"
                    if pending
                        base = strtrim(parts(end));
                        if strlength(base) > 0
                            flagged(end+1, 1) = base; %#ok<AGROW>
                        end
                    end
                    pending = false;   % reset accumulator for the next capture
                elseif any(event == count_events)
                    pending = true;
                end
            end
        end
        line = fgetl(fid);
    end
end


% =========================================================================
function flagged = collect_log(log_path)
% Legacy UHD stdout log: base name follows each "Creating file...." line; a
% "Got an overflow indication" line flags the capture currently streaming.
    flagged = strings(0, 1);
    fid = fopen(log_path, 'r');
    if fid < 0
        error('find_overflows: cannot open %s', log_path);
    end
    closer = onCleanup(@() fclose(fid));

    current = "";          % base name of the capture currently streaming
    pending_file = false;  % previous line was "Creating file...."

    line = fgetl(fid);
    while ischar(line)
        if pending_file
            % Line after "Creating file...." is the full .dat path.
            [~, current] = fileparts(strtrim(line));
            pending_file = false;
        elseif contains(line, 'Creating file')
            pending_file = true;
        elseif contains(line, 'Got an overflow indication')
            if strlength(current) > 0
                flagged(end+1, 1) = string(current); %#ok<AGROW>
            end
        end
        line = fgetl(fid);
    end
end


% =========================================================================
function write_flagged(out_path, flagged)
% Write unique base names, one per line (empty file if none).
    fid_out = fopen(out_path, 'w');
    if fid_out < 0
        error('find_overflows: cannot write %s', out_path);
    end
    if ~isempty(flagged)
        fprintf(fid_out, '%s\n', flagged);
    end
    fclose(fid_out);
end


% =========================================================================
function v = getopt(s, name, default)
% opts field with a fallback when absent/empty.
    if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
        v = s.(name);
    else
        v = default;
    end
end

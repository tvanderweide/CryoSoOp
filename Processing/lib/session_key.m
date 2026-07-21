function sid = session_key(folder, root_folder)
% Return the UHD session sentinel for a capture's containing folder.
%
% The cryosoop acquisition contract makes one <DATA_ROOT>/<YYYYMMDD>/<HHMMSS>/
% run folder == one UHD session (DataCollection/README.md), so the folder is
% the exact session key for the chain-phase calibration join (compute_L2).
% Returns one of:
%   "<YYYYMMDD>/<HHMMSS>"  capture in a shape-validated per-run subfolder of
%                          the data root (cryosoop layout)
%   "legacy-flat"          capture directly in the data root; time-gap run
%                          grouping applies downstream
%   "unknown"              anything else (unexpected nesting or folder shape)
%                          — fails closed downstream: no chain calibration
%
% Keys always use '/' separators so persisted CSVs are platform-portable.
% Both inputs should come from the same dir() scan (hit .folder and the data
% root as dir() spells it) so the string comparison is apples-to-apples;
% comparison is case-insensitive on Windows.

    f = normalize_path(folder);
    r = normalize_path(root_folder);
    if ispc
        same_root  = strcmpi(f, r);
        under_root = strlength(f) > strlength(r) + 1 && ...
                     strncmpi(f, r + "/", strlength(r) + 1);
    else
        same_root  = strcmp(f, r);
        under_root = strlength(f) > strlength(r) + 1 && ...
                     strncmp(f, r + "/", strlength(r) + 1);
    end

    if same_root
        sid = "legacy-flat";
        return;
    end
    if under_root
        rel = extractAfter(f, strlength(r) + 1);
        if ~isempty(regexp(rel, '^\d{8}/\d{6}$', 'once'))
            sid = rel;
            return;
        end
    end
    sid = "unknown";
end


function p = normalize_path(p)
% Forward slashes, no trailing separator (drive roots like "C:/" keep theirs).
    p = strrep(string(p), '\', '/');
    while endsWith(p, "/") && strlength(p) > 1 && ~endsWith(p, ":/")
        p = extractBefore(p, strlength(p));
    end
end

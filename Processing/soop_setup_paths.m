function info = soop_setup_paths()
% Put the cryosoop Processing runtime folders on the MATLAB path (idempotent).
% Warns if a shared function name resolves in more than one place (path
% shadowing by another SoOp/Processing tree left on the path).

    root = fileparts(mfilename('fullpath'));
    addpath(root, ...
            fullfile(root, 'stages'), ...
            fullfile(root, 'rfi'), ...
            fullfile(root, 'lib'), ...
            fullfile(root, 'viewer'), ...
            fullfile(root, 'tools'));

    % Shadowing check: compute_L1 (a name any parallel SoOp processing tree
    % also defines) resolving in more than one place after addpath means some
    % other tree on the path can shadow the copies in this one.
    hits     = which('compute_L1', '-all');
    shadowed = numel(hits) > 1;
    if shadowed
        warning('soop:setup:shadowedPath', ...
            ['Another SoOp processing tree is active alongside this one ' ...
             '(root "%s"); compute_L1 resolves in %d place(s):\n  %s'], ...
            root, numel(hits), strjoin(hits, sprintf('\n  ')));
    end

    if nargout > 0
        info = struct('root', root, 'shadowed', shadowed);
    end
end

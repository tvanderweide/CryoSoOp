function cfg = gating_apply_config(cfg, site)
% Apply the site_config "gating" block to cfg, or clear gating when it is off.
%
% The gating fields are REMOVED first, then reassigned only when the block
% enables gating. BrundageSoOp is a script and reuses the base workspace, so a
% previous run's cfg survives into the next one; assigning only in the enabled
% branch would let a stale cfg.gating_toggle keep gating data after the
% operator sets "gating"."toggle": false.
%
% An absent block, an empty block, or a toggle that is not literally true
% leaves every cfg.gating_* field UNSET, so each consumer's
% isfield(cfg, 'gating_toggle') test runs ungated. jsondecode maps JSON null to
% [], which the ~isempty terms treat as "not specified".
    names = {'gating_toggle', 'gating_mode', 'gating_window_ms', 'gating_transition_ms'};
    stale = names(isfield(cfg, names));
    if ~isempty(stale)
        cfg = rmfield(cfg, stale);
    end

    if ~(isfield(site, 'gating') && ~isempty(site.gating) && ...
         isfield(site.gating, 'toggle') && isequal(site.gating.toggle, true))
        return;
    end

    cfg.gating_toggle        = true;
    cfg.gating_mode          = 'quiet';  % 'quiet' keeps MUOS, 'loud' keeps RFI
    cfg.gating_window_ms     = 0.5;      % rolling-power window (ms)
    cfg.gating_transition_ms = 2.0;      % blanked each side of a transition (ms)
    opt = {'mode', 'window_ms', 'transition_ms'};
    for k = 1:numel(opt)
        if isfield(site.gating, opt{k}) && ~isempty(site.gating.(opt{k}))
            cfg.(['gating_' opt{k}]) = site.gating.(opt{k});
        end
    end
    % Validated once here so no consumer has to invent a fallback.
    cfg.gating_mode = gating_mode_check(cfg.gating_mode);
end

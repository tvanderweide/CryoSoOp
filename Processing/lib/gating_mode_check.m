function mode = gating_mode_check(mode)
% Validate a time-domain gating mode and normalize it to lower case.
%
% Legal modes are 'quiet' (keep the MUOS intervals) and 'loud' (keep the RFI
% intervals). Fails closed: an unrecognized mode is a hard error at config
% load, because the three consumers (compute_L1, compute_rfi_spectrum, and the
% viewer's raw views) would otherwise each fall back differently. Gating is
% switched off with "gating"."toggle": false, not with a mode string.
    if ischar(mode) || (isstring(mode) && isscalar(mode))
        mode = lower(char(mode));
    else
        mode = '';
    end
    if ~ismember(mode, {'quiet', 'loud'})
        error('BrundageSoOp:gatingMode', ...
              ['site_config.json "gating"."mode" is ''%s''. Legal modes are ' ...
               '''quiet'' (keep the MUOS intervals) and ''loud'' (keep the RFI ' ...
               'intervals); set "gating"."toggle" to false to process ungated.'], ...
              mode);
    end
end

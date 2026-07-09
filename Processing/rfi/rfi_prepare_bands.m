function P = rfi_prepare_bands(cfg, bands, npts)
% rfi_excise operator for one dataset's band list: prepare(cfg, npts) with
% cfg.rfi_bands swapped to BANDS (N x 2 RF Hz, or empty).
%
% An empty BANDS list is a legitimate configured state — the per-dataset band
% files (rfi_bands_NL.csv / rfi_bands_L.csv) are optional, and a missing file
% means that dataset runs unexcised. Forcing rfi_methods to {'none'} for the
% empty case skips the mask build and the rfi_excise:noBands warning (this
% prepare sits in per-pair paths that would otherwise warn on every capture);
% apply() still passes through for any requested method because P.bands /
% P.mask are empty.
    cfgp = cfg;
    cfgp.rfi_bands = bands;
    if isempty(bands)
        cfgp.rfi_methods = {'none'};
    end
    P = rfi_excise().prepare(cfgp, npts);
end

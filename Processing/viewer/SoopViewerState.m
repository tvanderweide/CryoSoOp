classdef SoopViewerState < handle
% Explicit shared state for the split BrundageSoOp_viewer.
%
% One handle object replaces the parent-scope `S` struct + the loose locals
% (cfg, M, Erfi, npts, ...) of the original single-function viewer. Property
% names are preserved from the original `S.*` fields so the module bodies stay
% a mechanical `S.` -> `V.` (via a `S = V;` alias) rewrite. All viewer modules
% take this object as their first argument.

    properties (Constant)
        % Sentinel ItemsData values for the two synthetic Dataset entries (not
        % real product dirs). Verbatim from the original viewer.
        COMPARE_DATASET  = '__compare_base_notch__';
        CHAINCAL_DATASET = '__notch_chaincal__';
    end

    properties
        % ---- cfg + derived constants ----
        cfg                 % MUTABLE cfg copy (Dataset dropdown rewrites cfg.out_dir)
        npts
        n_want
        calib_N_looks
        base_out_dir
        notch_out_dir
        rfi_dir

        % ---- libraries ----
        M                   % BrundageSoOp_fun() handle struct
        Erfi                % rfi_excise() handle struct

        % ---- catalog ----
        PLOT_INFO
        CAP_PATTERNS

        % base_name -> containing folder map for raw captures (containers.Map,
        % char keys). Under the cryosoop layout captures live in per-run
        % subfolders <data_root>/<YYYYMMDD>/<HHMMSS>/; the recursive discovery
        % records each capture's actual folder here so rr_load_capture reads
        % from the right place. Old flat-season data maps base -> data_dir.
        cap_folders

        % ---- module handle structs ----
        CB
        U
        D

        % ---- data tables + caches ----
        L1
        CAL
        L2
        CAND
        WX
        OVF
        cache
        calib_base_cache
        calib_notch_cache

        % ---- RFI-explorer export state ----
        rfi_bands
        rfi_src
        rfi_chan

        % ---- render state ----
        busy
        pending
        last_n
        ov_title
        ov_xlabel
        ov_ylabel
        ov_plot_kind

        % ---- outer grid layout (row 3 toggled by render_now) ----
        gl

        % ---- UI widget handles ----
        fig
        dd_plot
        dd_agg
        dp1
        dp2
        cb_depth
        cb_airtc
        cb_tempc
        dd_method
        dd_domain
        dd_ctype
        dd_cap
        btn_prev
        btn_next
        lbl_cap
        rfi_row
        rfi_dataset
        rfi_excess
        rfi_sk
        rfi_gap
        rfi_gap_ef
        rfi_usesk
        btn_rfi_export
        lbl_rfi
        panel
        ef_title
        ef_xlabel
        ef_ylabel
        sp_fs_title
        sp_fs_label
        sp_fs_legend
        sp_fs_tick
        dd_legend
        sw_units
        units_row
        sw_gain
        gain_row
        sw_snr
        snr_row
        sw_ampscale
        ampscale_row
        sw_detrend
        detrend_row
        lbl_settings
        lbl_expl
        lbl_math
        src_box
    end
end

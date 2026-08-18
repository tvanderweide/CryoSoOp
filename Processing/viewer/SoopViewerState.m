classdef SoopViewerState < handle
% Shared mutable state for BrundageSoOp_viewer modules and callbacks.
% All viewer modules receive this handle object as their first argument.

    properties (Constant)
        % Sentinel ItemsData values for synthetic Dataset entries that do not
        % represent product directories.
        COMPARE_DATASET  = '__compare_base_notch__';
        CHAINCAL_DATASET = '__notch_chaincal__';

        % Daily AboveFreezing-nearest matching and display defaults.
        % LINE_WIDTH is the spinner's initial value in points, sized so
        % consecutive warm days abut with
        % no gap: a full season across the default 1500 px window leaves
        % roughly 4-5 points per day. Rules share one color, so the slight
        % overlap at narrower spans is invisible; widen this if a hairline
        % shows on a wider window; users can adjust it per viewer session.
        ABOVE_FREEZING_THRESHOLD_C = 0;
        ABOVE_FREEZING_NEAREST_WINDOW_MIN = 35;
        ABOVE_FREEZING_NEAREST_LINE_WIDTH = 6;
        % SnowTemp - Nearest: match tolerance for pairing a kept capture with a
        % DTC profile, sized for the station's 15-minute logging cadence. Held
        % separately from the AboveFreezing window so the two features stay
        % independent. Band width is in PIXELS (not points) so it needs no DPI
        % conversion and stays meaningful in headless renders.
        SNOWTEMP_NEAREST_WINDOW_MIN = 35;
        SNOWTEMP_NEAREST_BAND_PX = 8;
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
        % from the right place. Flat-layout captures map base -> data_dir.
        cap_folders

        % ---- module handle structs ----
        CB
        U
        D

        % ---- data tables + caches ----
        L1
        CAL
        L2
        SIG0
        CAND
        WX
        OVF
        OVF_ok = false      % true when an overflow list file was found (gates cb_ovf)
        OVF_src = ""        % resolved overflow-list path ("" when none found)
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
        cb_swe
        cb_airtc
        cb_tempc
        cb_abvfrz
        cb_snowtemp
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
        sw_phaseoff
        phaseoff_row
        sw_detrend
        detrend_row
        cb_tod
        ef_tod
        tod_row
        cb_abvfrz_nearest
        abvfrz_nearest_row
        sp_abvfrz_nearest_linew
        abvfrz_nearest_width_row
        cb_snowtemp_nearest
        snowtemp_nearest_row
        cb_soilvwc
        soilvwc_row
        cb_phline
        phline_row
        sp_snrcut
        snrcut_row
        cb_ovf
        ovf_row
        cb_theory
        dd_thanchor
        theory_row
        ef_fringe
        fringe_row
        cb_hourcolor
        hour_row
        cb_snrcolor
        snrcolor_row
        sp_linew
        sp_ptsz
        style_row
        cb_geom_r2
        cb_geom_r1
        cb_geom_aeff
        dd_geom_h
        geom_row
        dd_map_sat
        dd_map_h
        dp_map
        map_row
        lbl_settings
        lbl_expl
        lbl_math
        src_box
    end
end

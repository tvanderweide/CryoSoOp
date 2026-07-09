function w = rfi_env_window(env_khz, df_hz)
% Odd movmedian window (in bins) for a PSD envelope/baseline of width env_khz
% (kHz) at a frequency-bin spacing of df_hz (Hz).
%
% Single definition of the "kHz -> smoothing window" conversion so every
% envelope smooths by the same cfg.rfi_env_khz width: the season-aggregate
% figure and per-capture occupancy baseline (compute_rfi_spectrum), the
% band-finder gate (rfi_propose_bands), the interactive explorer
% (soop_viewer_render_rfi), and the single-capture Raw: PSD / Raw: FFT
% Amplitude displays (soop_viewer_render_raw). df_hz is the native FFT bin
% spacing for the stage/finder and the decimated display-bin spacing for the
% viewer displays.
    w = round(env_khz * 1e3 / df_hz);
    w = max(3, w + (1 - mod(w, 2)));   % force odd, >= 3
end

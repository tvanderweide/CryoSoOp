function [quiet_mask, loud_mask] = get_gating_masks(ch0, ch1, fs, margin_ms, period_ms, width_ms)
% Compute masks for "quiet" (MUOS) and "loud" (RFI) time-series segments from
% raw IQ data. Process: calculates per-sample power for both channels, finds 
% median per-channel power, and normalizes powers. Then, using experimental
% period time (period_ms), separates power data into periods, and takes
% mean across all periods (creating period power profile). Cross correlates
% this profile with a rectangular pulse of with experimental pulse width
% (width_ms). Peak lag indicates RFI pulse offset. Smooths power and finds
% edges and centers of RFI pulses, by looking at median power (near MUOS
% baseline), looking where the threshold is crossed. Accounts for pulses
% which are cut off by beginning or end of recording. Looks near
% theoretical boundary of pulse to see if the pulse is wider than expected
% (or offset from center). Finally, masks any other RFI spikes which are
% separate from regular pulses.
%
% Inputs:
%   ch0 (ch1)   Raw ch0 (ch1) I/Q data (already loaded in compute_L1.m,
%   compute_rfi_spectrum.m, or soop_viewer_render_raw.m).
%   fs          Sampling frequency in Hertz.
%   margin_ms   Guard band margin padding on each side of RFI pulse (ms).
%   period_ms   RFI pulse period (ms).
%   width_ms    RFI pulse width (ms).
% Outputs:
%   quiet_mask  Mask setting all samples containing RFI pulse to 0
%   loud_mask   Mask setting all samples not containing RFI pulse to 0

    iq_data = [ch0(:), ch1(:)];
    num_samples    = size(iq_data, 1);
    period_samples = round(fs * (period_ms / 1000));
    width_samples  = round(fs * (width_ms  / 1000));
    margin_samples = round(fs * (margin_ms / 1000));
    num_periods = floor(num_samples / period_samples);

    % Find normalized power in time across channels
    p_ch = abs(iq_data).^2;
    med_p = median(p_ch, 1);
    med_p(med_p == 0) = eps;
    p_comb = sum(p_ch ./ med_p, 2);

    % Find offset of RFI pulse by wrapping over ~100ms estimated pulse
    % period and averaging across both channels.
    p_truncated    = p_comb(1 : num_periods * period_samples);
    p_stacked      = reshape(p_truncated, period_samples, num_periods);
    xperiod_mean = mean(p_stacked, 2);

    % Cross correlates period-length power average with rectangular pulse to
    % find offset (peak lag).
    rect_pulse = zeros(period_samples, 1);
    rect_pulse(1:width_samples) = 1;
    xcorr_period_pulse = real(ifft(fft(xperiod_mean) .* conj(fft(rect_pulse))));
    [~, phi_0] = max(xcorr_period_pulse);

    % Find edges of RFI pulses by smoothing power and finding pulse centers, 
    % allowing for larger than expected (49.98ms) pulses, and catching pulses 
    % which are cut off at the beginning or end of the file.
    loud_mask = false(num_samples, 1);
    N_smooth = round(fs * 0.0005);
    p_smooth = movmean(p_comb, N_smooth);
    p_thresh = median(p_comb) * 2.5;
    N_search = round(fs * 0.0030);
    c_offset_in_period = phi_0 + floor(width_samples / 2);

    % Iterate through each pulse, adjusting individual centers and edges
    m_min = -1;
    m_max = num_periods + 1;
    max_expand = round(fs * 0.010);
    for m = m_min:m_max
        c_nom = c_offset_in_period + m * period_samples;
        max_extent = floor(width_samples / 2) + margin_samples + max_expand;
        if (c_nom + max_extent < 1) || (c_nom - max_extent > num_samples)
            continue;
        end
        w_start = max(1, c_nom - N_search);
        w_end   = min(num_samples, c_nom + N_search);
        if w_start <= w_end
            [~, rel_idx] = max(p_smooth(w_start:w_end));
            c_true = w_start + rel_idx - 1;
        else
            c_true = c_nom; 
        end
        rfi_start = c_true - floor(width_samples / 2) - margin_samples;
        rfi_end   = rfi_start + width_samples + (2 * margin_samples) - 1;
        left_bound = max(1, rfi_start - max_expand);
        while rfi_start > left_bound && rfi_start <= num_samples && p_smooth(rfi_start) > p_thresh
            rfi_start = rfi_start - 1; end
        right_bound = min(num_samples, rfi_end + max_expand);
        while rfi_end < right_bound && rfi_end >= 1 && p_smooth(rfi_end) > p_thresh
            rfi_end = rfi_end + 1; end
        clip_start = max(1, rfi_start);
        clip_end   = min(num_samples, rfi_end);
        if clip_start <= clip_end
            loud_mask(clip_start:clip_end) = true;
        end
    end

    % Mask out any RFI spikes outside of regular pulses
    N_min_spike = round(fs * 0.0005);
    raw_spikes  = (p_smooth > p_thresh);
    d = diff([0; raw_spikes; 0]);
    spike_starts = find(d == 1);
    spike_ends   = find(d == -1) - 1;
    valid_spikes = (spike_ends - spike_starts + 1) >= N_min_spike;
    for k = find(valid_spikes)'
        loud_mask(spike_starts(k):spike_ends(k)) = true;
    end
    quiet_mask = ~loud_mask;
end
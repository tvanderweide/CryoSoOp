function [quiet_mask, loud_mask] = get_gating_masks(iq_data, fs, window_ms, blank_ms)
% Time domain mask generation for RFI pulse removal (specific to CSSL).
%
% Computes masks for "quiet" (MUOS) and "loud" (RFI) time-series segments
% from raw IQ data.
%
% Evaluates a sliding-window average power against a threshold to
% distinguish loud and quiet. Blanks blank_ms at BOTH capture ends and on
% each side of every internal transition, so a capture with one transition
% loses 4*blank_ms in total and a capture with none still loses 2*blank_ms.
%
% Inputs:
%   iq_data     Array of complex time-domain IQ samples (row or column).
%   fs          Sampling frequency in Hertz (Hz).
%   window_ms   Rolling average integration window duration (ms).
%   blank_ms    Removal band duration applied to run boundaries (ms).
%
% Outputs:
%   quiet_mask  Logical, same size and orientation as iq_data, marking quiet
%               intervals outside the blanked bands.
%   loud_mask   Same, for loud (RFI) intervals. The two masks are disjoint.
%
% Thresholding calculates midpoint between the 10th and 90th power
% percentiles (P10/P90). Standard array sorting if no Statistics Toolbox.
% The threshold assumes bimodal power: on data without pulsed RFI it splits
% a flat distribution at its own midpoint and rejects most of the capture.

    power_sq = abs(iq_data).^2;
    window_samples = round(fs * (window_ms / 1000));
    rolling_power = movmean(power_sq, window_samples);

    try
        p10 = prctile(rolling_power, 10);
        p90 = prctile(rolling_power, 90);
    catch
        sorted_p = sort(rolling_power);
        p10 = sorted_p(max(1, round(0.10 * numel(sorted_p))));
        p90 = sorted_p(max(1, round(0.90 * numel(sorted_p))));
    end
    threshold = (p10 + p90) / 2.0;

    is_loud = rolling_power > threshold;

    % Run boundaries are forced to a COLUMN with (:): find() inherits the
    % orientation of its input, so a row-vector iq_data would otherwise make
    % this concatenation a dimension mismatch.
    edge_indices = find(diff(double(is_loud)) ~= 0);
    boundaries = [1; edge_indices(:) + 1; numel(iq_data) + 1];
    blank_samples = round(fs * (blank_ms / 1000));

    quiet_mask = false(size(iq_data));
    loud_mask  = false(size(iq_data));

    for i = 1:(numel(boundaries) - 1)
        start_idx = boundaries(i);
        end_idx   = boundaries(i+1) - 1;

        mid_idx = floor((start_idx + end_idx) / 2);
        state_is_loud = is_loud(mid_idx);

        safe_start = start_idx + blank_samples;
        safe_end   = end_idx - blank_samples;

        if safe_start <= safe_end
            if state_is_loud
                loud_mask(safe_start:safe_end) = true;
            else
                quiet_mask(safe_start:safe_end) = true;
            end
        end
    end
end

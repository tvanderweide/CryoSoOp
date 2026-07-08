function soop_run_pipeline(cfg, toggles)
% Run the Brundage SoOp processing pipeline for one cfg and a set of toggles.
%
% Extracted verbatim from the BrundageSoOp.m entry script so the same dispatch
% logic can be driven programmatically (verification harness) and from the
% user-facing entry alike. The entry script builds cfg and toggles, then calls
% this; the viewer is launched by the entry, not here.
%
%   soop_run_pipeline(cfg, toggles)
%
% toggles is a struct of logical fields:
%   toggles.run_L1     - compute_L1              (L1 cross-correlation products)
%   toggles.run_calib  - compute_calib           (NL/L calibration CSV)
%   toggles.run_snr    - compute_snr             (SNR distribution / threshold)
%   toggles.run_satid  - compare_sat_candidates  (sat_candidates_corrected.csv)
%   toggles.run_L2     - compute_L2              (elevation-corrected L2 series)
%   toggles.run_rfi    - compute_rfi_spectrum    (season RFI diagnostic + bands)
%
% Behaviour matches the original entry: L1 + calib process every cfg.rfi_methods
% entry in a single read/FFT pass; the downstream stages (snr, sat-id, L2) are
% RFI-unaware and run once per method dir, overriding only cm.out_dir.

%% Parallel pool (only when processing; the viewer doesn't need workers)
if any([toggles.run_L1, toggles.run_calib, toggles.run_snr, toggles.run_rfi]) && ~cfg.use_gpu && isempty(gcp('nocreate'))
    % Size the pool from the SLURM allocation, not the node's physical core
    % count (the default), which oversubscribes a cgroup-limited job. Works
    % in all three contexts: sbatch (env vars set), TurboVNC GUI on Borah
    % (also a SLURM job, so the pool matches that session's allocation),
    % and plain local MATLAB (falls back to physical cores). A pool already
    % open in a GUI session is reused as-is.
    nw = str2double(getenv('SLURM_CPUS_PER_TASK'));
    if isnan(nw), nw = feature('numcores'); end
    c = parcluster('Processes');
    job_id = getenv('SLURM_JOB_ID');
    if ~isempty(job_id)
        % Job-unique pool metadata dir — concurrent MATLAB jobs sharing the
        % default ~/.matlab location corrupt each other's pool state.
        % Root comes from site_config.json (paths.hpc.matlab_jobs) via
        % cfg.matlab_jobs_dir; the literal fallback keeps old cfg structs working.
        if isfield(cfg, 'matlab_jobs_dir')
            jobs_root = cfg.matlab_jobs_dir;
        else
            jobs_root = '/bsuscratch/thomasvanderweide/BrundageSoOp/matlab_jobs';
        end
        js = fullfile(jobs_root, job_id);
        if ~isfolder(js), mkdir(js); end
        c.JobStorageLocation = js;
    end
    parpool(c, nw);
    fprintf('[BrundageSoOp] parpool: %d workers.\n', nw);
end

%% Run
% L1 + calib process every cfg.rfi_methods entry in a single read/FFT pass,
% writing one product dir per method (base / _notch).
if toggles.run_L1,    compute_L1(cfg);    end
if toggles.run_calib, compute_calib(cfg); end
% Season RFI diagnostic (method-independent; reads raw data, writes to base).
if toggles.run_rfi,   compute_rfi_spectrum(cfg); end % — intentional toggle

% Downstream stages (snr, sat-id, L2) are not RFI-aware, so run them once per
% method dir, overriding only cm.out_dir. The season inputs they read (overflow
% list, elevation tables via cfg.elev_dir/cfg.elev_table, RFI bands) are
% decoupled from out_dir into cfg.input_dir, so no per-method copying is needed.
% With cfg.rfi_methods = {'none'} this loops once over cfg.out_dir.
if any([toggles.run_snr, toggles.run_satid, toggles.run_L2])
    E_rfi = rfi_excise();
    for mi = 1:numel(cfg.rfi_methods)
        cm = cfg;
        cm.out_dir = E_rfi.method_out_dir(cfg.out_dir, cfg.rfi_methods{mi});
        if ~isfolder(cm.out_dir), mkdir(cm.out_dir); end
        if toggles.run_snr,    compute_snr(cm);            end % — intentional toggle
        if toggles.run_satid,  compare_sat_candidates(cm); end
        if toggles.run_L2,     compute_L2(cm);             end
    end
end
end

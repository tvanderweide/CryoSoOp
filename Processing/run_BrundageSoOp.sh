#!/bin/bash
#SBATCH -J BrundageSoOp
#SBATCH -p cryogars
#SBATCH -n 1
#SBATCH -c 32
#SBATCH -t 24:00:00
#SBATCH -o /bsuscratch/thomasvanderweide/logs/BrundageSoOp_%j.out
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=thomasvanderweide@boisestate.edu

# Full-season Brundage SoOp L1 + calibration run (headless).
# Interruption-safe: if walltime expires or the job is cancelled, at most one
# batch (cfg.batch_size pairs) is lost — just sbatch again to resume.
#
# Estimated 6-10 h for ~25k pairs at the bench rate (41 pairs/min, 20 cores);
# 24 h walltime leaves margin for scratch-filesystem I/O.
#
# Logging: one file per job at the -o path above. stderr merges into the same
# file (no -e given), so MATLAB errors/warnings, module errors, and the
# fprintf batch progress all land in the per-job log. Watch with:
#   tail -f /bsuscratch/thomasvanderweide/logs/BrundageSoOp_<jobid>.out

echo "[$(date '+%F %T')] BrundageSoOp job ${SLURM_JOB_ID} starting on $(hostname)"

module load matlab/r2023b || { echo "[$(date '+%F %T')] FATAL: module load matlab/r2023b failed"; exit 1; }

# TODO: confirm Borah deploy path once the cryosoop B210 season is provisioned
cd /bsuhome/thomasvanderweide/Documents/CryoSoOp/Processing || { echo "[$(date '+%F %T')] FATAL: cd to script dir failed"; exit 1; }

echo "[$(date '+%F %T')] launching matlab -batch BrundageSoOp"
matlab -batch "BrundageSoOp"
status=$?
echo "[$(date '+%F %T')] matlab exited with status ${status}"
exit ${status}

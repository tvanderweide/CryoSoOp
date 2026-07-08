#!/bin/bash
# radiometer_run.sh -- CryoSoOp radiometer cron wrapper (Raspberry Pi, run as root).
#
# Adapted from the hardened SoOp production script
# (SoOp/Collection/cpp_run_test_2025-12-15.bash). Deliberately THIN: the entire
# NL / L / Signal capture sequence (including any BBB GPIO state hooks) runs INSIDE
# the cryosoop binary in one UHD session -- this wrapper only does the field-safety
# envelope: root check, mount + free-space guard, performance governor with restore,
# a hard timeout, one binary invocation, and the production reboot-on-failure path.
#
# Cron (matches the SoOp even-hour :10 schedule):
#   10 */2 * * * /home/SDR/CryoSoOp/orchestration/radiometer_run.sh >> /var/log/cryosoop_radiometer_cron.log 2>&1
#
# Manual long (30-min ring-buffered) capture -- NOTE: point --save-loc OUTSIDE the
# rsync-pulled Data/ tree so the VM does not pull a huge diagnostic mid-write:
#   cryosoop --config /home/SDR/CryoSoOp/config/radiometer_B210.yaml \
#           --duration 1800 --save-loc /mnt/snowData/SDR/Diag --ring-mb 12288
#
# TIMEOUT SCOPE (changed vs the 2025-12-15 original): RX_TIMEOUT_SEC is a SINGLE OS
# timeout wrapped around the WHOLE single-UHD-session NL/L/Signal sequence, not the
# per-capture 240 s timeout the SoOp script applied around each capture. This is
# deliberate: the NL phase-calibration invariant requires the entire sequence to run in
# one uninterrupted UHD session (see README.md "Why one UHD session"), so the wrapper cannot bound
# individual captures without risking a mid-sequence kill. Guidance: set RX_TIMEOUT_SEC
# to >= 2x the expected full-sequence duration. In-binary hang protection is independent
# of this envelope -- the binary uses 1 s recv timeouts with a consecutive-timeout abort,
# so a wedged stream is caught internally long before this OS timeout fires.
#
# OUTPUT LAYOUT: this script's behaviour is UNCHANGED -- it still passes --save-loc
# "$DATA_DIR". The binary now treats that as a ROOT and creates a per-run subfolder
# "$DATA_DIR"/<YYYYMMDD>/<HHMMSS>/ for each invocation, holding that run's .dat files plus
# events.csv / RunLog.log / config_effective.yaml / summary.json (no cross-run append or
# overwrite). So each two-hourly cron run lands in its own dated subfolder under DATA_DIR.
#
# SITE CONFIGURATION: per-site values live in <project>/config/site.env (sourced and
# exported below, so cryosoop's exec_hook children -- bbb_set_state.sh -- inherit the
# BBB_* / GPIO_PINS / *_VALS settings too). Edit THAT file for a new deployment; the
# in-script defaults below only apply when site.env is absent. Because site.env
# assignments override any environment set on the crontab line, a one-off manual
# override needs the site file skipped: SITE_ENV=/dev/null DATA_DIR=... radiometer_run.sh
#
# Variables (defaults used when site.env is absent):
#   SITE_ENV        site settings file          [<project>/config/site.env]
#   MOUNT           data mount point            [/mnt/snowData]
#   DATA_DIR        capture output dir          [/mnt/snowData/SDR/Data]
#   MIN_FREE_GB     minimum free space (GB)     [8]
#   NVME_MIN_MBPS   min NVMe write throughput   [400]  (YAML key: DISK.nvme_min_mbps)
#   CONFIG          radiometer YAML             [<project>/config/radiometer_B210.yaml]
#   CRYOSOOP_BIN     path to cryosoop binary      [autodetect under project, then PATH]
#   RX_TIMEOUT_SEC  hard timeout for the run    [1200]  (whole-sequence; see TIMEOUT SCOPE)
#   REBOOT_ON_FAIL  1 = reboot on nonzero exit  [1]  (production default)
#   DEFAULT_GOV     governor to restore on exit [ondemand]

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "ERROR: This script must be run as root (governor + reboot path)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Per-site settings (exported so cryosoop's exec_hook children inherit the BBB_* values).
SITE_ENV="${SITE_ENV:-${PROJECT_DIR}/config/site.env}"
if [ -f "$SITE_ENV" ]; then
  set -a
  # shellcheck source=../config/site.env
  . "$SITE_ENV"
  set +a
fi

MOUNT="${MOUNT:-/mnt/snowData}"
DATA_DIR="${DATA_DIR:-/mnt/snowData/SDR/Data}"
MIN_FREE_GB="${MIN_FREE_GB:-8}"
NVME_MIN_MBPS="${NVME_MIN_MBPS:-400}"   # min NVMe write MB/s; YAML key DISK.nvme_min_mbps
CONFIG="${CONFIG:-${PROJECT_DIR}/config/radiometer_B210.yaml}"
RX_TIMEOUT_SEC="${RX_TIMEOUT_SEC:-1200}"
REBOOT_ON_FAIL="${REBOOT_ON_FAIL:-1}"
DEFAULT_GOV="${DEFAULT_GOV:-ondemand}"

# Locate the cryosoop binary if not provided.
if [ -z "${CRYOSOOP_BIN:-}" ]; then
  for cand in "${PROJECT_DIR}/build/cryosoop" "${PROJECT_DIR}/cryosoop" "${PROJECT_DIR}/bin/cryosoop"; do
    if [ -x "$cand" ]; then CRYOSOOP_BIN="$cand"; break; fi
  done
  [ -z "${CRYOSOOP_BIN:-}" ] && CRYOSOOP_BIN="$(command -v cryosoop || echo cryosoop)"
fi

log() { echo "[$(date -u --iso-8601=seconds)] $*"; }  # UTC, matching cryosoop's stamps

# --- pre-flight: mount present ---
if ! mountpoint -q "$MOUNT"; then
  echo "ERROR: $MOUNT is not mounted. Aborting." >&2
  logger -t cryosoop_radiometer "abort: $MOUNT not mounted"
  exit 1
fi

# --- pre-flight: free space ---
free_kb=$(df --output=avail "$MOUNT" | tail -n1)
free_gb=$((free_kb / 1024 / 1024))
if [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
  echo "ERROR: Only ${free_gb}GB free on $MOUNT, below ${MIN_FREE_GB}GB. Aborting." >&2
  logger -t cryosoop_radiometer "abort: only ${free_gb}GB free (< ${MIN_FREE_GB}GB)"
  exit 1
fi

# --- pre-flight: NVMe write throughput (threshold NVME_MIN_MBPS; YAML DISK.nvme_min_mbps) ---
PROBE_SCRIPT="${SCRIPT_DIR}/probe_nvme.sh"
if [ -x "$PROBE_SCRIPT" ] || [ -f "$PROBE_SCRIPT" ]; then
  if ! bash "$PROBE_SCRIPT" "$NVME_MIN_MBPS" "$MOUNT"; then
    echo "ERROR: NVMe throughput below ${NVME_MIN_MBPS} MB/s on $MOUNT. Aborting." >&2
    logger -t cryosoop_radiometer "abort: NVMe throughput < ${NVME_MIN_MBPS} MB/s"
    exit 1
  fi
else
  echo "WARN: probe_nvme.sh not found ($PROBE_SCRIPT); skipping NVMe throughput check." >&2
fi

if [ ! -x "$CRYOSOOP_BIN" ] && ! command -v "$CRYOSOOP_BIN" >/dev/null 2>&1; then
  echo "ERROR: cryosoop binary not found: $CRYOSOOP_BIN" >&2
  logger -t cryosoop_radiometer "abort: binary not found ($CRYOSOOP_BIN)"
  exit 1
fi
if [ ! -f "$CONFIG" ]; then
  echo "ERROR: config not found: $CONFIG" >&2
  logger -t cryosoop_radiometer "abort: config not found ($CONFIG)"
  exit 1
fi

# --- CPU governor: performance for the run, restore on any exit ---
GOV_FILES=(/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor)
set_governor() {
  local gov="$1" gf
  for gf in "${GOV_FILES[@]}"; do
    [ -f "$gf" ] || continue
    echo "$gov" > "$gf"
  done
}
restore_governor() { set_governor "$DEFAULT_GOV" 2>/dev/null || true; }
trap restore_governor EXIT

mkdir -p "$DATA_DIR"
set_governor performance

log "==== CryoSoOp radiometer run started ===="
log "config=$CONFIG binary=$CRYOSOOP_BIN data=$DATA_DIR free=${free_gb}GB nvme_min=${NVME_MIN_MBPS}MB/s timeout=${RX_TIMEOUT_SEC}s reboot_on_fail=${REBOOT_ON_FAIL}"

# --- single invocation: the NL/L/Signal sequence runs inside the binary ---
rc=0
timeout --foreground "$RX_TIMEOUT_SEC" \
  "$CRYOSOOP_BIN" --config "$CONFIG" --save-loc "$DATA_DIR" || rc=$?

if [ "$rc" -eq 0 ]; then
  log "==== radiometer run clean (rc=0) ===="
  logger -t cryosoop_radiometer "run clean rc=0"
elif [ "$rc" -eq 1 ]; then
  # completed-with-drops: data usable, do NOT reboot.
  log "==== radiometer run completed WITH drops (rc=1) ===="
  logger -t cryosoop_radiometer "run completed-with-drops rc=1"
else
  # fatal (2) or timeout (124) or signal: production behaviour is to reboot so the
  # next cron window starts from a clean device state.
  log "ERROR: radiometer run failed (rc=$rc)."
  logger -t cryosoop_radiometer "run FAILED rc=$rc"
  if [ "$REBOOT_ON_FAIL" -eq 1 ]; then
    log "REBOOT_ON_FAIL=1 -> rebooting."
    logger -t cryosoop_radiometer "rebooting RPi (rc=$rc)"
    restore_governor
    /usr/sbin/reboot
  else
    log "REBOOT_ON_FAIL=0 -> skipping reboot."
  fi
fi

exit "$rc"

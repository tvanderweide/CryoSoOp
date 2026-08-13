#!/bin/bash
# probe_nvme.sh -- quick sequential write-rate probe of the capture filesystem.
#
# Writes a 1 GiB throwaway file with dd (O_DIRECT, falling back to conv=fsync if the
# filesystem rejects direct I/O), parses the MB/s dd reports, prints it, and exits
# nonzero if the measured rate is below the threshold. Used by the bench checklist
# to confirm the NVMe can keep up with the capture write rate before deployment.
#
# Usage: probe_nvme.sh [MIN_MBPS] [TARGET_DIR]
#   MIN_MBPS    minimum acceptable MB/s   [400]
#   TARGET_DIR  dir to probe              [/mnt/snowData]  (env DATA_DIR overrides)
#
# Exit: 0 if rate >= MIN_MBPS, 1 if below, 2 on probe/setup error.

set -uo pipefail

MIN_MBPS="${1:-400}"
TARGET_DIR="${2:-${DATA_DIR:-/mnt/snowData}}"
COUNT_MIB="${COUNT_MIB:-1024}"   # 1 GiB

if [ ! -d "$TARGET_DIR" ]; then
  echo "ERROR: target dir does not exist: $TARGET_DIR" >&2
  exit 2
fi
if [ ! -w "$TARGET_DIR" ]; then
  echo "ERROR: target dir not writable: $TARGET_DIR" >&2
  exit 2
fi

PROBE="$TARGET_DIR/.nvme_probe.$$"
cleanup() { rm -f "$PROBE" 2>/dev/null || true; }
trap cleanup EXIT

# Parse the trailing "<value> <unit>" (e.g. "512 MB/s" or "1.2 GB/s") from dd, in MB/s.
parse_mbps() {
  echo "$1" | awk '{
    v=$(NF-1); u=$NF;
    if (u ~ /GB\/s/) v*=1000;
    else if (u ~ /kB\/s/) v/=1000;
    printf "%d", v
  }'
}

echo "Probing ${TARGET_DIR}: writing ${COUNT_MIB} MiB ..."

# Try O_DIRECT first (bypasses page cache -> true device write rate).
line="$(dd if=/dev/zero of="$PROBE" bs=1M count="$COUNT_MIB" oflag=direct 2>&1 | tail -n1)"
mode="oflag=direct"
if ! echo "$line" | grep -qE 'bytes.*copied|[0-9]+ (kB|MB|GB)/s'; then
  # O_DIRECT unsupported on this fs -> fall back to conv=fsync (flush at end).
  rm -f "$PROBE" 2>/dev/null || true
  line="$(dd if=/dev/zero of="$PROBE" bs=1M count="$COUNT_MIB" conv=fsync 2>&1 | tail -n1)"
  mode="conv=fsync"
fi

echo "dd (${mode}): ${line}"
mbps="$(parse_mbps "$line")"

if [ -z "${mbps:-}" ] || [ "$mbps" -le 0 ]; then
  echo "ERROR: could not parse dd write rate from: ${line}" >&2
  exit 2
fi

echo "Measured: ${mbps} MB/s  (threshold ${MIN_MBPS} MB/s)"
if [ "$mbps" -lt "$MIN_MBPS" ]; then
  echo "FAIL: ${mbps} MB/s < ${MIN_MBPS} MB/s"
  exit 1
fi
echo "PASS: ${mbps} MB/s >= ${MIN_MBPS} MB/s"
exit 0

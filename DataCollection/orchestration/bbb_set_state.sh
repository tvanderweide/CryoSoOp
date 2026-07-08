#!/bin/sh
# bbb_set_state.sh -- set + VERIFY the BeagleBone cal-switch GPIO state.
#
# The BBB host address, cal-switch GPIO pins, and per-state pin values are per-site
# settings: set them in config/site.env (radiometer_run.sh sources + exports it, and this
# script -- run from cryosoop's exec_hook -- inherits the values). The defaults below only
# apply when the corresponding variable is not in the environment. config/radiometer_B210.yaml's
# state_cmd / final_state_cmd hooks call this script by absolute path, so changing the IP
# or pins means editing ONLY site.env -- never the YAML.
#
# Install on the radiometer Pi (once per Pi, and again whenever this file changes):
#   sudo install -m 0755 orchestration/bbb_set_state.sh /usr/local/bin/bbb_set_state.sh
# The YAML calls /usr/local/bin/bbb_set_state.sh (absolute path: independent of where the
# repo lives, and immune to cron's minimal PATH).
#
# Usage:
#   bbb_set_state.sh NL|L|Signal        named cal state
#   bbb_set_state.sh V49 V115 V27       explicit 0/1 per pin, in GPIO_PINS order (bench/debug)
#
# Exit: 0 only if every GPIO write succeeded AND a read-back of the pin values matches the
# commanded state (set -e on the remote side) -- rc=0 means VERIFIED switch state, not just
# "ssh exited". Any nonzero rc makes cryosoop's on_cmd_fail: abort stop the run. BatchMode +
# ConnectTimeout + ServerAlive* make a dead/unreachable/password-prompting BBB fail fast
# instead of hanging exec_hook until the wrapper's whole-run timeout.
#
# Env overrides (all of them normally come from config/site.env via radiometer_run.sh):
#   BBB_HOST [root@192.168.1.101], BBB_CONNECT_TIMEOUT [15],
#   GPIO_PINS [49 115 27], NL_VALS [0 0 0], L_VALS [0 0 1], SIGNAL_VALS [1 1 0]
# Bench use without the wrapper:  set -a; . config/site.env; set +a; bbb_set_state.sh NL

set -u

# ---- defaults (per-site values belong in config/site.env, not here) -----------------------
BBB_HOST="${BBB_HOST:-root@192.168.1.101}"
GPIO_PINS="${GPIO_PINS:-49 115 27}"       # order matters: per-state values are per-pin in this order
NL_VALS="${NL_VALS:-0 0 0}"               # NL (Noise+Load)
L_VALS="${L_VALS:-0 0 1}"                 # L  (Load)
SIGNAL_VALS="${SIGNAL_VALS:-1 1 0}"       # Signal (also the end-of-run restore state)
BBB_CONNECT_TIMEOUT="${BBB_CONNECT_TIMEOUT:-15}"
# --------------------------------------------------------------------------------------------

usage() {
  echo "usage: $0 NL|L|Signal   (or three explicit 0/1 pin values in GPIO_PINS order)" >&2
  exit 2
}

case "${1:-}" in
  NL)     VALS="$NL_VALS" ;;
  L)      VALS="$L_VALS" ;;
  Signal) VALS="$SIGNAL_VALS" ;;
  [01])   [ $# -eq 3 ] || usage; VALS="$1 $2 $3" ;;
  *)      usage ;;
esac

# Remote body (single-quoted: $pins/$vals/$g/$got/$exp expand on the BBB, not here).
# set -e => fail on the FIRST bad export/direction/value write; the trailing read-back
# compares the concatenated pin values against the commanded state.
REMOTE_BODY='
set -e
for g in $pins; do
  [ -d /sys/class/gpio/gpio$g ] || echo "$g" > /sys/class/gpio/export
  echo out > /sys/class/gpio/gpio$g/direction
done
set -- $vals
for g in $pins; do echo "$1" > /sys/class/gpio/gpio$g/value; shift; done
got=""; exp=""
set -- $vals
for g in $pins; do got="$got$(cat /sys/class/gpio/gpio$g/value)"; exp="$exp$1"; shift; done
[ "$got" = "$exp" ]
'

exec ssh -o BatchMode=yes -o ConnectTimeout="$BBB_CONNECT_TIMEOUT" \
         -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
         "$BBB_HOST" "pins='$GPIO_PINS' vals='$VALS'; $REMOTE_BODY"

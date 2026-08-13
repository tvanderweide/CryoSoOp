#!/bin/sh
# test_bbb_set_state.sh -- offline tests for orchestration/bbb_set_state.sh.
#
# The GPIO cases run the REMOTE_BODY extracted verbatim from the shipped script against a fake
# /sys/class/gpio tree, so the code under test is the code that ships. The argument cases run the
# script itself with an `ssh` stub on PATH and inspect the composed remote command.
#
# Fixtures never rely on file permissions -- root ignores 0444, and these pins are driven as root
# on the BBB. An unwritable node is a directory; "no write happened" is detected by trailing-blank
# padding that any write would truncate (command substitution strips it, so reads still match).
#
# Coverage limit: plain files accept any write, so this cannot reproduce the kernel's rejection of
# a direction write on an edge-armed pin. Ordering is proved indirectly (T3: an unwritable edge
# must abort before direction is touched). Kernel behaviour is only provable on the BBB itself.
#
# Run:  sh DataCollection/tests/test_bbb_set_state.sh
# Uses dash when available (the BBB's /bin/sh); falls back to the invoking shell.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TARGET="$SCRIPT_DIR/../orchestration/bbb_set_state.sh"
[ -f "$TARGET" ] || { echo "FATAL: cannot find $TARGET" >&2; exit 2; }

# POSIX shell to run the extracted body under: dash matches the BBB's /bin/sh.
if command -v dash >/dev/null 2>&1 && dash -c ':' >/dev/null 2>&1; then
  POSIX_SH=dash
elif sh -c ':' >/dev/null 2>&1; then
  POSIX_SH=sh
  echo "NOTE: dash unavailable; running under sh ($(sh -c 'echo $0'))"
else
  echo "FATAL: no working POSIX shell to run the remote body" >&2; exit 2
fi

TMPROOT=$(mktemp -d) || exit 2
trap 'rm -rf "$TMPROOT"' EXIT INT TERM
FAILED=0
PASSED=0

ok()   { PASSED=$((PASSED + 1)); echo "  ok   - $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL - $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (want '$3', got '$2')"; fi; }

# ---- extract the shipped remote body, redirected to a fake sysfs root ------------------------
# Everything between the REMOTE_BODY=' line and the closing lone quote.
BODY=$(sed -n "/^REMOTE_BODY='\$/,/^'\$/p" "$TARGET" | sed '1d;$d')

# T5 -- extraction self-check: a silent miss here would make every other case vacuously pass.
echo "T5 extraction self-check"
case "$BODY" in
  *"/sys/class/gpio/gpio\$g/direction"*) ok "extracted body contains the direction write" ;;
  *) fail "REMOTE_BODY extraction produced nothing usable"; echo "$BODY"; exit 1 ;;
esac
case "$BODY" in
  *"/sys/class/gpio/gpio\$g/edge"*) ok "extracted body contains the edge write" ;;
  *) fail "extracted body has no edge handling" ;;
esac
SUBS=$(printf '%s\n' "$BODY" | grep -c '/sys/class/gpio')
BODY_T=$(printf '%s\n' "$BODY" | sed "s#/sys/class/gpio#\$SYSROOT#g")
SUBS_T=$(printf '%s\n' "$BODY_T" | grep -c '\$SYSROOT')
check "every /sys/class/gpio occurrence was redirected" "$SUBS_T" "$SUBS"

# run_body <sysroot> <pins> <vals> -> prints rc
run_body() {
  _root=$1; _pins=$2; _vals=$3
  "$POSIX_SH" -c "SYSROOT='$_root'; pins='$_pins'; vals='$_vals'
$BODY_T" >"$TMPROOT/out" 2>"$TMPROOT/err"
  echo $?
}

# mkpin <sysroot> <pin> <edge|-> <direction> <value>   ('-' = attribute absent)
mkpin() {
  mkdir -p "$1/gpio$2"
  [ "$3" = "-" ] || printf '%s\n' "$3" > "$1/gpio$2/edge"
  printf '%s\n' "$4" > "$1/gpio$2/direction"
  printf '%s\n' "$5" > "$1/gpio$2/value"
}
rdattr() { cat "$1" 2>/dev/null; }

# ---- T1: armed, misconfigured pins are normalised and driven --------------------------------
echo "T1 armed pins are normalised"
R="$TMPROOT/t1"; mkdir -p "$R"
mkpin "$R" 49 rising in 0
mkpin "$R" 115 both in 1
mkpin "$R" 27 none in 0
RC=$(run_body "$R" "49 115 27" "1 1 0")
check "exit code" "$RC" "0"
check "gpio49 edge"       "$(rdattr "$R/gpio49/edge")"      "none"
check "gpio115 edge"      "$(rdattr "$R/gpio115/edge")"     "none"
check "gpio49 direction"  "$(rdattr "$R/gpio49/direction")" "out"
check "gpio27 direction"  "$(rdattr "$R/gpio27/direction")" "out"
check "gpio49 value"      "$(rdattr "$R/gpio49/value")"     "1"
check "gpio115 value"     "$(rdattr "$R/gpio115/value")"    "1"
check "gpio27 value"      "$(rdattr "$R/gpio27/value")"     "0"

# ---- T2: a pin with no edge attribute still completes (the -e guard vs set -e) ---------------
echo "T2 pin without an edge attribute"
R="$TMPROOT/t2"; mkdir -p "$R"
mkpin "$R" 49 - in 0
mkpin "$R" 115 - in 0
mkpin "$R" 27 - in 0
RC=$(run_body "$R" "49 115 27" "0 0 1")
check "exit code" "$RC" "0"
check "gpio27 value" "$(rdattr "$R/gpio27/value")" "1"
check "no edge file was created" "$([ -e "$R/gpio49/edge" ] && echo yes || echo no)" "no"

# ---- T3: an unwritable edge is fatal AND aborts before direction is touched ------------------
# This is the ordering proof: an implementation that wrote direction first would leave 'out'.
# The node is made a DIRECTORY, not a read-only file: `>` on a directory fails for root too, so
# the case holds whatever identity runs the suite (the BBB drives these pins as root).
echo "T3 unwritable edge is fatal and precedes direction"
R="$TMPROOT/t3"; mkdir -p "$R"
mkpin "$R" 49 rising in 0
mkpin "$R" 115 rising in 0
mkpin "$R" 27 rising in 0
rm -f "$R/gpio49/edge"; mkdir "$R/gpio49/edge"
RC=$(run_body "$R" "49 115 27" "1 1 0")
if [ "$RC" -ne 0 ]; then ok "exit code is nonzero ($RC)"; else fail "exit code (want nonzero, got 0)"; fi
check "gpio49 direction untouched" "$(rdattr "$R/gpio49/direction")" "in"
check "gpio49 value untouched"     "$(rdattr "$R/gpio49/value")"     "0"

# ---- T4: a broken value node fails the run ---------------------------------------------------
echo "T4 unwritable value node is fatal"
R="$TMPROOT/t4"; mkdir -p "$R"
mkpin "$R" 49 none out 0
mkpin "$R" 115 none out 0
mkpin "$R" 27 none out 0
rm -f "$R/gpio115/value"; mkdir "$R/gpio115/value"
RC=$(run_body "$R" "49 115 27" "1 1 0")
if [ "$RC" -ne 0 ]; then ok "exit code is nonzero ($RC)"; else fail "exit code (want nonzero, got 0)"; fi

# ---- T6: pins already in the commanded state are not written to ------------------------------
# Write detection must not depend on file permissions (root ignores 0444). Instead every node is
# seeded with trailing blank lines: `$(cat ...)` strips them, so the body still reads the correct
# value and writes nothing, while ANY write would truncate the padding and change the file SIZE.
echo "T6 already-correct pins are left untouched"
R="$TMPROOT/t6"; mkdir -p "$R"
seedpad() { mkdir -p "$1/gpio$2"; printf '%s\n\n\n' "$3" > "$1/gpio$2/edge"
            printf '%s\n\n\n' "$4" > "$1/gpio$2/direction"
            printf '%s\n\n\n' "$5" > "$1/gpio$2/value"; }
fsize() { wc -c < "$1" | tr -d ' '; }
seedpad "$R" 49 none out 1
seedpad "$R" 115 none out 1
seedpad "$R" 27 none out 0
SZ_BEFORE=$(fsize "$R/gpio49/edge")$(fsize "$R/gpio49/direction")$(fsize "$R/gpio49/value")$(fsize "$R/gpio27/value")
RC=$(run_body "$R" "49 115 27" "1 1 0")
SZ_AFTER=$(fsize "$R/gpio49/edge")$(fsize "$R/gpio49/direction")$(fsize "$R/gpio49/value")$(fsize "$R/gpio27/value")
check "exit code" "$RC" "0"
check "padding intact => no node was written" "$SZ_AFTER" "$SZ_BEFORE"
check "no stderr" "$(wc -c < "$TMPROOT/err" | tr -d ' ')" "0"
# Guard the guard: a write really does shrink a padded node, so the check above can fail.
printf 'in\n\n\n' > "$R/gpio115/direction"
SZ_B2=$(fsize "$R/gpio115/direction"); RC=$(run_body "$R" "49 115 27" "1 1 0")
if [ "$(fsize "$R/gpio115/direction")" != "$SZ_B2" ]; then ok "a real write is detected by size"
else fail "size probe cannot detect a write (T6 would be vacuous)"; fi

# ---- T7: read-back mismatch fails the run ----------------------------------------------------
# Two pins share ONE value node via a hard link (portable, no privileges), with conflicting
# commanded values: the second write clobbers the first, so the final read-back cannot match.
echo "T7 read-back mismatch is fatal"
R="$TMPROOT/t7"; mkdir -p "$R"
mkpin "$R" 49 none out 0
mkpin "$R" 115 none out 0
mkpin "$R" 27 none out 0
rm -f "$R/gpio115/value"
if ln "$R/gpio49/value" "$R/gpio115/value" 2>/dev/null; then
  RC=$(run_body "$R" "49 115 27" "1 0 0")
  if [ "$RC" -ne 0 ]; then ok "exit code is nonzero ($RC)"; else fail "exit code (want nonzero, got 0)"; fi
else
  fail "could not hard-link the shared value node — read-back mismatch case did not run"
fi

# ---- T8: argument mapping, via an ssh stub ---------------------------------------------------
echo "T8 argument mapping"
STUB="$TMPROOT/bin"; mkdir -p "$STUB"
cat > "$STUB/ssh" <<'STUBEOF'
#!/bin/sh
# Last argument is the composed remote command; print its vals= assignment.
for a in "$@"; do last=$a; done
printf '%s\n' "$last" | sed -n "s/.*vals='\([^']*\)'.*/\1/p"
STUBEOF
chmod 0755 "$STUB/ssh"

argcase() { # argcase <label> <expected vals or RC:n> <args...>
  _label=$1; _want=$2; shift 2
  _got=$(PATH="$STUB:$PATH" "$POSIX_SH" "$TARGET" "$@" 2>/dev/null); _rc=$?
  case "$_want" in
    RC:*) check "$_label" "RC:$_rc" "$_want" ;;
    *)    check "$_label" "$_got" "$_want" ;;
  esac
}
argcase "NL maps to NL_VALS"          "0 0 0" NL
argcase "L maps to L_VALS"            "0 0 1" L
argcase "Signal maps to SIGNAL_VALS"  "1 1 0" Signal
argcase "explicit triple passes through" "1 0 1" 1 0 1
argcase "unknown state exits 2"       "RC:2"  bogus
argcase "no argument exits 2"         "RC:2"
# Pre-existing looseness pinned so it is not mistaken for validation:
argcase "trailing arg after a named state is ignored" "0 0 0" NL extra
argcase "only \$1 is validated in the explicit form"  "0 1 x" 0 1 x
argcase "explicit form with wrong arg count exits 2"  "RC:2"  1 0

# ---- assertion-count guard -------------------------------------------------------------------
# A case that silently stops running would otherwise leave the suite green. Update this number
# deliberately when adding or removing assertions.
EXPECTED_ASSERTIONS=32
TOTAL=$((PASSED + FAILED))
if [ "$TOTAL" -ne "$EXPECTED_ASSERTIONS" ]; then
  FAILED=$((FAILED + 1))
  echo "  FAIL - assertion count is $TOTAL, expected $EXPECTED_ASSERTIONS (a case did not run)"
fi

echo
echo "passed=$PASSED failed=$FAILED (body shell: $POSIX_SH)"
[ "$FAILED" -eq 0 ]

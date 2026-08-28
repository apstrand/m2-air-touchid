#!/usr/bin/env bash
# Install tracer/trace_sep.py into the m1n1 proxyclient hv dir and launch a
# guest under the m1n1 hypervisor with the SEP tracer attached, logging to file.
#
# This captures a LIVE AP<->SEP bring-up that we cannot reproduce from Linux.
# The high-value target is macOS as the guest (it drives the SEP for real), but
# note: iBoot boots the SEP before the guest runs, so against macOS you may see
# steady-state + re-pair traffic and the PMGR ps_sep accesses rather than the
# cold SEPROM boot. That is still the payoff we want; for the cold boot path,
# disassemble the staged sepfw / SEPROM instead.
#
# Booting macOS under the m1n1 hv is the heavier lift and depends on your macOS
# boot object; see the m1n1 hv docs. This wrapper handles the reusable parts:
# syncing the tracer into the m1n1 tree and running run_guest.py with logging.
# Point PAYLOAD at your guest image (a macOS boot object, or a raw m1n1+Linux
# build to smoke-test the tracer plumbing first).
#
# Usage:
#   PAYLOAD=/path/to/guest scripts/trace-sep-macos.sh [extra run_guest.py args...]
#
# Smoke-test the tracer against our own Linux build first (no macOS needed):
#   the tracer will attach and print "[sep] tracing ..." lines; you just won't
#   see a real bring-up because Linux can't boot the SEP.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
M1N1_SRC="${M1N1_SRC:-$HOME/code/m1n1}"
HVDIR="$M1N1_SRC/proxyclient/hv"

[ -d "$HVDIR" ] || { echo "error: no m1n1 hv dir at $HVDIR (set M1N1_SRC=)" >&2; exit 1; }
[ -n "${PAYLOAD:-}" ] || { echo "error: set PAYLOAD=/path/to/guest image" >&2; exit 1; }
[ -f "$PAYLOAD" ] || { echo "error: PAYLOAD not found: $PAYLOAD" >&2; exit 1; }

# 1. Sync the tracer into the m1n1 hv scripts dir (source of truth stays here).
echo "==> installing trace_sep.py into $HVDIR"
cp "$REPO/tracer/trace_sep.py" "$HVDIR/trace_sep.py"

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$REPO/out/sep-trace-$STAMP.log"
mkdir -p "$REPO/out"

# 2. Launch the guest with the tracer attached. run_guest.py runs the -m script
#    in the hv context (hv, u, p globals) after setting up the guest, then hands
#    off. -l logs the hv output to a file; we also tee for good measure.
echo "==> launching guest under hv with SEP tracer (log -> $LOG)"
cd "$M1N1_SRC/proxyclient"
exec python3 tools/run_guest.py \
    -m hv/trace_sep.py \
    -l "$LOG" \
    "$@" \
    "$PAYLOAD" 2>&1 | tee -a "$LOG"

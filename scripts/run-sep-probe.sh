#!/usr/bin/env bash
# Run the bare-metal SEP probe (tracer/sep_probe.py) against an m1n1 *proxy*.
#
# This does NOT need macOS or the hv. It talks to an m1n1 running in proxy mode
# over USB CDC-ACM and reads the SEP's AP-side state + tries the boot-ROM
# GET_STATUS handshake. It is the cheapest way to get a live yes/no on "does the
# SEP ROM answer" and to see the ps_sep / FIFO state in one shot.
#
# Prereq: an m1n1 proxy must be reachable. Our normal boot.bin chainloads
# straight to u-boot, which has NO proxy, so build a plain proxy m1n1 and
# chainload it over USB first:
#
#   1) Build a proxy m1n1 (no CHAINLOADING, so it drops to the proxy):
#        make -C "$M1N1_SRC" -j"$(nproc)" RELEASE=1 BUILDSTD=1
#   2) Put the Mac at an m1n1 stage that accepts a chainload over USB (either
#      boot our instrumented m1n1 and interrupt it, or use DFU/recovery), then
#      from THIS host push the proxy build:
#        python3 "$M1N1_SRC/proxyclient/tools/chainload.py" -r "$M1N1_SRC/build/m1n1.bin"
#   3) The Mac now exposes the proxy on a /dev/ttyACM* (the proxy interface, the
#      one that shows binary, not the text console). Point M1N1DEVICE at it.
#
# Usage:
#   M1N1DEVICE=/dev/ttyACM1 scripts/run-sep-probe.sh                 # read-only
#   M1N1DEVICE=/dev/ttyACM1 SEP_ALLOW_RESET=1 scripts/run-sep-probe.sh --reset
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
export M1N1_SRC="${M1N1_SRC:-$HOME/code/m1n1}"

[ -d "$M1N1_SRC/proxyclient" ] || {
    echo "error: no m1n1 proxyclient at $M1N1_SRC (set M1N1_SRC=)" >&2; exit 1; }

if [ -z "${M1N1DEVICE:-}" ]; then
    echo "note: M1N1DEVICE not set; m1n1 will auto-detect the first proxy port." >&2
    echo "      set M1N1DEVICE=/dev/ttyACM<n> (the proxy interface) if that fails." >&2
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$REPO/out/sep-probe-$STAMP.log"
mkdir -p "$REPO/out"

echo "==> running sep_probe.py (log -> $LOG)"
python3 "$REPO/tracer/sep_probe.py" "$@" 2>&1 | tee "$LOG"
echo "==> saved $LOG"

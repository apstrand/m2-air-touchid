#!/usr/bin/env bash
# Build a local m1n1 (with the step-5.1 SEP GETRAND instrumentation applied) and
# flash it into /boot/m1n1/boot.bin together with the SEP-enabled DTBs.
#
# Why a local m1n1 at all: update-m1n1 normally bundles the *packaged* m1n1
# (/usr/lib/asahi-boot/m1n1.bin). To get patches/0003-m1n1-log-sep-getrand.patch
# into boot.bin we build m1n1 ourselves and hand update-m1n1 an M1N1= override
# (see scripts/install-boot-bin.sh).
#
# boot.bin layout produced by update-m1n1:  m1n1.bin + DTBs + gzip(u-boot) + cfg
# so m1n1 MUST be built with CHAINLOADING=1 to hand off to the appended u-boot,
# and RELEASE=1 to match the packaged build. BUILDSTD=1 builds core/alloc from
# rust-src (Arch rust ships no aarch64-unknown-none-softfloat std).
#
# BOOT-CRITICAL (it rewrites boot.bin). See "Rollback / safety" in ../README.md.
# Only the final flash step needs root; the build does not.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
M1N1_SRC="${M1N1_SRC:-$HOME/code/m1n1}"

# SEP instrumentation patches, applied in order. Each line: "patchfile<TAB>marker"
# where <marker> is a string grep'd in src/sep.c to detect it's already applied.
PATCHES=(
    "0003-m1n1-log-sep-getrand.patch	SEP: \[dbg\] getrand"
    "0004-m1n1-dump-sep-provenance.patch	sep_dump_provenance"
)

[ -d "$M1N1_SRC" ] || { echo "error: m1n1 checkout not at $M1N1_SRC (set M1N1_SRC=)" >&2; exit 1; }
[ -f "$M1N1_SRC/src/sep.c" ] || { echo "error: $M1N1_SRC does not look like an m1n1 tree" >&2; exit 1; }

# 1. Ensure the instrumentation is present in the m1n1 tree (idempotent, in order).
for entry in "${PATCHES[@]}"; do
    pf="${entry%%	*}"; marker="${entry##*	}"
    patch_path="$REPO/patches/$pf"
    [ -f "$patch_path" ] || { echo "error: missing $patch_path" >&2; exit 1; }
    if grep -q "$marker" "$M1N1_SRC/src/sep.c"; then
        echo "==> $pf already applied"
    else
        echo "==> applying $pf to $M1N1_SRC"
        git -C "$M1N1_SRC" apply --3way "$patch_path" \
            || patch -p1 -d "$M1N1_SRC" < "$patch_path"
    fi
done

# 2. Build m1n1 (native aarch64; no sudo). Flags must match the packaged build's
#    boot chain so the resulting m1n1.bin still chainloads u-boot.
echo "==> building m1n1 (BUILDSTD=1 CHAINLOADING=1 RELEASE=1)"
make -C "$M1N1_SRC" -j"$(nproc)" BUILDSTD=1 CHAINLOADING=1 RELEASE=1
M1N1_BIN="$M1N1_SRC/build/m1n1.bin"
[ -f "$M1N1_BIN" ] || { echo "error: build produced no $M1N1_BIN" >&2; exit 1; }
echo "==> built $M1N1_BIN ($(stat -c%s "$M1N1_BIN") bytes)"

# 3. Ensure the SEP-enabled DTB set exists (build-dtb.sh is non-root).
if [ ! -f "$REPO/out/dtb-name" ]; then
    echo "==> no patched DTB set yet — running scripts/build-dtb.sh"
    "$REPO/scripts/build-dtb.sh"
fi

# 4. Flash boot.bin with our m1n1 + the patched DTBs (needs root inside).
echo "==> flashing boot.bin with instrumented m1n1 + SEP-enabled DTBs"
M1N1="$M1N1_BIN" "$REPO/scripts/install-boot-bin.sh"

cat <<'EOF'

done. reboot, then capture the m1n1 console (serial/screen) and look for:
  SEP: [dbg] asc_init(/arm-io/sep) = <ptr>      # NULL => mailbox never attached
  SEP: [dbg] /chosen sepfw-booted = ?           # 0004: did iBoot start the SEP?
  SEP: [dbg] /chosen sepfw-loaded = ?
  SEP: [dbg] /chosen sepfw-load-at-boot = ?
  SEP: [dbg] SEPFW region base=0x.. size=0x..   # is the fw blob resident in RAM?
  SEP: [dbg] cpu_running=? can_recv=?           # cpu_running is a RED HERRING (reads +0x44)
  SEP: [dbg] getrand asc_send = ?
  SEP: [dbg] getrand recv(1ms) = ? msg0=...
  SEP: [dbg] getrand recv(200ms retry) = ? ...  # only prints if the 1ms miss

Decode sepfw-booted (step5-results.md, patch 0004):
  sepfw-booted=0  -> iBoot never started the SEP on the m1n1 path (halted-not-started);
                     no local wake helps - needs iBoot's SEP-start (upstream WIP)
  sepfw-booted=1  -> booted then slept; a wake/RTKit-hello is missing -> maybe local

Decode getrand (step5-plan.md 5.1) -- ALREADY OBSERVED 2026-08-27: send=1, both recv=0:
  send=1 recv=1                -> SEP answers at m1n1 time; fault is in the
                                  m1n1->Linux handoff / kernel SEP init (pursue 5.2-5.4)
  send=1 recv(1ms)=0 recv(200ms)=1 -> SEP alive but slower than the 1ms window
                                  (a real, trivially-fixable bug on its own)
  send=1 both recv=0           -> SEP mailbox wedged before Linux exists
                                  (m1n1 SEP init / TZ0 / slept-SEPOS state)
  asc_init=NULL                -> the /arm-io/sep ASC never came up in m1n1

--------------------------------------------------------------------------
Capturing the m1n1 console (these prints are NOT in dmesg; they scroll past
before u-boot/GRUB take over, so capture them live).

METHOD A - USB serial gadget (recommended; no special cable) --------------
m1n1 exposes a USB CDC-ACM console over USB-C (VID:PID 1209:316d, two ACM
interfaces - one console, one proxy). On a SECOND machine (the "host"):

  1. Cable: plug a USB-C DATA cable from any port on the MacBook (this j413)
     into the host. If it never enumerates, try the Mac's other side.
  2. Start capturing on the host BEFORE you reboot the Mac, so you catch the
     early prints:
        # find the device m1n1 exposes:
        #   Linux host : ls -l /dev/serial/by-id/*1209*  (-> /dev/ttyACM0 / ACM1)
        #   macOS host : ls /dev/cu.usbmodem*            (m1n1 default: cu.usbmodemP_01)
        picocom -b 115200 /dev/ttyACM0 | tee m1n1-sep.log
     (baud is ignored for USB CDC; 115200 is just m1n1's handshake default.
     screen/minicom work too. The console text is on ONE of ACM0/ACM1 - if
     ACM0 shows binary junk that's the proxy; use ACM1.)
  3. Reboot the Mac (this machine). Watch for the "SEP: [dbg]" lines above,
     which print around m1n1's "Initialization complete." line.

  To STOP m1n1 at its console instead of booting straight through, hold a key
  in the terminal during early boot, or drive it with the proxyclient:
        cd ~/code/m1n1/proxyclient && M1N1DEVICE=/dev/ttyACM0 python3 -i -m m1n1.setup

METHOD B - physical UART over the USB-C SBU pins (fallback) ---------------
Only needed if no USB-C host is available. Requires an Apple-Silicon debug
serial cable wired to the USB-C SBU lines (DIY: CP2102N/FT232H on SBU1/SBU2).
Settings: 1500000 baud, 8N1, no flow control:
        picocom -b 1500000 /dev/ttyUSB0 | tee m1n1-sep.log

If you have neither: the text also renders to the laptop's own screen during
early boot, but it scrolls - fine for spotting the asc_init line, unreliable
for reading the msg0 hex.
EOF

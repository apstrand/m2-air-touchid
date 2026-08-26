#!/usr/bin/env bash
# Rebuild /boot/m1n1/boot.bin using the patched DTB set from build-dtb.sh.
#
# BOOT-CRITICAL. Takes a timestamped backup first; update-m1n1 also leaves
# boot.bin.old behind. See "Rollback / safety" in ../README.md before running.
set -euo pipefail

cd "$(dirname "$0")/.."
DTB_DIR="$PWD/out/dtb"
TARGET="${TARGET:-/boot/m1n1/boot.bin}"

[ -d "$DTB_DIR" ] || { echo "error: $DTB_DIR missing — run scripts/build-dtb.sh first" >&2; exit 1; }
[ -f "$TARGET" ]  || { echo "error: $TARGET not found" >&2; exit 1; }

# refuse to run against an unpatched set
[ -f out/dtb-name ] || { echo "error: out/dtb-name missing — run scripts/build-dtb.sh first" >&2; exit 1; }
DTB_NAME=$(cat out/dtb-name)
SEP_ALIAS=$(fdtget -t s "$DTB_DIR/$DTB_NAME" /aliases sep 2>/dev/null || true)
[ -n "$SEP_ALIAS" ] || { echo "error: $DTB_NAME has no sep alias — build-dtb.sh did not patch it" >&2; exit 1; }
echo "==> $DTB_NAME has /aliases/sep = $SEP_ALIAS"

BACKUP="$PWD/out/boot.bin.backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$PWD/out"
cp "$TARGET" "$BACKUP"
echo "==> backed up $TARGET -> $BACKUP"

echo "==> rebuilding boot.bin with patched DTBs"
sudo env DTBS="$DTB_DIR/*.dtb" update-m1n1 "$TARGET"

echo
echo "done. reboot, then check:"
echo "  dmesg | grep -i sep"
echo "  tr -d '\\0' < /proc/device-tree/soc/sep@25e400000/status"
echo "  ls /proc/device-tree/soc/sep@25e400000/    # want local-policy-manifest, iboot-manifest, memory-region"
echo "  ls /sys/bus/platform/devices/ | grep sep   # want 25e400000.sep to appear"

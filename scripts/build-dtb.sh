#!/usr/bin/env bash
# Build a patched t8112-j413 DTB with the SEP node enabled.
#
#   1. adds  /aliases/sep = "/soc/sep@25e400000"   -> makes m1n1's dt_set_sep()
#      actually run, so it reserves the sepfw region and attaches the
#      local-policy-manifest / iboot-manifest properties from the ADT
#   2. sets  /soc/sep@25e400000/status = "okay"    -> lets apple_sep probe
#
# Output: out/dtb/  (a full DTB set, patched copy substituted in)
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="out"
SEP_PATH="/soc/sep@25e400000"

command -v fdtput >/dev/null || {
    echo "error: fdtput not found. Install it with:  sudo pacman -S dtc" >&2
    exit 1
}

KREL="${KREL:-$(uname -r)}"
SRC_DTBS="/lib/modules/${KREL}/dtbs"
[ -d "$SRC_DTBS" ] || { echo "error: no dtbs at $SRC_DTBS" >&2; exit 1; }

# /proc/device-tree/compatible is a NUL-separated string list, e.g.
#   apple,j413\0apple,t8112\0apple,arm-platform\0
COMPAT=$(tr '\0' '\n' < /proc/device-tree/compatible)
MODEL=$(printf '%s\n' "$COMPAT" | head -1)                                    # apple,j413
BOARD="${MODEL#apple,}"                                                       # j413
SOC=$(printf '%s\n' "$COMPAT" | sed -n 's/^apple,\(t[0-9]\{4,\}\)$/\1/p' | head -1)  # t8112
[ -n "$BOARD" ] && [ -n "$SOC" ] || { echo "error: could not derive SoC/board from $COMPAT" >&2; exit 1; }
DTB_NAME="${SOC}-${BOARD}.dtb"

[ -f "$SRC_DTBS/$DTB_NAME" ] || { echo "error: $SRC_DTBS/$DTB_NAME not found" >&2; exit 1; }
echo "==> this machine: $MODEL / $SOC  ->  $DTB_NAME"

rm -rf "$OUT/dtb"; mkdir -p "$OUT/dtb"
cp "$SRC_DTBS"/*.dtb "$OUT/dtb/"
chmod u+w "$OUT/dtb"/*.dtb

TARGET="$OUT/dtb/$DTB_NAME"

# sanity: the node must exist and be disabled before we touch it
before=$(fdtget -t s "$TARGET" "$SEP_PATH" status 2>/dev/null || echo "<none>")
echo "==> $SEP_PATH status before: $before"
[ "$before" = "disabled" ] || echo "    warning: expected 'disabled', continuing anyway"

fdtput -t s "$TARGET" /aliases sep "$SEP_PATH"
fdtput -t s "$TARGET" "$SEP_PATH" status okay

echo "==> after:"
echo "    /aliases/sep      = $(fdtget -t s "$TARGET" /aliases sep)"
echo "    $SEP_PATH status  = $(fdtget -t s "$TARGET" "$SEP_PATH" status)"
echo
printf '%s\n' "$DTB_NAME" > "$OUT/dtb-name"
echo "patched DTB set in $OUT/dtb/ ($(ls "$OUT/dtb" | wc -l) files)"
echo "next: scripts/install-boot-bin.sh"

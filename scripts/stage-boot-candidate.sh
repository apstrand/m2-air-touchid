#!/usr/bin/env bash
# Assemble and verify a boot.bin candidate in out/. Never writes /boot or /run.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO=$PWD
fail() { echo "error: $*" >&2; exit 1; }

M1N1=${M1N1:-}
EXPECTED_BUILD_TAG=${EXPECTED_BUILD_TAG:-v1.5.2-sepdbg-1}
DTB_DIR=${DTB_DIR:-$REPO/out/dtb}
U_BOOT=${U_BOOT:-/usr/lib/asahi-boot/u-boot-nodtb.bin}
CONFIG=${CONFIG:-/etc/m1n1.conf}
CANDIDATE=${CANDIDATE:-$REPO/out/boot-candidate.bin}
MANIFEST=${MANIFEST:-$CANDIDATE.manifest}

[ -n "$M1N1" ] || fail "set M1N1 to a verified m1n1.bin"
[ -s "$M1N1" ] || fail "M1N1=$M1N1 is missing or empty"
grep -aFq 'SEPDBG:' "$M1N1" || fail "M1N1=$M1N1 does not contain SEPDBG diagnostics"
grep -aFq "$EXPECTED_BUILD_TAG" "$M1N1" ||
    fail "M1N1=$M1N1 does not contain expected build tag $EXPECTED_BUILD_TAG"
[ -d "$DTB_DIR" ] || fail "DTB_DIR=$DTB_DIR is missing"
[ -s "$U_BOOT" ] || fail "U_BOOT=$U_BOOT is missing or empty"
[ -f "$REPO/out/dtb-name" ] || fail "out/dtb-name is missing; run build-dtb.sh"
DTB_NAME=$(<"$REPO/out/dtb-name")
[ -s "$DTB_DIR/$DTB_NAME" ] || fail "$DTB_NAME is absent from the DTB set"
[ "$(fdtget -t s "$DTB_DIR/$DTB_NAME" /aliases sep 2>/dev/null)" = /soc/sep@25e400000 ] ||
    fail "$DTB_NAME does not have the expected SEP alias"
[ "$(fdtget -t s "$DTB_DIR/$DTB_NAME" /soc/sep@25e400000 status 2>/dev/null)" = okay ] ||
    fail "$DTB_NAME does not enable SEP"

mapfile -t DTBS < <(printf '%s\n' "$DTB_DIR"/*.dtb | LC_ALL=C sort)
[ -e "${DTBS[0]}" ] || fail "no DTBs in $DTB_DIR"
mkdir -p "$(dirname "$CANDIDATE")"
tmp=$(mktemp "${CANDIDATE}.tmp.XXXXXX")
cfg=$(mktemp "${CANDIDATE}.cfg.XXXXXX")
trap 'rm -f "$tmp" "$cfg"' EXIT

if [ -f "$CONFIG" ]; then
    while IFS= read -r line; do
        case "$line" in
            ''|'#'*) ;;
            chosen.*=*|display=*|mitigations=*) printf '%s\n' "$line" >> "$cfg" ;;
            *) echo "warning: ignoring unsupported config option: $line" >&2 ;;
        esac
    done < "$CONFIG"
fi

cat "$M1N1" "${DTBS[@]}" > "$tmp"
gzip -c "$U_BOOT" >> "$tmp"
cat "$cfg" >> "$tmp"

# Verify every uncompressed prefix component at its exact candidate offset.
offset=0
cmp -n "$(stat -c%s "$M1N1")" "$M1N1" "$tmp" || fail "m1n1 prefix verification failed"
offset=$(stat -c%s "$M1N1")
for dtb in "${DTBS[@]}"; do
    size=$(stat -c%s "$dtb")
    cmp -n "$size" -i "0:$offset" "$dtb" "$tmp" || fail "DTB verification failed: $dtb"
    offset=$((offset + size))
done

{
    echo "candidate=$CANDIDATE"
    echo "created_utc=$(date -u +%FT%TZ)"
    echo "m1n1=$M1N1"
    echo "m1n1_build_tag=$EXPECTED_BUILD_TAG"
    sha256sum "$M1N1"
    echo "u_boot=$U_BOOT"
    sha256sum "$U_BOOT"
    echo "dtb_dir=$DTB_DIR"
    echo "dtb_count=${#DTBS[@]}"
    echo "verified_prefix_bytes=$offset"
    sha256sum "${DTBS[@]}"
    echo "candidate_sha256=$(sha256sum "$tmp" | cut -d' ' -f1)"
    echo "candidate_bytes=$(stat -c%s "$tmp")"
} > "$MANIFEST.tmp"
mv "$tmp" "$CANDIDATE"
mv "$MANIFEST.tmp" "$MANIFEST"
trap - EXIT
rm -f "$cfg"

echo "==> verified candidate: $CANDIDATE"
echo "==> provenance: $MANIFEST"
echo "    no boot files were changed"

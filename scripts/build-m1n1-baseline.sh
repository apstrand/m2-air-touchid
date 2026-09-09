#!/usr/bin/env bash
# Build the revision-pinned September SEPDBG baseline without installing it.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO=$PWD
M1N1_SRC=${M1N1_SRC:-$REPO/build/m1n1}
EXPECTED_REV=e266c09ee50971828c6a7ba02bb7f36a24a7692e
BUILD_TAG=${BUILD_TAG:-v1.5.2-sepdbg-1}
PATCH=$REPO/patches/0003-m1n1-log-sep-getrand.patch
DEST=$REPO/out/m1n1-baseline/$BUILD_TAG

fail() { echo "error: $*" >&2; exit 1; }
command -v git >/dev/null || fail "git is required"
command -v make >/dev/null || fail "make is required"
[ -d "$M1N1_SRC/.git" ] || fail "no m1n1 checkout at $M1N1_SRC; clone v1.5.2 with submodules first"
[ -f "$PATCH" ] || fail "missing $PATCH"

actual_rev=$(git -C "$M1N1_SRC" rev-parse HEAD)
[ "$actual_rev" = "$EXPECTED_REV" ] || fail "m1n1 revision is $actual_rev, expected $EXPECTED_REV"
git -C "$M1N1_SRC" submodule status --recursive | grep -qE '^[-+U]' &&
    fail "m1n1 has missing or mismatched submodules"

if git -C "$M1N1_SRC" apply --reverse --check "$PATCH" 2>/dev/null; then
    echo "==> SEPDBG patch already applied"
else
    [ -z "$(git -C "$M1N1_SRC" status --short)" ] ||
        fail "m1n1 has changes unrelated to the SEPDBG patch; refusing to modify it"
    git -C "$M1N1_SRC" apply --check "$PATCH"
    git -C "$M1N1_SRC" apply "$PATCH"
fi
git -C "$M1N1_SRC" diff --check

echo "==> building $BUILD_TAG"
make -C "$M1N1_SRC" ARCH= RELEASE=0 CHAINLOADING=0 \
    M1N1_VERSION_TAG="$BUILD_TAG" -j"${JOBS:-$(nproc)}"

BIN=$M1N1_SRC/build/m1n1.bin
MACHO=$M1N1_SRC/build/m1n1.macho
[ -s "$BIN" ] || fail "build produced no $BIN"
[ -s "$MACHO" ] || fail "build produced no $MACHO"
grep -aFq "$BUILD_TAG" "$BIN" || fail "m1n1.bin does not contain build tag $BUILD_TAG"
grep -aFq 'SEPDBG:' "$BIN" || fail "m1n1.bin does not contain SEPDBG diagnostics"

mkdir -p "$DEST"
cp "$BIN" "$MACHO" "$PATCH" "$DEST/"
{
    echo "source_revision=$actual_rev"
    echo "build_tag=$BUILD_TAG"
    echo "build_flags=ARCH= RELEASE=0 CHAINLOADING=0"
    echo "compiler=$(gcc --version | head -1)"
    echo "make=$(make --version | head -1)"
    echo "built_utc=$(date -u +%FT%TZ)"
} > "$DEST/build-info.txt"
(cd "$DEST" && sha256sum m1n1.bin m1n1.macho 0003-m1n1-log-sep-getrand.patch build-info.txt > SHA256SUMS)

echo "==> staged build artifacts in $DEST"
echo "    no boot files were changed"

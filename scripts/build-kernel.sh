#!/usr/bin/env bash
# Build linux-asahi 7.1.6 with the SEP diagnostic patch, as a SEPARATE kernel
# (localversion -ARCH-sepdbg) so the distro kernel stays installed and bootable.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="build/linux-asahi-7.1.6"
PATCHFILE="patches/0002-soc-apple-sep-instrument-boot-and-probe-rom.patch"
LOCALVERSION="-ARCH-sepdbg"
JOBS="${JOBS:-$(nproc)}"

[ -d "$SRC" ] || { echo "error: $SRC missing — clone has not finished" >&2; exit 1; }

echo "==> checking build dependencies"
missing=()
for t in bc pahole bindgen make gcc flex bison rustc cargo; do
    command -v "$t" >/dev/null || missing+=("$t")
done
[ -e /usr/lib/rustlib/src/rust/library/core/src/lib.rs ] || missing+=("rust-src")
if [ ${#missing[@]} -ne 0 ]; then
    echo "error: missing: ${missing[*]}" >&2
    echo "  sudo pacman -S --needed bc pahole rust-bindgen rust-src xmlto" >&2
    exit 1
fi

cd "$SRC"

echo "==> applying $PATCHFILE (idempotent)"
if grep -q 'MSG_GETRAND' drivers/soc/apple/sep.rs; then
    echo "    already applied, skipping"
else
    patch -p1 < "../../$PATCHFILE"
fi

echo "==> seeding config from the running kernel"
zcat /proc/config.gz > .config
printf -- '-1-1\n' > localversion.10-pkgrel          # matches the distro's pkgrel suffix
# the patch makes the tree dirty, so setlocalversion would append "+";
# an empty .scmversion suppresses that and keeps the release name exact
: > .scmversion
./scripts/config --set-str LOCALVERSION "$LOCALVERSION"
make olddefconfig

# the whole point of the build — fail loudly rather than build a useless kernel
grep -q '^CONFIG_APPLE_SEP=y' .config || {
    echo "error: CONFIG_APPLE_SEP is not =y after olddefconfig" >&2; exit 1; }

REL=$(make -s kernelrelease)
echo "==> kernel release will be: $REL"
case "$REL" in
    *-ARCH-sepdbg*) ;;
    *) echo "error: unexpected release '$REL' — refusing to clobber the distro kernel" >&2; exit 1 ;;
esac

echo "==> building with -j$JOBS (this takes a while)"
time make -j"$JOBS"

echo
echo "built: $(realpath arch/arm64/boot/Image) "
echo "release: $REL"
echo "next: scripts/install-kernel.sh"

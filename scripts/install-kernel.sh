#!/usr/bin/env bash
# Install the -ARCH-sepdbg kernel ALONGSIDE the distro kernel and add a GRUB entry.
# Does not touch vmlinuz-linux-asahi or its initramfs.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="build/linux-asahi-7.1.6"
[ -d "$SRC" ] || { echo "error: $SRC missing" >&2; exit 1; }

cd "$SRC"
REL=$(make -s kernelrelease)
case "$REL" in
    *-ARCH-sepdbg*) ;;
    *) echo "error: release '$REL' is not a sepdbg build — refusing" >&2; exit 1 ;;
esac
[ -f arch/arm64/boot/Image ] || { echo "error: no Image — run build-kernel.sh first" >&2; exit 1; }

echo "==> installing modules for $REL"
sudo make modules_install

echo "==> installing kernel image"
sudo cp arch/arm64/boot/Image "/boot/vmlinuz-linux-asahi-sepdbg"

echo "==> generating initramfs"
sudo mkinitcpio -k "$REL" -g "/boot/initramfs-linux-asahi-sepdbg.img"

echo "==> updating GRUB"
sudo grub-mkconfig -o /boot/grub/grub.cfg

echo
echo "done. Distro kernel untouched:"
ls -l /boot/vmlinuz-linux-asahi /boot/vmlinuz-linux-asahi-sepdbg
echo
echo "Reboot and pick the -sepdbg entry in GRUB, then:"
echo "  dmesg | grep -i '25e400000.sep'"
echo "  ./scripts/check-sep.sh"

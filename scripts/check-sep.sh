#!/usr/bin/env bash
# Post-reboot: did m1n1 populate the SEP node, and did apple_sep probe?
SEP=/proc/device-tree/soc/sep@25e400000

echo "=== 1. m1n1 DT fixups (dt_set_sep) ==="
for p in status memory-region local-policy-manifest iboot-manifest; do
    if [ -e "$SEP/$p" ]; then
        case $p in
            status) printf '  %-24s %s\n' "$p" "$(tr -d '\0' < "$SEP/$p")" ;;
            *)      printf '  %-24s present (%s bytes)\n' "$p" "$(stat -c%s "$SEP/$p")" ;;
        esac
    else
        printf '  %-24s MISSING\n' "$p"
    fi
done
printf '  %-24s %s\n' "/aliases/sep" "$(tr -d '\0' < /proc/device-tree/aliases/sep 2>/dev/null || echo MISSING)"
echo "  sepfw reserved-memory:   $(ls -d /proc/device-tree/reserved-memory/sep-firmware* 2>/dev/null || echo MISSING)"

echo
echo "=== 2. driver bind ==="
if [ -e /sys/bus/platform/drivers/apple_sep/25e400000.sep ]; then
    echo "  BOUND: apple_sep <- 25e400000.sep"
elif [ -e /sys/bus/platform/devices/25e400000.sep ]; then
    echo "  device exists but NOT bound (probe failed - see dmesg below)"
else
    echo "  no 25e400000.sep platform device at all"
fi

echo
echo "=== 3. dmesg ==="
dmesg | grep -iE 'sep|secure enclave' || echo "  (nothing - expected with the stock stub driver on a clean boot)"

echo
echo "=== 4. did anything biometric appear? ==="
ls /dev/hidraw* 2>/dev/null
grep -iE 'touch|bio|finger' /proc/bus/input/devices 2>/dev/null | sed 's/^/  /' || true

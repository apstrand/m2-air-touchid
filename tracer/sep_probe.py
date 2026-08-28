#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
Bare-metal SEP probe over the m1n1 proxy (no macOS, no hv guest).

This is the cheap, fast-signal companion to trace_sep.py.  Boot the machine to
an m1n1 *proxy* stage (see scripts/run-sep-probe.sh) and run this against it:

    M1N1DEVICE=/dev/ttyACM1 python3 tracer/sep_probe.py

It reports, from the AP side, exactly the state README steps 2/5 measured, but
live and in one place:

  * PMGR ps_sep power-state    (TARGET/ACTUAL/AUTO/RESET nibbles decoded)
  * ASC CPU_CONTROL / CPU_STATUS
  * INBOX/OUTBOX FIFO CTRL     (is the AP->SEP FIFO drained? is there a reply?)
  * a GET_STATUS probe to the boot ROM (EP 0xFF), with a timeout

The discriminator:
  - GET_STATUS answers STATUS_OK (0x66)  -> the SEP ROM is alive and listening;
    sep.rs's TZ0/IMG4 sequence should work -- pursue the driver, not the wake.
  - GET_STATUS times out AND the AP->SEP FIFO stays non-empty (undrained)
    -> the core is not running its ROM servicer: the "parked, needs a
    reset/power kick" case.  That is what --reset tests (DANGEROUS, see below).

--reset (env SEP_ALLOW_RESET=1) performs an experimental PMGR power-cycle of the
SEP domain, then re-probes GET_STATUS.  This is the local experiment the README
reopened -- but it is genuinely risky: the SEP holds keystore / effaceable-
storage / disk-encryption state, and a bad reset can wedge it until a full power
cycle, or perturb secure storage.  Do NOT run it casually.  Run the macOS
trace_sep.py capture first, confirm the real sequence, and coordinate with
upstream before firing this on hardware.  It is OFF unless you pass --reset AND
set SEP_ALLOW_RESET=1.
"""

import os
import sys
import time
import argparse
import pathlib

# Allow running from the touchid repo against the m1n1 proxyclient.
_M1N1 = os.environ.get("M1N1_SRC", os.path.expanduser("~/code/m1n1"))
sys.path.insert(0, str(pathlib.Path(_M1N1) / "proxyclient"))

from m1n1.setup import *            # noqa: F401,F403  (gives u, p, iface)
from m1n1.hw.sep import SEP, SEPMessage, BootRomMsg, BootRomStatus
from m1n1.hw.asc import R_MBOX_CTRL, R_CPU_CONTROL, R_CPU_STATUS


def decode_ps(val):
    target = val & 0xF
    actual = (val >> 4) & 0xF
    return (f"{val:#010x}  TARGET={target:#x} ACTUAL={actual:#x}"
            f" AUTO_PM={(val >> 28) & 1} bits={val:#010x}")


def read_state(sep):
    a = sep.asc
    print("=== SEP AP-side state ===")
    print(f" CPU_CONTROL       = {R_CPU_CONTROL(a.CPU_CONTROL.val)!s}")
    print(f" CPU_STATUS        = {R_CPU_STATUS(a.CPU_STATUS.val)!s}")
    inb = R_MBOX_CTRL(a.INBOX_CTRL.val)
    outb = R_MBOX_CTRL(a.OUTBOX_CTRL.val)
    print(f" INBOX_CTRL (A2I)  = {inb!s}")
    print(f"     -> AP->SEP FIFO {'EMPTY (drained)' if inb.EMPTY else 'HAS DATA (undrained!)'}")
    print(f" OUTBOX_CTRL (I2A) = {outb!s}")
    print(f"     -> SEP->AP FIFO {'EMPTY (no reply)' if outb.EMPTY else 'HAS DATA (reply waiting)'}")


def read_ps_sep():
    for dev in u.adt["/arm-io/pmgr"].devices:
        if dev.name.lower() in ("sep", "sep0"):
            addr = u.adt.pmgr_dev_get_addr(dev)
            val = p.read32(addr)
            print(f" PMGR ps_sep @ {addr:#x} = {decode_ps(val)}")
            return addr, val
    print(" PMGR ps_sep: no 'sep' device found")
    return None, None


def probe_getstatus(sep, timeout=0.5):
    print(f"=== GET_STATUS probe (EP 0xFF), timeout {timeout*1000:.0f} ms ===")
    # drain any stale replies first
    sep._try_recv_msgs()
    sep.send_msg(SEPMessage(EP=0xFF, TYPE=BootRomMsg.GET_STATUS))
    deadline = time.time() + timeout
    while time.time() < deadline:
        sep._try_recv_msgs()
        if len(sep.msgs[0xFF]):
            msg = sep.msgs[0xFF].popleft()
            name = next((s.name for s in BootRomStatus if s.value == msg.TYPE),
                        f"{msg.TYPE:#x}")
            print(f" REPLY: type={msg.TYPE:#x} ({name}) raw={msg.value:#018x}")
            print(" -> SEP ROM is ALIVE and servicing the mailbox.")
            return True
        time.sleep(0.005)
    print(" NO REPLY within timeout.")
    print(" -> SEP ROM is not servicing the mailbox (silent, as README steps 2/5).")
    return False


def experimental_reset(addr, val):
    print("\n!!! EXPERIMENTAL PMGR power-cycle of the SEP domain !!!")
    print("!!! This can wedge the SEP or perturb secure storage.  You asked for it.")
    # Ordinary PMGR power down/up: drive TARGET nibble to 0 then back to 0xf.
    down = (val & ~0xF)
    up = (val & ~0xF) | 0xF
    print(f" writing ps_sep <- {down:#010x} (power target 0)")
    p.write32(addr, down)
    time.sleep(0.05)
    print(f" ps_sep now = {decode_ps(p.read32(addr))}")
    print(f" writing ps_sep <- {up:#010x} (power target 0xf)")
    p.write32(addr, up)
    time.sleep(0.1)
    print(f" ps_sep now = {decode_ps(p.read32(addr))}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reset", action="store_true",
                    help="experimental PMGR power-cycle + re-probe (needs SEP_ALLOW_RESET=1)")
    ap.add_argument("--timeout", type=float, default=0.5,
                    help="GET_STATUS reply timeout in seconds (default 0.5)")
    args = ap.parse_args()

    sep = SEP(p, iface, u)
    print(f" SEP ASC base = {sep.sep_base:#x}")
    print(f" DART-sep base = {sep.dart_base:#x}\n")

    read_ps_sep()
    read_state(sep)
    print()
    alive = probe_getstatus(sep, timeout=args.timeout)

    if args.reset:
        if os.environ.get("SEP_ALLOW_RESET") != "1":
            print("\n--reset refused: set SEP_ALLOW_RESET=1 to actually do it.")
            return
        if alive:
            print("\nSEP already answering; skipping reset (nothing to fix).")
            return
        addr, val = read_ps_sep()
        if addr is None:
            return
        experimental_reset(addr, val)
        print("\n=== re-probe after reset ===")
        read_ps_sep()
        read_state(sep)
        probe_getstatus(sep, timeout=args.timeout)


if __name__ == "__main__":
    main()

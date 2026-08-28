# SPDX-License-Identifier: MIT
"""
m1n1 hypervisor tracer for the SEP (Secure Enclave Processor) ASC mailbox.

Run this as an m1n1 hv script (`run_guest.py -m trace_sep.py ...`) while a real
Apple OS drives the SEP, to capture the AP<->SEP bring-up we cannot reproduce
from Linux.  It logs, with values:

  * every AP->SEP and SEP->AP mailbox message, decoded (boot-ROM 0xFF, shmem
    0xFE, endpoint-discovery 0xFD, and named endpoints once discovered),
  * writes/reads of CPU_CONTROL / CPU_STATUS and the INBOX/OUTBOX FIFO CTRL
    registers (so we see any attempt to start/stop the core), and
  * writes/reads of the PMGR ps_sep power-state register (the AP-writable
    reset/power lever, distinct from the walled-off ASC CPU_CONTROL at +0x44).

Why this exists: on this j413 the SEP never answers its mailbox under
m1n1/Linux (README step 5).  The one thing the investigation never did was
watch a *working* bring-up live.  This is that instrument.  The high-value
signal is the ordering just before the first BOOT_TZ0: does the driver pulse
PMGR ps_sep (reset/power) first?  Does it touch CPU_CONTROL from a context that
isn't walled off?  What RTKit/hello, if any, precedes TZ0?

Caveat: iBoot boots the SEP before the hv guest runs, so against a macOS guest
you may capture steady-state + re-pair traffic rather than the cold SEPROM boot.
The PMGR ps_sep accesses and any re-bootstrap are still the payoff; for the cold
path, disassemble the staged sepfw / SEPROM instead.

The SEP mailbox uses the standard ASCRegs offsets (INBOX0=0x8800 ...), but --
unlike RTKit ASCs -- the endpoint id lives in msg0's low byte, not msg1.EP, so
this tracer routes on msg0.  (See m1n1/hw/sep.py, which drives the SEP the same
way.)
"""

import struct
from enum import IntEnum

from m1n1.hv import TraceMode
from m1n1.utils import *
from m1n1.trace import Tracer
from m1n1.trace.asc import BaseASCTracer, DIR

# ---------------------------------------------------------------------------
# SEP mailbox message format and boot-ROM protocol (from m1n1/hw/sep.py)
# ---------------------------------------------------------------------------

class SEPMessage(Register64):
    EP    = 7, 0     # endpoint id (0xFF boot ROM, 0xFE shmem, 0xFD discovery)
    TAG   = 15, 8
    TYPE  = 23, 16
    PARAM = 31, 24
    DATA  = 63, 32

EP_BOOT     = 0xFF
EP_SHMEM    = 0xFE
EP_DISCOVER = 0xFD

class BootRomMsg(IntEnum):
    GET_STATUS = 0x02
    BOOT_TZ0   = 0x05
    BOOT_IMG4  = 0x06
    SET_SHMEM  = 0x18

class BootRomStatus(IntEnum):
    STATUS_OK             = 0x66
    STATUS_BOOT_TZ0_DONE  = 0x69
    STATUS_BOOT_IMG4_DONE = 0x6A
    STATUS_BOOT_UNK_DONE  = 0xD2

_BOOT_TX = {m.value: m.name for m in BootRomMsg}
_BOOT_RX = {s.value: s.name for s in BootRomStatus}


# ---------------------------------------------------------------------------
# The SEP ASC tracer
# ---------------------------------------------------------------------------

class SEPTracer(BaseASCTracer):
    # We route by msg0.EP ourselves, so no ENDPOINTS map here.
    ENDPOINTS = {}
    DEFAULT_MODE = TraceMode.SYNC

    def init_state(self):
        super().init_state()
        # discovered endpoint id -> 4-char name, persisted across reloads
        if not hasattr(self.state, "epnames"):
            self.state.epnames = {}

    def _epname(self, ep):
        if ep == EP_BOOT:
            return "boot"
        if ep == EP_SHMEM:
            return "shmem"
        if ep == EP_DISCOVER:
            return "discover"
        return self.state.epnames.get(ep, f"ep{ep:02x}")

    def _decode(self, direction, m):
        ep = m.EP
        if ep == EP_BOOT:
            tbl = _BOOT_TX if direction == DIR.TX else _BOOT_RX
            nm = tbl.get(m.TYPE, f"type={m.TYPE:#x}")
            extra = f" DATA={m.DATA:#x}" if m.DATA else ""
            return f"boot.{nm}{extra}"
        if ep == EP_SHMEM:
            return f"shmem.type={m.TYPE:#x} DATA={m.DATA:#x} (iova={m.DATA << 12:#x})"
        if ep == EP_DISCOVER:
            if m.TYPE == 0:
                # name is 4 ASCII chars packed big-endian in DATA; the endpoint
                # id being advertised is in PARAM (see hw/sep.py)
                name = "".join(chr((m.DATA >> (i * 8)) & 0xFF)
                               for i in range(3, -1, -1))
                self.state.epnames[m.PARAM] = name
                return f"discover: ep {m.PARAM:#04x} = {name!r}"
            return f"discover.type={m.TYPE:#x} PARAM={m.PARAM:#x} DATA={m.DATA:#x}"
        # a named/unknown endpoint
        return (f"[{self._epname(ep)}] type={m.TYPE:#x} param={m.PARAM:#x} "
                f"tag={m.TAG:#x} data={m.DATA:#x}")

    def handle_msg(self, direction, r0, r1):
        # BaseASCTracer.w_INBOX1 / r_OUTBOX1 call us with r0=msg0, r1=msg1.
        m = SEPMessage(r0.value)
        d = ">TX" if direction == DIR.TX else "<RX"
        self.log(f"{d} {m.value:016x}  {self._decode(direction, m)}"
                 + (f"  msg1={r1.value:#x}" if r1.value else ""))
        return True

    # --- control / FIFO visibility -----------------------------------------

    def w_CPU_CONTROL(self, val):
        self.log(f"!! W CPU_CONTROL = {val!s}  (attempt to start/stop the core)")

    def r_CPU_CONTROL(self, val):
        self.log(f"   R CPU_CONTROL = {val!s}")

    def r_CPU_STATUS(self, val):
        self.log(f"   R CPU_STATUS  = {val!s}")

    def w_INBOX_CTRL(self, val):
        self.log(f"   W INBOX_CTRL  = {val!s}")

    def w_OUTBOX_CTRL(self, val):
        self.log(f"   W OUTBOX_CTRL = {val!s}")

    # If TX messages never show up, macOS may be committing via a write other
    # than INBOX1.  Uncomment to see raw INBOX0 writes and adjust the trigger.
    # def w_INBOX0(self, val):
    #     self.log(f"   W INBOX0 = {val:#018x}")


# ---------------------------------------------------------------------------
# PMGR ps_sep power-state register tracer (the reset/power lever)
# ---------------------------------------------------------------------------
#
# ps_sep is an ordinary PMGR power-state register the AP *can* write (the
# investigation read it as 0x1f0020ff).  It is a different register from the
# ASC CPU_CONTROL at sep_base+0x44 that reads-as-zero / write-ignored.  If a
# working bring-up pulses reset or re-asserts power here, this is where we see
# it.  Layout of a PMGR PS reg (t8112): bits [3:0] TARGET, [7:4] ACTUAL,
# bit[31] AUTO_PM, RESET/DEV bits in the high nibble region.

class PMGRRegTracer(Tracer):
    def __init__(self, hv, addr, name):
        super().__init__(hv, ident=f"PMGR:{name}")
        self.addr = addr
        self.name = name

    def start(self):
        # HOOK mode traps synchronously so hook_r/hook_w fire with values;
        # ps_sep is a single 4-byte reg, so the trap overhead is negligible.
        self.trace(self.addr, 4, TraceMode.HOOK)

    def hook_w(self, addr, val, width, **kwargs):
        self.hv.log(f"PMGR: W {self.name} ({addr:#x}) <- {val:#010x}")
        super().hook_w(addr, val, width, **kwargs)

    def hook_r(self, addr, width, **kwargs):
        val = super().hook_r(addr, width, **kwargs)
        self.hv.log(f"PMGR: R {self.name} ({addr:#x}) = {val:#010x}")
        return val


def _find_ps_sep_addr():
    pmgr = u.adt["/arm-io/pmgr"]
    for dev in pmgr.devices:
        if dev.name.lower() in ("sep", "sep0"):
            try:
                return u.adt.pmgr_dev_get_addr(dev)
            except Exception as e:
                print(f"[sep] could not resolve ps_sep addr: {e}")
                return None
    print("[sep] no 'sep' device in /arm-io/pmgr")
    return None


# ---------------------------------------------------------------------------
# Wire everything up (hv, u, p are provided by the run_guest.py hv context)
# ---------------------------------------------------------------------------

SEPTracer = SEPTracer._reloadcls()
PMGRRegTracer = PMGRRegTracer._reloadcls()

sep_tracer = SEPTracer(hv, "/arm-io/sep", verbose=1)
sep_tracer.start()
print("[sep] tracing /arm-io/sep mailbox")

ps_sep_addr = _find_ps_sep_addr()
if ps_sep_addr is not None:
    ps_sep_tracer = PMGRRegTracer(hv, ps_sep_addr, "ps_sep")
    ps_sep_tracer.start()
    print(f"[sep] tracing PMGR ps_sep at {ps_sep_addr:#x}")

# SEP interrupt(s), if the ADT wires them to the AIC -- shows doorbell timing.
try:
    aic_phandle = getattr(u.adt["/arm-io/aic"], "AAPL,phandle")
    sep_node = u.adt["/arm-io/sep"]
    if getattr(sep_node, "interrupt-parent", None) == aic_phandle:
        for irq in getattr(sep_node, "interrupts", []):
            hv.trace_irq("/arm-io/sep", irq, 1, hv.IRQTRACE_IRQ)
            print(f"[sep] tracing SEP IRQ {irq}")
except Exception as e:
    print(f"[sep] IRQ trace skipped: {e}")

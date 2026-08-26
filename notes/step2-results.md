# Step 2 result — the SEP CPU is halted and the AP cannot start it

Built `linux-asahi 7.1.6` (tag `asahi-7.1.6-1`) as `7.1.6-1-1-ARCH-sepdbg+` with
`patches/0002`, which logs every mailbox message and probes the boot ROM with
GETRAND before attempting the boot handshake. Booted 2026-08-26.

## The driver sends, and nothing comes back

```
[0.314180] apple_sep 25e400000.sep: start: probing boot ROM with GETRAND
[0.314186] apple_sep 25e400000.sep: start: sending BOOT_TZ0
[0.314191] apple_sep 25e400000.sep: start: both messages queued, awaiting reply
```

No `RX ep=` line, ever. `25e408000.mbox-recv` stays at 0 across all 8 CPUs.

GETRAND is the significant one: it is exactly what m1n1's `sep_get_random()`
sends to the same endpoint (EP_BOOT is 0xFF, the ROM endpoint), and it is a
simple ROM service with no preconditions. Silence there is much stronger
evidence than the TZ0 silence alone.

## The FIFO bits say it is not even reading

`mod/sepmbox_peek.ko` reads the ASC mailbox status registers directly
(`STRICT_DEVMEM=y` blocks doing this from userspace):

```
A2I_CONTROL (AP->SEP) = 0x00209b01   bit17 clear -> HAS DATA
I2A_CONTROL (SEP->AP) = 0x0002aa01   bit17 set   -> empty
```

139 seconds after boot, our two messages were **still queued**. The SEP had not
drained them.

**This killed the previous leading hypothesis.** `notes/step1-results.md` argued
iBoot had already booted SEPOS, leaving the ROM endpoint gone. That predicts the
SEP *drains* the FIFO and declines to answer. It did not drain it. The dmesg
silence alone was consistent with both stories; only the FIFO bits separated them.

## Powered, but the CPU is halted — and the RUN write is discarded

`mod/sepcpu_start.ko`:

```
pmgr ps_sep  = 0x1f0020ff   TARGET=0xf ACTUAL=0xf, AUTO_ENABLE, no RESET, no DEV_DISABLE
CPU_CONTROL  = 0x00000000   RUN clear
before: A2I=0x00209b01 [HAS DATA]  I2A=0x0002aa01 [empty]
setting CPU_CONTROL RUN bit
after (x5, over 1s): A2I=0x00209b01 [HAS DATA]  I2A=0x0002aa01 [empty]
CPU_CONTROL now = 0x00000000   RUN still clear
```

The power domain is genuinely active. The CPU is genuinely halted. And the
`CPU_CONTROL |= RUN` write — a read-modify-write, posted with a read-back, the
same operation `rtkit-helper.c:112`, `aop.rs:838` and `pmp.rs:151` perform for
their coprocessors — **does not stick**. The FIFOs did not move.

## Why `sep.rs` could never have done this anyway

`sep.rs` takes `reg = <0x2 0x5e400000 0x0 0x6C000>` — the ASC control region —
and **never ioremaps it**. It only ever constructs a `Mailbox`. So it has no code
path that could start the processor. Every other Apple coprocessor driver in the
tree does exactly that write. This looks like a real gap in the stub driver, but
our experiment says filling it would not help on this machine.

## Open question before reporting upstream

`CPU_CONTROL` read `0x00000000` *before* the write too. That is consistent with:

 (a) the register is real but write-protected by secure gating, or
 (b) there is no AP-facing CPU control at this offset — the SEP is not a plain
     ASC and 0x44 means nothing here.

Same practical consequence, different bug report. `mod/sepscan.ko` scans two
256-byte windows (ASC control at +0x000, mailbox at +0x8000 as a positive
control) to see whether the AP's view of the control block is blocked wholesale.
It deliberately does not sweep the whole 0x6c000 region: unimplemented MMIO
reads can raise an SError on these SoCs.

## Where this leaves Touch ID

If the SEP cannot be started by the AP, then on a machine booted this way the
SEP is dormant and unreachable, `sep.rs`'s TZ0/IMG4 path cannot run, and Touch ID
is out of reach from Linux without the firmware starting the SEP for us. That
would make the `local-policy-manifest` / `iboot-manifest` blobs — the per-install
security policy m1n1 copies out of the ADT — the interesting thread to pull next,
since they are what tells iBoot what this OS install is allowed to do.

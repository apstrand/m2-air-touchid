# Step 5 — reopening "the SEP cannot start from Linux"

Written 2026-08-27. This revisits the Step 2/3 conclusion (`SEP-start is a
firmware/handoff wall, upstream-only`) after checking it against the current
upstream Asahi SEP boot model. **The conclusion looks premature.** The real
evidence narrows to a single anomaly with mundane, locally-testable causes.

## Why the "walled off" conclusion is over-read

Upstream ground truth (Asahi SEP docs + current `drivers/soc/apple/sep.rs`):

- The SEP is booted **entirely over the mailbox**: `MSG_BOOT_TZ0` → ack →
  `MSG_BOOT_IMG4` + `MSG_SET_SHMEM`. The docs describe exactly this XNU flow
  ("XNU sends a boottz0 message… sends img4… boots into SEP/OS").
- `sep.rs` confirms the driver **never ioremaps the control region, never writes
  any CPU-control/start register, has no power/reset code, and has no per-SoC
  branch**. It maps `sepfw` with `dma_map_resource` (DMA_TO_DEVICE) through the
  SEP IOMMU and talks to `mbox`. That's the whole mechanism.
- Asahi has already reverse-engineered SEP endpoints and shipped stub drivers
  (e.g. the hardware mic switch) on shipping machines → the bootstrap **works on
  real Asahi hardware**. `sep.rs` boots the SEP; only the endpoint layer is stubbed.

Against that, two of the three Step 2/3 pillars are not evidence of a wall:

1. **`CPU_CONTROL |= RUN` doesn't stick** — irrelevant. Nothing starts the SEP
   CPU this way; the SEPROM is already alive and boots SEPOS on mailbox command.
   No upstream code writes this register for the SEP. (Step 2 already flagged this
   as "moot on this machine"; it's moot *everywhere*.)
2. **Control page `+0x000..+0x100` reads zero, `+0x8000` is live** — expected. The
   SEP ASC just doesn't expose an AP-facing CPU-control block; the mailbox at
   `+0x8000` is the AP's whole interface, by design. Not a permission wall.
3. **The SEPROM doesn't drain the AP→SEP FIFO under Linux** — *this is the only
   real anomaly.* Everything else is interpretation layered on top of it.

So the open question is not "can the AP ever start the SEP" (upstream says yes).
It is: **why does the SEPROM stop draining the mailbox on *this* m1n1→Linux boot,
when it drains for macOS and for other Asahi machines?** That is a handoff/init
delta, and handoff deltas are local and traceable.

## The one contradiction in our own notes to resolve first

The README asserts m1n1's `sep_get_random()` (GETRAND to SEP EP 0xFF) is
"known-good on this hardware," but Step 3b says the m1n1-console GETRAND probe
"showed nothing." Those can't both be casually true. Pin it down: **does the SEP
mailbox answer at m1n1 time on this specific unit?** This single bit routes the
whole investigation:

- **Answers at m1n1 time → dies by kernel time**: the regression is in the
  m1n1→Linux handoff or the kernel's SEP init (DART / mailbox / RTKit / a stale
  FIFO m1n1 left behind). **Local and fixable.** Pursue steps 2–4 below.
- **Never answers, even at m1n1 time**: the SEP mailbox is wedged before Linux is
  in the picture — investigate m1n1's own SEP init, the TZ0 register programming,
  or a unit-specific SEP state. Still local, different fix.

## Prioritized next steps

### 5.1 — Establish the m1n1-time baseline (cheapest, most decisive)
Use the m1n1 **proxy/hypervisor over USB** (`m1n1.proxy`) to send a GETRAND to SEP
endpoint 0xFF and **read the I2A (SEP→AP) reply FIFO directly**, not just watch the
console. Confirm whether the AP→SEP FIFO gets drained at m1n1 time. This is the
discriminator above. Non-destructive; no flashing.

### 5.2 — Trace the handoff with the m1n1 hypervisor
Boot Linux under `m1n1 hv` with SEP mailbox MMIO tracing (`+0x8000` window, both
A2I/I2A FIFOs and doorbell/IRQ regs). Capture the exact sequence of writes the
kernel makes around the first `BOOT_TZ0`, and whether the doorbell is asserted and
the SEP ever toggles I2A. Diff against a macOS boot trace of the same registers if
we can get one. This is how Asahi reverses every coprocessor and is the definitive
tool here.

### 5.3 — Verify the SEP DART/IOMMU + TZ0 carveout are actually programmed
`sep.rs` DMA-maps `sepfw` through `25d2c0000.iommu`; SEPOS also needs the TZ0
secure-RAM registers programmed before it will accept `boottz0`. Check:
- SEP DART is initialized and `sepfw`/shmem are mapped for the SEP.
- m1n1's `dt_set_sep()` path actually ran (we added the `sep` alias pre-m1n1) and
  that TZ0 secure-memory MMIO is set. A SEPROM that sees no valid TZ0 window can
  stall *before* draining — a candidate cause of the FIFO anomaly that doesn't
  require any "wall."

### 5.4 — Rule the mailbox doorbell / SEP sleep-state in or out
The SEP is "put to sleep before the OS kernel boots" (Asahi docs). Confirm the
kernel's `apple-mailbox send` rings the SEP doorbell (not just fills the FIFO), and
that the SEP isn't parked in a sleep state needing a wake/RTKit hello. Also try
draining/resetting the mailbox FIFO before the first kernel send, in case m1n1's
own GETRAND left it half-open.

### 5.5 — Cross-machine sanity check
Confirm whether upstream `sep.rs` boots the SEP on any other M1/M2 (the mic-switch
stub implies yes). If it boots elsewhere but not here, diff DT / SEP firmware
version / LocalPolicy `love` version / config against a working unit. Distinguishes
"unit/config-specific" from "universal t8112 gap." Cheapest via Asahi dev channels.

### 5.6 — Only after the SEP boots
Un-gag `MSG_ADVERTISE_EP` in `sep.rs`, confirm the 12 endpoints (esp. `sbio`)
appear, then begin the `sbio`/Mesa protocol reversing. This is the acknowledged
multi-year part — but it is downstream of 5.1–5.5, and unreachable until the SEP boots.

## Tooling needed
- m1n1 built with proxy + a USB-C data cable to a host running `m1n1` python
  (`proxyclient`). The hypervisor + ASC tracers (`m1n1/trace/…`) are the workhorse.
- `sudo` is blocked in the agent sandbox; kernel modules / bputil / m1n1 flashing
  are run by the user via the `!` prefix (see [[dev-machine-is-target-hw]]).

## Execution log

### macOS reference harvested (2026-08-27, on poseidon/macOS 26.5.1)
Read-only `ioreg -p IODeviceTree` (no sudo). Baseline the Linux side compares to:
- **`dart-sep@5D2C0000`** is a *standard* Apple DART with child `mapper-sep@0`
  (`IODARTMapperNub`) → the SEP IOMMU (`25d2c0000.iommu` on Linux) is an ordinary
  DART. So on Linux it should bind `apple-dart`; verify it does and that `sepfw`/
  shmem are mapped for the SEP's stream (5.3).
- `/chosen`: `sepfw-load-at-boot = 1`, **`sepfw-booted = 1`**, `sepfw-loaded = 1`.
  iBoot loaded *and booted* SEPOS on this unit before handoff. The TZ0 carveout
  MMIO itself is not exposed via ioreg (needs kernel memory; sudo blocked here).
- Nuance this raises: if iBoot already booted SEPOS (`sepfw-booted=1`) and then the
  SEP is "put to sleep before the OS kernel boots" (Asahi docs), the state Linux
  inherits may be *slept SEPOS*, not fresh SEPROM. Whether `GETRAND` to EP 0xFF
  (a ROM-endpoint service) is even valid in that state is exactly what 5.1 tests.

### 5.1 pinned down — instrument m1n1 (no second machine required)
m1n1 `src/sep.c :: sep_get_random()` already has a clean pass/fail signal:
```c
sep_asc = asc_init("/arm-io/sep");                     // in sep_init()
const struct asc_message msg_getrand = {.msg0 =
    FIELD_PREP(SEP_MSG_EP, SEP_EP_ROM) |               // SEP_EP_ROM = 0xFF
    FIELD_PREP(SEP_MSG_CMD, SEP_MSG_GETRAND)};         // GETRAND = 16
if (!asc_send(sep_asc, &msg_getrand)) ...              // send
if (!asc_recv_timeout(sep_asc, &reply, SEP_TIMEOUT))   // 1000 ms
    return done;                                       // <- silent fail today
data = FIELD_GET(SEP_MSG_DATA, reply.msg0);            // REPLY_GETRAND = 116
```
Add `printf` around the `asc_send` return, the `asc_recv_timeout` return, and the
decoded `reply.msg0`. Rebuild `boot.bin` (we already do — `scripts/build-dtb.sh` /
`install-boot-bin.sh`), reboot, read the m1n1 console (screen/serial). Outcome:
- **send ok + recv ok** → SEP mailbox answers at m1n1 time → fault is in the
  m1n1→Linux handoff or kernel SEP init (pursue 5.2–5.4). *Local.*
- **send ok + recv timeout** → SEP wedged before Linux exists → m1n1 SEP init / TZ0 /
  slept-SEPOS state. Cross-check whether `sep_init()`/`asc_init` even succeeded.
This is authored and ready; finalize the exact diff against `src/sep.c` on the Linux
side (where the m1n1 checkout lives) as `patches/0003-m1n1-log-sep-getrand.patch`.

### Environment for the Linux-side work (confirmed 2026-08-27)
- **m1n1 source checkout: `~/code/m1n1`.** Author `patches/0003-m1n1-log-sep-getrand.patch`
  against `~/code/m1n1/src/sep.c`; `scripts/build-dtb.sh` / `install-boot-bin.sh` build+flash
  `boot.bin` from there.
- **A second USB-C machine is available** → the `m1n1 hv` mailbox trace (5.2) is on the
  table: boot poseidon under the hypervisor, drive/trace from the second host over USB-C
  via `proxyclient`. Use it to trace the AP↔SEP mailbox (`+0x8000`, A2I/I2A FIFOs) around
  the first `BOOT_TZ0` once 5.1 has localized m1n1-time vs. kernel-time.
- Next action on reboot: apply 5.1 m1n1 instrumentation → rebuild boot.bin → read console.

### Where each remaining step runs
- **Linux (Asahi):** 5.1 (m1n1 rebuild), 5.2 (hv trace — richer with a 2nd-machine
  USB host, but the m1n1-console variant of 5.1 needs none), 5.3 DART/TZ0 checks
  (kernel module reading `dart-sep` regs + `apple-dart` sysfs), 5.4 mailbox/doorbell.
  All need root + reboot → run by the user via `!` (sandbox blocks sudo).
- **macOS:** reference only — done above. No further macOS step is blocking.

## Bottom line
The Step 2/3 "SEP-start is an unbreakable firmware wall" verdict rested on two red
herrings plus one genuine anomaly. Upstream boots the SEP by mailbox on real
Asahi hardware, so the anomaly (FIFO not drained on this boot) is most likely a
local handoff/init bug, not an architectural wall. Step 5.1 (m1n1-time GETRAND with
a real FIFO read) is the decisive, cheap next experiment.

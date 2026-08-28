# Step 5.1 result — the SEP is silent at m1n1 time too (not a handoff regression)

Instrumented m1n1 (`patches/0003-m1n1-log-sep-getrand.patch`) built + flashed via
`scripts/build-m1n1.sh`, booted, m1n1 console captured over the USB CDC-ACM gadget.

## What the console showed

```
SEP: [dbg] asc_init(/arm-io/sep) = <non-null>     # ASC attached, sep_init ok
SEP: [dbg] cpu_running=0 can_recv=0 (stale FIFO?)
SEP: [dbg] getrand asc_send = 1                   # AP queued GETRAND into A2I FIFO
SEP: [dbg] getrand recv(1ms)   = 0 msg0=0
SEP: [dbg] getrand recv(200ms) = 0 msg0=0         # no reply even at 200ms
SEP: couldn't get enough random bytes for KASLR seed   # falls back to ADT rng
```

## Verdict: the discriminator resolves to "never answers, even at m1n1 time"

This is the third branch of the 5.1 decode table. The SEP mailbox does **not**
answer at m1n1 time, before Linux is anywhere in the picture. So the fault is
**not** an m1n1→Linux handoff regression and **not** a kernel SEP-init bug — the
state Linux inherits is the same silent state m1n1 already sees.

It also **retires a wrong claim in the README**: that m1n1's `sep_get_random()`
is "known-good on this hardware." It is not. It has been failing silently on this
j413 at *every* boot, falling back to the ADT rng seed for KASLR. There was never
a working SEP mailbox reply on this unit — the Step 3b "GETRAND showed nothing"
observation was the true one; the "known-good" line was an assumption.

## This confirms Step 2's register read — at a second, earlier point in boot

Step 2 read the same ASC registers from Linux via `mod/sepmbox_peek.ko`:

| Register | Step 2 (Linux, kernel module) | Step 5.1 (m1n1, via asc.c helpers) |
|---|---|---|
| A2I (AP→SEP) | `0x00209b01` — bit17 clear → **HAS DATA** (queued, undrained) | `asc_send=1` → message queued into A2I |
| I2A (SEP→AP) | `0x0002aa01` — bit17 set → **empty** (no reply) | `can_recv=0` → I2A empty, `recv=0` at 1ms and 200ms |
| `pmgr ps_sep` | `0x1f0020ff` → power domain **ACTIVE** | (not re-read; unchanged) |
| `CPU_CONTROL` (+0x44) | `0x00000000`, RUN write does not stick | `cpu_running=0` (reads the same register) |

Identical picture at both boot stages: **power domain on, mailbox live, AP
messages queued, SEP never drains them or replies.**

## Reading the individual signals correctly

- **`cpu_running=0` is a red herring — ignore it.** `asc_cpu_running()` reads
  `cpu_base + 0x44` (`ASC_CPU_CONTROL`), which is inside the low control window
  Step 2/3 found reads-as-zero / not AP-facing on the SEP. Step 2 already left this
  as its open question (a: secure-gated, or **b: no AP CPU-control at 0x44 on the
  SEP**). It tells us nothing about the real run state of the SEP core.
- **The mailbox IS live and AP-visible** — this is the reliable part. The I2A
  EMPTY bit reads *set* (`can_recv=0`); if the window were dead/zero, EMPTY would
  read clear and `can_recv` would wrongly report data. And Step 2's raw reads
  (`0x00209b01`, `0x0002aa01`) are real, distinct, non-zero register contents.
  The AP can send; the SEP simply never services the queue.
- **`asc_send=1` is meaningful**, not a write into a black hole: `asc_send()`
  first polls the A2I FULL bit for up to 200 ms and only writes if there is room;
  it did not hit the "A2I mailbox full for 200ms" path, i.e. real FIFO status.

## What this means for the mechanism

m1n1 does **not** boot the SEP (its only SEP code is this GETRAND TRNG call —
`git log src/sep.c` is a single "add simple SEP TRNG API" commit). On the Asahi
boot path the SEP should therefore be sitting in **SEPROM**, and GETRAND to EP
0xFF is a ROM service with no preconditions — it should answer. It does not. So
the SEP core is **powered but not executing its ROM mailbox servicer** on this
boot: halted, not merely "declining to answer."

Contrast macOS on the same unit (`step4`): `/chosen sepfw-booted = 1` — iBoot
starts SEPOS before handoff and it is alive. On the m1n1 path the SEP is left
halted, and the AP cannot start it (RUN write is ignored; SEP-start is not an
AP-writable op).

The tension to resolve: upstream `sep.rs` is claimed to boot the SEP purely by
mailbox on real Asahi hardware (the shipping mic-switch SEP-endpoint stub). That
only works if, on those machines, the SEP **is** in a listening ROM state at
OS-boot time (it acks TZ0). Here it is not. So the open question is now sharp:

> Why is this j413's SEP core halted (not running ROM) on the m1n1 boot, when
> other Asahi machines' SEPs are ROM-listening enough for `sep.rs` to boot them?

## Next steps (revised off this result)

1. **Cheapest decisive probe — read `sepfw-booted` on the *Asahi* boot.** We have
   it =1 for macOS only. **Built + staged as `patches/0004-m1n1-dump-sep-provenance.patch`**
   (dumps `/chosen` `sepfw-booted`/`sepfw-loaded`/`sepfw-load-at-boot` + the SEPFW
   `[base,size]` from `/chosen/memory-map`). `scripts/build-m1n1.sh` now applies both
   0003+0004 — so the next flash+reboot yields these lines with no further code work.
   This splits the two live theories:
   - `sepfw-booted = 0` → iBoot never started the SEP on the m1n1 path → SEP halted
     in a not-started state → nothing short of reproducing iBoot's SEP-start (the
     upstream WIP) will help. Rules out a "just wake it" fix.
   - `sepfw-booted = 1` → iBoot booted then slept it → a wake/RTKit-hello sequence
     is missing (m1n1 and `sep.rs` both lack it) → a potentially local fix.
2. **5.5 cross-machine (now pivotal).** Confirm with Asahi whether `sep.rs`
   actually boots the SEP on any **t8112 (M2)**, or only on t8103 (M1) where the
   shipping SEP stubs live. Distinguishes "universal M2 gap = genuine multi-person
   WIP" from "this unit / this config." Cheapest via Asahi dev channels.
3. Only if step 1 says slept (`sepfw-booted=1`): try a mailbox reset / RTKit
   management hello before the first GETRAND/TZ0.

## Step 5.1b result — the SEP firmware is staged normally; the SEP just isn't running it

Patch 0004 (ADT provenance), same boot, m1n1 console:

```
SEP: [dbg] /chosen sepfw-booted        = <absent>
SEP: [dbg] /chosen sepfw-loaded        = <absent>
SEP: [dbg] /chosen sepfw-load-at-boot  = 1
SEP: [dbg] SEPFW region base=0x802ae4000 size=0x5a0000
```

Decode:
- **`SEPFW region` is present and real.** Apple-Silicon DRAM base is `0x8_0000_0000`,
  so base `0x802ae4000` = RAM + ~45 MB, size `0x5a0000` = 5.6 MiB. iBoot **loaded**
  the SEP firmware image into a RAM carveout. (This is the same region m1n1's
  `chainload.c` copies via the ADT `SEPFW` prop; ground-truth that the blob exists.)
- **`sepfw-load-at-boot = 1`** read cleanly as a 4-byte value → the "<absent>" on the
  other two is **true absence**, not the width caveat (a same-width sibling read fine).
- **`sepfw-booted` absent** → iBoot did **not** boot SEPOS on this boot object.

**This overturns the "halted-not-started, no local fix" lean from the 5.1 writeup's
first pass.** The staging here is the *normal* Asahi hand-off: iBoot loads the SEP
firmware into RAM and leaves it **for the OS to boot by mailbox** (`MSG_BOOT_TZ0` →
`MSG_BOOT_IMG4` pointing at this very region → `MSG_SET_SHMEM`) — precisely what
`sep.rs` attempts and what the Asahi SEP docs describe. Nothing about the firmware
staging is anomalous or macOS-specific.

So the anomaly narrows to one thing, cleanly:

> The SEP firmware is loaded and staged exactly as the OS-boots-the-SEP model
> expects, yet the SEP core does not service its mailbox — it doesn't answer GETRAND
> (5.1), doesn't ack `BOOT_TZ0` (step 1), and **doesn't even drain** the AP→SEP FIFO
> (step 2: messages still queued after 139 s). The core isn't executing its ROM
> servicer, even though the firmware it's meant to boot is sitting in RAM.

### The one question that now decides everything (→ 5.5, cross-machine)

Does the SEP ROM service the mailbox at OS-handoff on **any** Asahi/Linux machine —
i.e. does `sep.rs`'s `BOOT_TZ0`/`IMG4` sequence actually boot the SEP anywhere?

- **Yes on M1 (t8103), no on this M2 (t8112)** → iBoot leaves the SEP ROM-listening
  on working machines but leaves it halted on this unit/SoC/boot-object. The fix is
  "start the SEP core," which we've shown the AP can't do via the known register
  (`CPU_CONTROL` RUN doesn't stick — step 2). Real RE, but bounded and t8112-specific.
- **No anywhere** → the SEP has never been booted from Linux; Asahi's "SEP: WIP" means
  exactly this, and features like the hardware mic switch don't require a booted SEPOS.
  Then this is unimplemented upstream, full stop — not a local bug.

`sep.rs` **never writes `CPU_CONTROL`**, so if a reset-release were needed it would
fail on every machine — which means on working machines iBoot must leave the SEP
already running ROM. The divergence is therefore in **what iBoot leaves behind**
for this boot object, not in the Linux driver. That is a firmware/hand-off delta,
consistent with upstream "SEP: WIP", and the cross-machine check tells us if it's
t8112-universal or unit/config-specific. **This is a desk/upstream research task,
not another experiment on this box** — no cheap local probe remains that would move it.

## Step 5.5 done — the cross-machine question, answered from source (no hardware)

The pivotal question was: does the SEP boot from Linux on *any* Asahi machine, or is
this t8112-specific? Answered by reading the kernel tree + current upstream + the
Asahi SEP docs. **It's universal: the SEP is not booted from Linux on any machine.**

Evidence:
- **The SEP node is `status = "disabled"` in *every* Apple SoC dtsi** — t8103 (M1),
  t8112 (M2), t600x (M1 Pro/Max), t602x (M2 Pro/Max). No shipping Asahi DT enables it.
  So `sep.rs` (`compatible = "apple,sep"`) **never binds** in any stock config.
- **There are no `sep-endpoint` drivers anywhere in the tree.** The README/plan claim
  that "Asahi ships SEP-endpoint stub drivers on real hardware (e.g. the hardware mic
  switch)" is **false** — the only SEP-related driver is `sep.rs`, and it discards
  every advertised endpoint (`process_discover_msg` is empty). Corrected in the README.
- **Current upstream `sep.rs` (asahi branch) is still the same stub.** It has *no*
  code to wake / power on / reset-release / start the SEP core — no CPU-control write,
  no control-region ioremap, no RTKit power management, no wake message. It only sends
  `BOOT_TZ0` / `BOOT_IMG4` / `SET_SHMEM` and, per its own design, "delegates actual SEP
  initialization to firmware **already running** on the processor." **It assumes the
  SEP is awake.**

## What the authoritative model says (Asahi SEP docs)

- iBoot **preloads** the SEP firmware into a reserved RAM region (the ADT `SEPFW`
  region — exactly our `0x802ae4000 / 0x5a0000`). ✓ matches 5.1b.
- **"The SEP is used during the boot process but is put to sleep before the OS kernel
  is booted. The OS must re-load the SEP firmware and re-bootstrap it to be able to use
  it."** — so by m1n1/Linux time the SEP is **asleep**, not fresh-ROM and not SEPOS.
- Re-bootstrap is `BOOT_TZ0` → `IMG4` (SEP self-verifies, panics on auth failure) →
  SEPOS.

## The whole investigation, reconciled

Every measurement now fits one coherent story:
- iBoot preloads the SEP fw and **puts the SEP to sleep** before handing off. (docs)
- At m1n1 time the SEP is asleep → GETRAND gets no reply (5.1); m1n1 silently uses the
  ADT rng seed. This is best-effort and its failure here is **not unit-specific** —
  it's the expected result of a slept SEP, the same on any machine.
- At Linux time the SEP is still asleep → it doesn't drain the AP→SEP FIFO (step 2)
  and never acks `BOOT_TZ0` (step 1).
- `sep.rs` sends `BOOT_TZ0` to a **sleeping** SEP and assumes it is awake — there is no
  wake / reset-release / re-bootstrap step. So it cannot boot a slept SEP. And the
  obvious AP-side start (`CPU_CONTROL |= RUN`) does not stick on this SoC (step 2), so
  even adding the naive write wouldn't obviously work.
- `cpu_running=0` was always a red herring (reads the walled-off `+0x44`).

**The real, precise gap:** nothing on the Linux side *wakes / re-bootstraps* the slept
SEP before talking to it. That step is missing from `sep.rs`, the SEP node is disabled
everywhere because of it, and it is unsolved on all Apple Silicon — which is exactly
what Asahi's "SEP: WIP" / "Touch ID: TBA" means. This is not a t8112 or unit bug; it is
the universal upstream gap, now characterized down to the specific missing operation.

## Bottom line

5.1 killed the "local handoff regression" hypothesis; 5.1b showed the SEP firmware is
staged the normal way (loaded, not booted); 5.5 showed the SEP is booted from Linux on
**no** Asahi machine and current upstream `sep.rs` is a stub that assumes an
already-awake SEP. Combined with the docs' "SEP is put to sleep before the OS kernel,"
the blocker is nailed down: **the missing piece is waking / re-bootstrapping the slept
SEP from Linux — an unsolved upstream problem, not a local misconfiguration.** No cheap
local experiment advances this further; progress from here means either (a) reverse-
engineering the SEP wake/re-bootstrap sequence (deep, risky — a bad reset can panic the
SEP until device reset), best done with/for upstream Asahi, or (b) waiting on upstream
SEP work. Touch ID (`sbio` protocol, step 6) remains downstream of that and unreachable
until the SEP boots.

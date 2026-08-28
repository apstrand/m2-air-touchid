# Step 6 (dynamic RE) — instrument a live SEP bring-up

Every prior step was *static*: registers read from a booted Linux, `ioreg`/
`bputil` snapshots from a booted macOS, and reading `sep.rs`/`kboot.c`. We never
watched a *working* AP↔SEP bring-up as it happened. This step adds that
instrument, and reopens one local experiment the earlier "firmware wall" verdict
dismissed too fast.

Two tools, in `../tracer/`:

## 1. `sep_probe.py` — bare-metal, run this first (cheap, decisive)

Runs over an **m1n1 proxy** (no macOS, no hv). Uses the in-tree
`m1n1/hw/sep.py` driver to read the SEP's AP-side state and send one boot-ROM
`GET_STATUS` (EP 0xFF), with a timeout. In one shot it reproduces README steps
2/5 live and gives a yes/no on the load-bearing question:

- **`GET_STATUS` → `STATUS_OK` (0x66)** — the SEP ROM is alive and servicing
  the mailbox. Then the blocker is in the driver, not the wake: pursue
  `sep.rs`'s `BOOT_TZ0`/`IMG4` path.
- **timeout + AP→SEP FIFO stays non-empty** — the core isn't running its ROM
  servicer ("parked", not merely "asleep and listening"). This is the state
  steps 2/5 measured, now confirmed from the proxy in one place.

Run:
```
# 1. build a proxy m1n1 (no CHAINLOADING so it drops to the proxy):
make -C ~/code/m1n1 -j"$(nproc)" RELEASE=1 BUILDSTD=1
# 2. chainload it onto the Mac over USB, then:
M1N1DEVICE=/dev/ttyACM1 scripts/run-sep-probe.sh          # read-only
```

### The reopened local experiment: PMGR `ps_sep` reset (`--reset`)

The step-2/3 verdict "the AP can't start the SEP" was proven **only** for the
ASC `CPU_CONTROL` at `sep_base+0x44` (reads-as-zero, `RUN` write ignored — the
walled-off control window). It was **not** tested for the **PMGR `ps_sep`**
power-state register, which is an ordinary AP-writable PMGR reg (we read it as
`0x1f0020ff`). If a parked SEP needs a power/reset kick to re-enter SEPROM,
`ps_sep` is the lever, and `CPU_CONTROL` being walled off says nothing about it.

`sep_probe.py --reset` power-cycles the SEP domain via `ps_sep` then re-probes
`GET_STATUS`. **It is dangerous** and OFF by default (needs `--reset` **and**
`SEP_ALLOW_RESET=1`): the SEP holds keystore / effaceable-storage / disk-crypto
state; a bad reset can wedge it until a full power cycle or perturb secure
storage. **Do the macOS trace (tool 2) first**, learn the real sequence, and
coordinate with upstream before firing this on hardware. It is a last-resort
confirmation, not the opening move.

## 2. `trace_sep.py` — m1n1 hv tracer for a live (macOS) bring-up

An m1n1 hypervisor script that logs, with values:
- every AP→SEP / SEP→AP mailbox message, decoded (boot-ROM 0xFF, shmem 0xFE,
  endpoint-discovery 0xFD → names, and named endpoints thereafter),
- `CPU_CONTROL` / `CPU_STATUS` and INBOX/OUTBOX FIFO CTRL writes/reads,
- **PMGR `ps_sep` writes/reads** — the whole point: does a working bring-up
  pulse reset/power here before `BOOT_TZ0`?
- the SEP AIC IRQ (doorbell timing), if wired.

Run (macOS guest is the real target):
```
PAYLOAD=/path/to/macos-boot-object scripts/trace-sep-macos.sh
# log lands in out/sep-trace-<stamp>.log
```
Smoke-test the plumbing against our own Linux build first — the tracer will
attach and print `[sep] tracing …`; you just won't see a real bring-up because
Linux can't boot the SEP.

### What to look for in the log, in order

1. **Any `ps_sep` write** around SEP init — value transitions (TARGET/ACTUAL
   nibbles, a RESET bit pulse). If macOS resets/re-powers the SEP here, that is
   the missing step `sep.rs` never does, and it maps to an AP-writable register.
2. **`CPU_CONTROL` writes** — if macOS writes it *and it sticks* (in the hv it
   is driven pre-handoff, from a context that may not be walled off), the wall
   we hit is context/ordering, not absolute.
3. **The exact message ordering before the first `boot.BOOT_TZ0`** — any RTKit
   management/hello, `GET_STATUS` poll, or shmem setup that precedes it.
4. **The discovery burst** — the 12 endpoints from step 4 (`sbio` = Touch ID),
   confirming the mailbox format decode end-to-end.

### Caveat (important)

iBoot boots the SEP *before* the hv guest runs, so against macOS you may capture
**steady-state + re-pair** traffic and the `ps_sep` accesses, not the cold
SEPROM boot. That is still the payoff (re-bootstrap ordering + the power lever).
For the cold boot path proper, disassemble the staged `sepfw` (plaintext AArch64
in RAM, README step 3) and SEPROM instead — the mailbox opcodes in `sep.rs`/
`hw/sep.py` came from exactly that.

## Before hardware time: talk to upstream

We've re-derived the "SEP: WIP" wall to a sharper resolution than the public
docs. Highest-leverage move: put the step 5.1b/5.5 findings (`sepfw-booted`
absent on the Asahi boot object, FIFO never drains, `ps_sep` state) in front of
the SEP owners (svenpeter / `#asahi-re`), who may already have the
reset/re-bootstrap sequence reversed. A dangerous SEP reset should be done with
them and against a traced macOS reference — not solo.

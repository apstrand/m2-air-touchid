# Touch ID on Apple Silicon (M2 / t8112) under Asahi Linux

Working notes + tooling for bringing up the Secure Enclave Processor (SEP) far
enough to reach the Touch ID sensor on a MacBook Air (13-inch, M2, 2022)
(`apple,j413` / `apple,t8112`) running Omarchy 4.0.1rc1, `linux-asahi 7.1.6`.

Status: **SEP is dormant, not missing.** The kernel driver is compiled in and the
device tree node exists. Nothing enables it.

## What is actually on the machine

| Piece | State |
|---|---|
| `CONFIG_APPLE_SEP` | `=y` — built in (`kernel/drivers/soc/apple/sep.ko` in `modules.builtin`) |
| `apple_sep` platform driver | registered, visible in `/sys/bus/platform/drivers/` |
| `/soc/sep@25e400000` DT node | present, `compatible = "apple,sep"`, **`status = "disabled"`** |
| `sep` alias in `/aliases` | **absent** |
| `sepfw` reserved-memory region | **absent** |
| `local-policy-manifest` / `iboot-manifest` props on the sep node | **absent** |
| Touch ID as an input/HID device | never appears — `dockchannel-hid` enumerates only `stm`, `multi-touch`, `keyboard`, `tp_accel`, `actuator` |

So the driver never probes, because the node is disabled; and even if it were
enabled it would fail probe, because the three things `probe()` needs
(`sepfw` region, `local-policy-manifest`, `iboot-manifest`) are not in the tree.

## Why those are missing: m1n1 bails early

m1n1 v1.5.2 is what populates them, in `dt_set_sep()` (`src/kboot.c`):

```c
static int dt_set_sep(void)
{
    const char *path = fdt_get_alias(dt, "sep");
    if (path == NULL) {
        printf("FDT: sep alias not found in devtree\n");
        return 0;                      /* <-- we exit here, every boot */
    }
    ...
    dt_get_or_add_reserved_mem("sep-firmware", "apple,asc-mem", false, ...);
    dt_device_add_mem_region(path, mem_phandle, "sepfw");
    fdt_setprop(dt, node, "local-policy-manifest", ...);   /* from ADT /chosen/boot-object-manifests lpol */
    fdt_setprop(dt, node, "iboot-manifest",        ...);   /* ... ibot */
}
```

`t8112.dtsi` (and `t8103.dtsi`) declare the node but never add the alias, and
`/aliases` on this machine confirms it: `atcphy0 atcphy1 bluetooth0 dcp disp0
disp0_piodma gpu isp keyboard nvram serial0 serial2 wifi0`. No `sep`.

**The alias is the single gate.** It must be in the DTB *before* m1n1 runs, because
only m1n1 can read the ADT to find the SEPFW physical range and the lpol/ibot
manifests. A later overlay (U-Boot, kernel) cannot synthesise those.

`dt_set_sep()` also does *not* set `status = "okay"`, so that has to be patched too.

## What the driver would actually give us (read `notes/sep-driver-analysis.md`)

`drivers/soc/apple/sep.rs` — 370 lines of Rust, described in its own module line as a
**"Secure enclave processor stub driver"**. It:

1. maps the `sepfw` region, builds a 0x30000 shmem block (CNIP/OPLA/IPIS/llun),
2. boots the SEP: `MSG_BOOT_TZ0` → ack → `MSG_BOOT_IMG4` + `MSG_SET_SHMEM`,
3. listens on `EP_DISCOVER` (0xFD) for endpoint advertisements,
4. **throws every one of them away** — the `MSG_ADVERTISE_EP` handler body is
   commented out, and `process_message()` ends in `_ => {}` for all other endpoints.

There is no SKS, no `stac` endpoint, no biometric endpoint, no userspace interface.
Booting the SEP gets us to the starting line, not to Touch ID.

Note that m1n1 *already* talks to the SEP boot ROM today — `sep_get_random()` in
`m1n1/src/sep.c` pokes endpoint 0xFF `GETRAND` for the KASLR/RNG seed — so the
mailbox path itself is known-good on this hardware. The kernel driver is what
boots SEPOS proper.

## Plan

- [x] **Step 0** — establish where the chain breaks (above).
- [x] **Step 1** — patch the DTB: add the `sep` alias, flip `status` to `okay`.
      Rebuild `boot.bin`. **Done 2026-08-26.** DT fixups all landed and `apple_sep`
      binds — but the SEP mailbox has **zero** recv interrupts, i.e. it never acked
      `MSG_BOOT_TZ0`. See `notes/step1-results.md`.
      → `scripts/build-dtb.sh`, `scripts/install-boot-bin.sh`, `scripts/check-sep.sh`
- [x] **Step 1b / 2 / 3** — establish why the SEP is silent under Linux and what it
      advertises under macOS. **Resolved 2026-08-26.** Under Linux the AP cannot start
      the SEP at all: the ASC control page reads-as-zero and `CPU_CONTROL |= RUN` does
      not stick — the control window is walled off from the AP (`notes/step2-results.md`,
      `notes/step3-results.md`). So SEPOS never runs and nothing is ever advertised;
      un-gagging `MSG_ADVERTISE_EP` in `sep.rs` is moot on a Linux boot.
      On **macOS** (same machine, `notes/step4-results.md`) SEPOS boots and advertises
      12 endpoints. The biometric endpoint is **`sep-endpoint,sbio`** (not `stac`), driven
      by `AppleMesaSEPDriver → AppleBiometricServices`; calibration is `MesaCalBlobSource
      = "FDR"`.
- [ ] **Step 3b (the real blocker)** — get the SEP started in a state Linux can inherit.
      `bputil -d` on both installs is **done** (`notes/step4-results.md`): the Asahi stub
      (install 2, `love=22.7.74`) already boots at **maximum permissive security**
      (`smb0 && smb1`, CTRR off, custom KC), matching our decoded `local-policy-manifest`
      exactly. **So the blocker is not a settable LocalPolicy bit** — the boot-policy side
      is already wide open. What differs is the *handoff*: macOS's signed kernel +
      `AppleSEPManager` brings up/pairs SEPOS; the m1n1→Linux path leaves the SEP control
      window walled off from the AP. This is firmware/handoff territory (upstream Asahi,
      "SEP: WIP"), not a local knob. The m1n1-console `GETRAND` probe was tried
      (2026-08-26) and showed nothing — but it is **moot**: Step 2's instrumented kernel
      already sent `GETRAND` to the same ROM endpoint, got no reply, and saw the SEP never
      drain its recv FIFO. No cheap local probe remains.
- [ ] **Step 5 (reopens 3b — `notes/step5-plan.md`)** — the Step 2/3 "SEP-start is
      a firmware wall" verdict is likely premature. Upstream `sep.rs` boots the SEP
      *purely by mailbox* (never writes CPU_CONTROL), and Asahi ships SEP-endpoint
      stub drivers on real hardware — the bootstrap works elsewhere. The
      `CPU_CONTROL`/control-page findings are red herrings; the one real anomaly is
      the SEPROM not draining the AP→SEP FIFO on *this* boot, i.e. a handoff/init
      delta that is plausibly local. Decisive cheap test: send GETRAND to SEP EP
      0xFF from the **m1n1 proxy/hypervisor** and read the I2A reply FIFO directly —
      does the SEP mailbox answer *before* Linux? Then trace the handoff under
      `m1n1 hv`. See `notes/step5-plan.md` for the full 5.1–5.6 plan.
- [ ] **Step 6** — userspace: SEP match is yes/no in-enclave, so this is a
      libfprint/fprintd shim over a kernel-provided verify call, not an image-based
      driver. Enrollment likely has to happen in macOS (calibration + templates are
      SEP/FDR-owned — confirmed in `notes/step4-results.md`).

Upstream context: Asahi's M2 feature table lists **SEP as WIP** and **Touch ID as TBA**.
Nothing here contradicts that — the blocker is Step 3b (starting the SEP from Linux),
and Step 3/4 (reversing the `sbio` protocol) is where the multi-year part lives.

## Rollback / safety

`scripts/install-boot-bin.sh` rewrites `/boot/m1n1/boot.bin`, which is boot-critical.
`update-m1n1` keeps the previous copy as `boot.bin.old` automatically, and the script
takes its own timestamped backup first.

If the machine will not boot afterwards: hold the power button to reach the boot
picker, boot macOS, mount the Linux ESP (partition PARTUUID
`a153434d-5c3a-46d5-8010-1162363e00c1`, `/dev/nvme0n1p4` — it is plain vfat), and copy
`m1n1/boot.bin.old` over `m1n1/boot.bin`.

Also: the pacman hook `95-m1n1-install.hook` re-runs `update-m1n1` on every kernel or
m1n1 upgrade, which will silently restore the **unpatched** DTBs. Re-run
`install-boot-bin.sh` after any such upgrade, or make it permanent by setting `DTBS`
in `/etc/default/update-m1n1`.

## References

- Asahi SEP docs — <https://asahilinux.org/docs/hw/soc/sep/>
- Asahi M2 feature support (SEP: WIP, Touch ID: TBA) — <https://asahilinux.org/docs/platform/feature-support/m2/>
- `AsahiLinux/linux` branch `asahi`: `drivers/soc/apple/sep.rs`, `arch/arm64/boot/dts/apple/t8112.dtsi`
- `AsahiLinux/m1n1` branch `main`: `src/kboot.c` (`dt_set_sep`), `src/sep.c` (`sep_get_random`)
- Claimed T1 Touch ID result, unverified — <https://x.com/0xBOYD/status/2092616493787730294>
  (x.com returns HTTP 402 to fetches; no code found). T1 is an Intel-Mac coprocessor
  reached over USB iBridge, so nothing from it transfers to the t8112 SEP path anyway.

# Touch ID on Apple Silicon (M2 / t8112) under Asahi Linux

Working notes + tooling for bringing up the Secure Enclave Processor (SEP) far
enough to reach the Touch ID sensor on a MacBook Air (13-inch, M2, 2022)
(`apple,j413` / `apple,t8112`) running Omarchy 4.0.1rc1, `linux-asahi 7.1.6`.

Status (2026-09-08): **Linux driver binds after DT fixes, but SEP has not replied.**
The cause is unresolved. August notes record early-boot timeouts; a September
diagnostic revision still needs validation. See [the current plan and Linux
handoff](notes/next-steps.md).

## Original stock configuration (before Step 1)

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

m1n1's `sep_get_random()` sends endpoint 0xFF `GETRAND` for the KASLR/RNG seed.
A successful reply on this machine's Asahi boot path has not been captured.
[Step 5 results](notes/step5-results.md) record August timeouts at 1 ms and
200 ms, plus ADT firmware provenance. The next capture should preserve those
observations and add reproducible build identity and mailbox status samples.

## Plan

The current plan and Linux resume commands are in
[notes/next-steps.md](notes/next-steps.md). Status as of 2026-09-08:

- [x] Enable the DT node and provide m1n1's SEP fixups; Linux driver binds.
- [x] Record Linux mailbox silence and collect the macOS `sbio` reference.
- [x] Preserve the August m1n1 GETRAND/ADT reports and draft proxy/HV tools.
- [ ] Finish m1n1 diagnostics and build/package tooling. Draft patch
      `patches/0003-m1n1-log-sep-getrand.patch` is saved against v1.5.2, but
      compilation and hardware testing remain. The source checkout in `build/`
      is ignored by git; recreate it on Linux.
- [ ] Validate the proxy/HV tools against the pinned m1n1 API before use.
- [ ] Capture an identified early baseline and trace the first Linux handshake.
- [ ] Obtain repeatable Linux SEP boot acknowledgments and endpoint discovery.
- [ ] Reverse sensor setup and `sbio` authentication, establish enrollment and
      credential requirements, then integrate Linux authentication.

The old CPU-control experiments do not prove that SEP is halted or impossible
to boot from Linux. Nor is a locally fixable cause established. Enrollment in
macOS and reuse of those enrollments in Linux remain untested hypotheses.
Asahi still lists SEP as WIP and Touch ID as TBA.

`scripts/build-m1n1.sh` retains the **historical build-and-install workflow**
using `patches/historical/0003-m1n1-log-sep-getrand-200ms.patch` plus patch 0004.
It installs immediately and does not build the September baseline. The proxy
and HV drafts are in `tracer/`; their known issues and validation work are in
the current plan. The old probe's default path is not read-only.

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

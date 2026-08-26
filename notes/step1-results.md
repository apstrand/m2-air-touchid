# Step 1 result — SEP node enabled, driver bound, SEP silent

Flashed `boot.bin` with the patched `t8112-j413.dtb` (sep alias + `status = "okay"`),
rebooted 2026-08-26. Machine came up normally, no boot regression.

## Everything we asked for happened

m1n1's `dt_set_sep()` ran this time:

```
/aliases/sep                    /soc/sep@25e400000
/soc/sep@25e400000 status       okay
  memory-region                 present (4 bytes, phandle 217)
  local-policy-manifest         present (2735 bytes)
  iboot-manifest                present (5719 bytes)
reserved-memory/sep-firmware    reg = 0x8037c0000 + 0x5a0000 (5760 KiB)
                                compatible = "apple,asc-mem", phandle 0xd9 = 217 ✓
```

```
[0.000000] OF: reserved mem: 0x00000008037c0000..0x0000000803d5ffff (5760 KiB) map non-reusable sep-firmware
[0.057076] platform 25e400000.sep: Adding to iommu group 4
```

And the driver bound:

```
/sys/bus/platform/drivers/apple_sep/25e400000.sep      -> BOUND
/sys/bus/platform/devices/25e400000.sep/
    supplier:platform:25d2c0000.iommu
    supplier:platform:25e408000.mbox
/sys/kernel/iommu_groups/4/devices/25e400000.sep
25e408000.mbox -> bound to apple-mailbox
```

Binding proves `probe()` ran to completion: the `sepfw` region resolved,
`build_shmem()` read both manifests, `Mailbox::new_byname()` succeeded, and
`start()` — which sends `MSG_BOOT_TZ0` on `EP_BOOT` — returned `Ok`.

## But the SEP never answered

```
61:  0 0 0 0 0 0 0 0   AIC2 65815 Level  25e408000.mbox-recv
62:  0 0 0 0 0 0 0 0   AIC2 65812 Level  25e408000.mbox-send
```

**Zero receive interrupts.** For comparison, every other live coprocessor mailbox
on this machine has traffic: `206408000` (SMC) 2907, `231c08000` (DCP) 4997,
`24e408000` (MTP) 34, `277408000` (NVMe) 39.

No `dev_err!` from the driver either — but that is not evidence of success. The
error paths only fire on messages that *arrive* ("Unknown boot message type") or on
a failed firmware map, which happens in `load_fw_and_shmem()`, and that is only
reached from `MSG_BOOT_TZ0_ACK2`. We never got ACK1 or ACK2. **The failure is at
the very first step: the SEP did not ack TZ0.**

## Hypotheses ruled out

- *Missing power domain on the mailbox* — `mbox@25e408000` has no `power-domains`,
  but neither do `206408000`, `23e408000`, `24a408000`, `24e408000`, all of which
  have busy recv counters. Normal for always-on ASCs.
- *Mailbox not bound / send failed* — `apple-mailbox` is bound, both device links
  are present, and a failed send would have failed `probe()`.
- *Broken DT plumbing* — `memory-region` phandle 217 matches the `sep-firmware`
  node's phandle exactly; region size and address match the dmesg reservation.

## Leading hypothesis

**iBoot already booted SEPOS, so the boot-ROM endpoint (0xFF) is gone.**

`sep.rs` assumes it is talking to the SEP boot ROM and drives TZ0 → IMG4 → shmem.
If SEPOS is already running, the ROM endpoint no longer exists and those messages
go nowhere — exactly the silence we see.

This also retro-explains an earlier ambiguity. m1n1's `sep_get_random()` talks to
the same ROM endpoint (`SEP_EP_ROM 0xff`, `SEP_MSG_GETRAND`) with a 1000 ms timeout,
and falls back to `dt_set_rng_seed_adt()` on failure. We noted that `/chosen` has
`kaslr-seed` but no `rng-seed`, and set that aside because Linux `fdt_nop`s
`rng-seed` after consuming it. But the ADT fallback path sets *only* `kaslr-seed` —
so both stories fit the evidence, and "SEP ROM never answered m1n1 either" is now
the more economical one.

## How to discriminate — cheapest first

1. **Read m1n1's boot console at the next reboot** (free). It prints either
   `FDT: Passing 8 bytes of KASLR seed and 128 bytes of random seed`  → ROM alive
   or `ADT: N bytes of random seed available`                          → ROM silent, fell back.
   That single line settles it. Text is on the framebuffer very early and scrolls fast.
2. **USB serial console** from a second machine (m1n1 proxy) — same information,
   captured properly, needs a USB-C cable and a host.
3. **Instrumented kernel** — `patches/0002` plus logging around `start()`/`send()`,
   and a timeout so we can tell "no reply" from "reply we mishandled". Definitive,
   but it is a full Rust-enabled kernel build.

If the ROM really is gone, `sep.rs`'s entire boot path is inapplicable on a machine
booted this way, and the question becomes what SEPOS advertises to an AP that did
not boot it — which is new reverse-engineering, not a patch.

# Step 3 — firmware IS staged; the AP simply cannot drive the SEP

## Retraction

In `notes/step2-results.md` and in conversation I argued that the absence of a SEP
firmware object in the `iboot-manifest` (which lists `aopf avef dcp2 dtre gfxf
ispf krnl mtpf pmpf siof trst` and ~13 more, each with a digest) meant iBoot had
not staged SEP firmware for this boot.

**That was wrong.** Reading the region directly disproves it.

## The sepfw region holds real code

```
sepfw region 0x8037c0000 + 0x5a0000, first 0x10000 bytes:
first 32 bytes: ff 83 01 d1 fd 7b 03 a9 fd c3 00 91 f3 53 04 a9 ...
54689/65536 bytes non-zero, first non-zero at +0x0
```

Disassembled as AArch64 that is a textbook function prologue:

```
0:  d10183ff   sub  sp, sp, #0x60
4:  a9037bfd   stp  x29, x30, [sp, #48]
8:  9100c3fd   add  x29, sp, #0x30
c:  a90453f3   stp  x19, x20, [sp, #64]
10: aa0003f3   mov  x19, x0
14: aa0303f4   mov  x20, x3
18: b0000320   adrp x0, 0x65000        <- target inside the 5760 KiB region
1c: f9438400   ldr  x0, [x0, #1800]
```

83% of the surveyed window is non-zero and the `adrp` target lands inside the
region. This is a staged, plaintext AArch64 image, not an empty carveout and not
a wrapped IM4P container. iBoot did its job. The manifest omission means
something else, or my tag extraction missed it.

## The ASC control registers are read-as-zero / write-ignored

```
window +0x00000..+0x00100  (ASC control, CPU_CONTROL at +0x44)
  -> 0 non-zero in this window
window +0x08000..+0x08100  (mailbox)
  +0x08000 = 0x0000000c
  -> 1 non-zero in this window
```

Caveat on my own instrumentation: the windows were 0x100 bytes, and the mailbox
control registers live at +0x8110 / +0x8114 — sixteen bytes past the end of the
second window. So the "positive control" was weaker than intended. It does not
matter for the conclusion, because `mod/sepmbox_peek.ko` already read those two
registers directly and got live values (`0x00209b01`, `0x0002aa01`).

The load-bearing facts are:

1. the whole ASC control page reads as zero, including `CPU_CONTROL` at +0x44
2. writing `CPU_CONTROL |= RUN` does not stick — it reads back zero (step 2)

Read-as-zero plus write-ignored is the signature of a register window the AP is
not permitted to touch. Which is exactly what one would expect of a Secure
Enclave: the AP gets a mailbox and nothing else. The mailbox is live; the control
registers are walled off.

## Consequences

- **The SEP cannot be started from Linux.** Not a driver bug, not a missing
  ioremap — the hardware does not expose that control to the AP. Adding the
  CPU-start write to `sep.rs` (which it genuinely is missing, unlike
  rtkit-helper.c / aop.rs / pmp.rs) would not help on this machine.
- The SEP is powered (`ps_sep` ACTUAL=0xf, AUTO_ENABLE, no RESET), firmware is
  staged, and the processor is halted with our two messages queued since boot.
- Whatever starts the SEP runs before us and chose not to, or started it and
  stopped it. Either way the lever is on the firmware / boot-policy side.

## What is worth doing next

Not more poking from Linux. The remaining questions are about what iBoot does
differently for this OS install, and those are answerable from macOS:

- `sudo bputil -d` — dumps each install's LocalPolicy in readable form, naming
  the `smb*` / `sip*` flags properly. Direct comparison against the DER we
  decoded from our own `local-policy-manifest`:
  `smb0=true smb1=true sip2=true lobo=true hrlp=true love="22.7.74.0.0,0"`
- `ioreg -rc AppleSEPManager -l` — the SEP endpoint list on a machine where it
  actually booted. This is the step-4 information we would otherwise reverse
  engineer.
- `ioreg -l | grep -i mesa` — "Mesa" is Apple's internal name for Touch ID.
- Compare the macOS ADT's SEPFW memory-map entry against what m1n1 hands us.

Separately, m1n1's own console line would say whether SEPROM answers *early* in
boot (`FDT: Passing 8 bytes of KASLR seed and 128 bytes of random seed` = ROM
alive, vs `ADT: N bytes of random seed available` = fell back). The device tree
cannot tell us — `dt_set_rng_seed_adt()` writes `rng-seed` too. Practical way to
read it: interrupt U-Boot at the prompt on the next boot; m1n1's log is still on
the framebuffer above it, frozen and photographable.

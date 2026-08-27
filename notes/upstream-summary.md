# SEP / Touch ID on Apple M2 (t8112, j413) under Asahi — findings

Investigation of how far the Secure Enclave (SEP) and Touch ID can be brought up on a
MacBook Air (13", M2, 2022) — `apple,j413` / `apple,t8112` — dual-booting macOS 26.5.1
(build 25F80) and Asahi (`linux-asahi 7.1.6`, m1n1 v1.5.2). Same physical machine used
for both sides, so the macOS observations are ground truth for this exact SoC.

**TL;DR:** On the m1n1→Linux boot path the AP cannot start the SEP: the ASC control page
is read-as-zero / write-ignored to the AP, the SEP never drains its mailbox FIFO, and it
never answers `GETRAND` or `BOOT_TZ0`. This is independent of DT fixups and of LocalPolicy
— the Asahi boot already runs at maximum permissive security. Under macOS on the same
machine the SEP boots normally and Touch ID is the `sep-endpoint,sbio` (Mesa) endpoint.
The gap is the firmware/handoff, consistent with Asahi's "SEP: WIP / Touch ID: TBA".

## 1. The DT side is solvable and does not help by itself

Out of the box, `t8112.dtsi` declares `/soc/sep@25e400000` but leaves it
`status = "disabled"` and adds no `sep` alias, so m1n1's `dt_set_sep()` (`src/kboot.c`)
bails at its first line (`fdt_get_alias(dt,"sep") == NULL`) and never attaches the
`sepfw` reserved-memory region or the `local-policy-manifest` / `iboot-manifest` props.

Adding the `sep` alias to the DTB *before* m1n1 runs (it must be pre-m1n1: only m1n1 can
read the ADT for the SEPFW physical range and the lpol/ibot manifests) plus flipping
`status = "okay"` makes all of that land:

- `sep-firmware` reserved region `0x8037c0000 + 0x5a0000` (5760 KiB), `apple,asc-mem`
- `local-policy-manifest` (2735 B) and `iboot-manifest` (5719 B) copied from the ADT
- `apple_sep` binds; device links to `25d2c0000.iommu` and `25e408000.mbox` (apple-mailbox)

`probe()` runs to completion — `build_shmem()` reads both manifests, the mailbox opens,
`start()` sends `MSG_BOOT_TZ0` and returns `Ok`. The firmware region is real: dumping it
shows plaintext AArch64 (`d10183ff sub sp,sp,#0x60; a9037bfd stp x29,x30,...`), 83%
non-zero, `adrp` targets landing inside the region. iBoot staged the SEP image.

## 2. …but the SEP never responds, because the AP can't drive it

After all of the above:

- `25e408000.mbox-recv` stays at **0** across all 8 CPUs, indefinitely. Every other live
  ASC mailbox on the machine has traffic (SMC 2907, DCP 4997, MTP 34, NVMe 39).
- Reading the ASC mailbox status registers directly (kernel module; `STRICT_DEVMEM`
  blocks userspace):
  ```
  A2I_CONTROL (AP->SEP) = 0x00209b01   bit17 clear -> HAS DATA
  I2A_CONTROL (SEP->AP) = 0x0002aa01   bit17 set   -> empty
  ```
  139 s after boot, `BOOT_TZ0` (and a `GETRAND` probe to the ROM endpoint `0xFF`, the same
  service m1n1's `sep_get_random()` uses) are **still queued** — the SEP has not drained
  the FIFO. It is not "declining to answer"; it is not reading at all.
- `pmgr ps_sep = 0x1f0020ff` (TARGET=0xf ACTUAL=0xf, AUTO_ENABLE, no RESET) — the power
  domain is genuinely on. `CPU_CONTROL` at ASC `+0x44` reads `0x00000000`, and writing
  `|= RUN` (read-modify-write with read-back, the same op `rtkit-helper.c`, `aop.rs`,
  `pmp.rs` use) **does not stick** — reads back 0, FIFOs do not move.
- Sweeping the ASC control page: the whole `+0x000..+0x100` window (incl. `CPU_CONTROL`)
  reads as zero, while the mailbox window at `+0x8000` returns live values. Read-as-zero
  plus write-ignored on the control page, with a live mailbox, is the signature of a
  control window the AP is not permitted to touch — expected for a Secure Enclave: the AP
  gets a mailbox and nothing else.

Note `sep.rs` never ioremaps its control region (`reg = <0x2 0x5e400000 0x0 0x6C000>`) and
has no CPU-start path — a real gap vs. every other Apple coprocessor driver — but on this
machine filling it would not help, because that write is ignored anyway.

## 3. It is not a LocalPolicy / boot-policy gate

Two macOS installs share the machine (`bputil -d`, same ECID `0x1C14C126FB401E`, BORD
`0x28`, CHIP `0x8112`, shared KEK group `kuid`):

| Field | Install 1 (stock macOS) | Install 2 (Asahi stub) |
|---|---|---|
| `love` | 25.6.80 (macOS 26) | 22.7.74 (macOS 13-era) |
| Security Mode | Reduced (`smb0`) | **Permissive (`smb0 && smb1`)** |
| CTRR (`sip2`) | Enabled | Disabled |
| `coih` (CustomKC/fuOS) | absent | present (m1n1 custom KC) |

The Asahi stub already boots at the loosest security Apple offers — Permissive Security,
CTRR off, custom kernel collection authorised. Its policy matches the
`local-policy-manifest` m1n1 hands to Linux exactly. **There is no looser LocalPolicy to
set**, so the SEP-start blocker is not a policy bit. What differs between "SEP boots"
(macOS) and "SEP dormant" (Linux) is the *handoff*, not the policy: a signed macOS kernel
+ `AppleSEPManager` starts and pairs SEPOS; the m1n1→Linux path never does, and the AP
cannot do it afterward (§2).

## 4. macOS reference: what a booted SEP exposes on this SoC

For whoever eventually reverses the endpoint protocols. Under macOS, `AppleSEPManager`
reports `sep-booted = Yes` and advertises 12 endpoints (`AppleSEPDeviceService`):

| Endpoint | Attaches | Meaning |
|---|---|---|
| `cntl` | — | control |
| `hibe` | `HibernationService` | hibernation key wrap |
| `stac` | `AppleTrustedAccessoryManager` | trusted accessory / STAC |
| `pnon` | — | pre-boot nonce |
| `hdcp` | — | HDCP |
| `xars` / `xarm` | — | XART anti-replay |
| `skdl` | — | secure key delivery |
| **`sbio`** | **`AppleMesaSEPDriver` → `AppleBiometricServices`** | **Touch ID (Mesa)** |
| `sse` | — | secure element |
| `scrd` | — | smartcard |
| `sks` | — (AppleKeyStore) | secure key store |

Touch ID is **`sep-endpoint,sbio`** (not `stac`). `AppleMesaSEPDriver` carries
`MesaCalBlobSource = "FDR"` — the Mesa calibration blob is sourced from factory secure
storage, and match is yes/no in-enclave, so any Linux driver would be a
libfprint/fprintd shim over a kernel verify call, with enrollment + calibration owned by
the SEP/FDR (realistically done under macOS). Hardware node: `biosensor,mesa` →
`AppleBiometricSensor`. ("Mesa" = Apple internal name for Touch ID, confirmed here.)

## 5. Bottom line

On t8112 booted via m1n1, the SEP cannot be started from Linux — not for want of DT
plumbing (solvable), not for want of a driver ioremap (a real but insufficient gap), and
not for want of a looser boot policy (already maximal). The SEP's ASC control window is
not AP-accessible on this boot path and its mailbox never advances. Bringing up SEP/Touch
ID therefore requires the firmware/handoff to start (and pair) SEPOS before Linux takes
over — upstream territory, matching the current "SEP: WIP, Touch ID: TBA" status.

## Environment / how to reproduce

- HW: `apple,j413` / `apple,t8112`, MacBook Air 13" M2 2022, ECID `0x1C14C126FB401E`
- macOS: 26.5.1 (25F80), `xnu-12377.121.6 RELEASE_ARM64_T8112`
- Linux: `linux-asahi 7.1.6` (tag `asahi-7.1.6-1`), m1n1 v1.5.2
- macOS probes: `ioreg -rc AppleSEPManager -l`, `ioreg -rc AppleMesaSEPDriver`,
  `sudo bputil -d`
- Linux probes: DT fixup (add `sep` alias + `status=okay`, rebuild boot.bin);
  instrumented `sep.rs` logging every mailbox message + `GETRAND` probe; small kernel
  modules reading the ASC mailbox/CPU-control registers directly (userspace blocked by
  `STRICT_DEVMEM`).

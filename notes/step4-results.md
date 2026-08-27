# Step 4 — the macOS ground truth: SEP endpoint map on booted j413

Collected 2026-08-26 from macOS 26.5.1 (build 25F80, `xnu-12377.121.6 RELEASE_ARM64_T8112`)
on the **same physical machine** (`target-type = J413`, `IOPlatformSerialNumber G9N04MY7JL`).
This is the data `notes/step3-results.md` said was answerable only from macOS. It is now
answered.

## The SEP booted and advertised its full endpoint set

`ioreg -rc AppleSEPManager -l` reports `"sep-booted" = Yes`, `HasXART = Yes`. Under it,
12 endpoints are advertised (`sep-endpoint,<tag>`), each a node of class
`AppleSEPDeviceService`:

| Endpoint | id | Kernel driver that attaches | Meaning |
|---|---|---|---|
| `cntl` | 0x8a6 | — (control channel) | SEP control |
| `hibe` | 0x8a4 | `HibernationService` (SEPHibernation) | hibernation key wrap |
| `stac` | 0x8a5 | `AppleTrustedAccessoryManager` | trusted accessory / STAC |
| `pnon` | 0x8a9 | — | pre-boot nonce? |
| `hdcp` | 0x8aa | — | HDCP key handling |
| `xars` | 0x8ab | — | XART anti-replay (server) |
| `xarm` | 0x8ac | — | XART anti-replay (manager) |
| `skdl` | 0x91e | — | secure key delivery? |
| **`sbio`** | **0x91f** | **`AppleMesaSEPDriver` → `AppleBiometricServices`** | **Touch ID (Mesa)** |
| `sse`  | 0x920 | — | secure element |
| `scrd` | 0x921 | — | smartcard |
| `sks`  | 0x92a | — (AppleKeyStore) | secure key store |

## The biometric endpoint is `sbio`, not `stac`

The README's Step 3 line guessed "the biometric/`stac` endpoint". Wrong tag. `stac` is
the **trusted-accessory** manager. Touch ID is **`sep-endpoint,sbio`**, and the driver
stack on top of it is:

```
sep-endpoint,sbio  (AppleSEPDeviceService)
  └─ AppleMesaSEPDriver        com.apple.driver.AppleMesaSEPDriver   IOProbeScore 1000
       IONameMatch = "sep-endpoint,sbio"
       MesaCalBlobSource = "FDR"
       └─ AppleBiometricServices  com.apple.driver.AppleBiometricServices
            └─ AppleBiometricServicesUserClient   <- userspace entry point
```

Separately there is a hardware-side stack for the physical sensor:
`biosensor,mesa` → `AppleBiometricSensor` / `AppleMesaResources` / `AppleMesaShim`
(`AppleMesaARMFunction` also present as a class). "Mesa" is Apple's internal name for
Touch ID; confirmed on this machine.

## New fact: calibration comes from FDR

`AppleMesaSEPDriver` carries `MesaCalBlobSource = "FDR"`. The Mesa sensor's calibration
blob is sourced from **FDR** (Factory Data Restore / effaceable secure storage), not from
a file in the OS. Implication for any Linux path: even with the SEP running and the `sbio`
protocol reversed, per-sensor calibration is held in SEP-owned secure storage, and
enrollment templates live in-enclave. This reinforces the Step-4 conclusion in the README:
match is yes/no in-enclave; enrollment realistically has to happen under macOS.

## How this squares with the Linux side (Steps 1–3)

None of this contradicts Steps 1–3 — it sits on the far side of the wall they hit:

- On **macOS**, iBoot/SEPROM starts SEPOS, SEPOS advertises these 12 endpoints, and the
  AP driver stack binds `sbio` for Touch ID.
- On **Asahi**, the AP cannot start the SEP at all (control page reads-as-zero,
  `CPU_CONTROL |= RUN` does not stick — `step2`/`step3`). So SEPOS never runs, no endpoint
  discovery happens, and `sbio` never appears. The Linux `sep.rs` throwing away
  `MSG_ADVERTISE_EP` is moot when nothing is ever advertised.

The lever remains on the firmware/boot-policy side: something has to start the SEP for us,
or start it in a state that survives the handoff to Linux. That is the LocalPolicy /
`bputil -d` thread (still pending — needs root; see below).

## LocalPolicy comparison — `bputil -d`, both installs (collected 2026-08-26)

Two macOS installs share one machine (same `ECID 0x1C14C126FB401E`, `BORD 0x28`,
`CHIP 0x8112`, and the **same `kuid` F2621434-…** — one KEK/owner group):

| Field | Install 1 `785CD95D` (real macOS) | Install 2 `F72F6C2E` (Asahi stub) |
|---|---|---|
| `love` (OS ver) | 25.6.80 (macOS 26) | **22.7.74** (macOS 13-era) |
| Security Mode | **Reduced** (`smb0`) | **Permissive** (`smb0 && smb1`) |
| 3rd-party kexts (`smb2`) | Enabled | absent |
| CTRR (`sip2`) | Enabled (absent) | **Disabled (`sip2=1`)** |
| `coih` (CustomKC/fuOS) | absent | **present** (= m1n1/Asahi custom KC) |
| `spih`/`auxp`/`auxi`/`auxr` | present | absent (stub, no cryptex/kext stack) |
| `nsih` (next-stage IMG4) | EC1F4F68… | C5B93645… |

**Install 2 is the Linux-booting policy, confirmed.** Its `love = 22.7.74.0.0,0`,
`smb0 && smb1`, and `sip2=1` match the DER we decoded from the m1n1-supplied
`local-policy-manifest` (`smb0=true smb1=true sip2=true lobo=true love="22.7.74.0.0,0"`)
**exactly**. `coih` present is the Asahi custom kernel collection; a stock macOS install
(install 1) has none.

### The load-bearing consequence

The Asahi boot **already runs at maximum permissive security** — `smb0 && smb1`
(Permissive), CTRR off, custom KC authorised. There is no looser LocalPolicy to set.
**So the SEP-start blocker is NOT a `bputil`/LocalPolicy bit** — it cannot be loosened
from the boot-policy side, because that side is already wide open. This retires the
"maybe a boot-policy flag gates the SEP" hypothesis from `step2`/`step3`.

What differs between the two boots is therefore *not* policy but the **handoff
mechanism**: under install 1, a signed macOS kernel + `AppleSEPManager` brings up and
pairs SEPOS; under install 2, iBoot hands off to m1n1→Linux, and on that path the SEP
control window is walled off from the AP (`step2`/`step3`) and SEPOS is never driven.
The remaining lever is the firmware/handoff itself — upstream Asahi territory
(matches their "SEP: WIP"), not a knob we can turn locally.

Note: `OS Pairing Status: Not Paired` on both — that is the MDM/remote-policy pairing
(these are personal, unsupervised installs), not the SEP↔OS hardware pairing, so it does
not bear on the SEP question.

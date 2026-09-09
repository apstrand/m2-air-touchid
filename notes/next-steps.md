# Current plan and Linux handoff

Updated 2026-09-08. This is the current plan; it supersedes the conclusions in
`step2-results.md`, `step3-results.md`, `upstream-summary.md`, and the more
confident interpretations in `step5-plan.md`, `step5-results.md`, and
`step6-tracer-plan.md`. Their recorded observations remain useful. This plan
incorporates both the August experiments and the September diagnostic draft.
The step numbers below describe the next work, not the original DT-enablement steps.

## Established state

- The patched DTB supplies the `sep` alias and enables the node. m1n1 supplies
  the firmware reservation and both manifests, and `apple_sep` binds.
- Linux has not received a boot acknowledgment. The sampled mailbox status has
  outgoing data pending and the incoming FIFO empty. There is no successful
  Linux SEP boot or biometric operation recorded in this repo.
- `step5-results.md` reports August m1n1 GETRAND send success, no reply at 1 ms
  or an additional 200 ms, and an ADT SEPFW region with `sepfw-load-at-boot=1`.
  It reports `sepfw-booted` and `sepfw-loaded` as absent. These are prior results,
  not experiments still awaiting their first run. The repo contains a written
  console excerpt, not a complete raw capture tied to binary hashes.
- macOS exposes `sbio` through `AppleMesaSEPDriver`, with calibration source
  reported as `FDR`. The macOS reference lists 12 SEP services.
- Zero reads and ignored writes at an assumed ASC CPU-control offset do not
  establish that SEP's CPU is halted or that Linux cannot boot it. Upstream
  `sep.rs` starts the boot sequence through the mailbox.
- Permissive LocalPolicy does not prove every firmware/policy dependency is
  irrelevant. FDR calibration does not prove enrollment must happen in macOS,
  or that Linux can reuse macOS enrollments.
- Send success means the AP submitted a request, not that a particular request
  remained queued. A nonempty FIFO sample does not identify its contents or
  establish continuous non-consumption. Missing ADT properties do not reveal
  the SEP core's execution state. Patch 0004 also labels failed fixed-width
  reads as `<absent>`; a future capture should distinguish absence from a
  property with an unexpected length.
- The current [Asahi SEP page](https://asahilinux.org/docs/hw/soc/sep/) describes
  XNU sending BOOT_TZ0 followed by IMG4.
  Neither its claimed sleep quote nor the driver's purported "already running"
  quote in Step 5 results appears in the sources checked on 2026-09-08.
  The support table's WIP/TBA status does not identify the missing operation.

## Where to work

Patch authoring and cross-compilation can run on macOS. Prefer native Asahi Linux
for the build, DTB packaging, and first boot experiment: that tests the boot path
where the failure was observed and supplies the distro's DTBs and U-Boot.
macOS remains the reference for later protocol tracing and a recovery path.
The second USB-C host recorded in the earlier notes is available for tracing.

## Plan

1. **Finish and validate m1n1 diagnostics and packaging.** Pin m1n1 to v1.5.2,
   matching the recorded Linux setup. Instrument initialization, GETRAND send
   and receive results, reply endpoint/type, and mailbox status before/after.
   Preserve the existing timeout and RNG behavior. Produce identified,
   checksummed m1n1 binaries and a separately staged candidate `boot.bin`.
   Verify the candidate contains the intended m1n1 binary and patched DTBs
   before installation. **Build and candidate staging are complete; hardware
   installation and capture remain pending.** The old build wrapper exists
   but applies the August variant and installs immediately (see below).
2. **Repeat the early baseline with attributable evidence.** The August run
   already reported m1n1-time silence. Record the new `SEPDBG` console output,
   build/patch/image hashes, boot-object and firmware versions, cold/warm boot
   state, and subsequent Linux SEP logs in one run. A valid early reply
   followed by Linux silence narrows attention to the intervening handoff and
   initialization. An early timeout needs further discrimination: initialization
   failure, pending outgoing data, or observations consistent with consumption
   without a valid reply. Status snapshots alone cannot track one request.
   A timeout alone does not prove a halted or wedged SEP.
3. **Validate the tracer, then trace the first Linux handshake.** Inspect
   mailbox initialization, MMIO writes, incoming activity, interrupts, and
   power transitions with m1n1.
   Compare a working reference and record firmware versions. Preserve a run of
   the original BOOT_TZ0 sequence: patch 0002 adds GETRAND immediately ahead of
   it. Check TZ0 configuration; prioritize firmware DMA mapping after TZ0
   responds, because upstream maps that firmware only after its second ACK.
   Avoid speculative CPU-start writes, FIFO resets, or generic RTKit handshakes
   without evidence that they apply to SEP.
   Repair the existing proxy/HV drafts before use (issues below). A bounded
   GET_STATUS experiment can then provide a separate liveness observation;
   require a fresh EP 0xff / type 0x66 response. It neither guarantees TZ0 will
   work nor makes a timeout evidence for a PMGR reset. A macOS reference can
   show only transitions after tracing starts; verify whether it captures
   bootstrap, re-pairing, or steady-state traffic instead of assuming one.
4. **Discover endpoints and investigate sbio.** First obtain repeatable Linux
   endpoint advertisements. Patch 0002 already enables advertisement logging.
   Then trace macOS sensor setup and authentication, including shared-memory
   traffic, calibration loading, and credential dependencies. Discover numeric
   mailbox endpoint IDs from advertisements; macOS IORegistry object IDs are
   not mailbox endpoint numbers. Firmware versions may expose different lists.
5. **Prove enrollment and matching, then integrate authentication.** Establish
   the ownership, credential, enrollment, and verification flows experimentally.
   Matching occurs inside SEP; expose authentication operations to Linux and
   subsequently integrate with libfprint/fprintd/PAM as appropriate. Neither
   cross-OS enrollment reuse nor a working Linux verification call exists yet.

## Saved implementation

Two versions of the diagnostic now coexist intentionally:

| Artifact | Purpose and validation state |
|---|---|
| `patches/0003-m1n1-log-sep-getrand.patch` | September baseline; preserves 1 ms timeout, adds status/build identity, omits RNG payloads; not compiled or boot-tested. |
| `patches/historical/0003-m1n1-log-sep-getrand-200ms.patch` | Exact August patch preserved for the reported 1 ms + 200 ms experiment. |
| `patches/0004-m1n1-dump-sep-provenance.patch` | ADT diagnostics layered on the historical patch; does not apply to the September baseline. |
| `scripts/build-m1n1.sh` | Historical build-and-install wrapper, pointed at the archived variant so its markers and patch 0004 remain consistent. |
| `scripts/build-m1n1-baseline.sh` | Revision-checked September build; records hashes and never installs. |
| `scripts/stage-boot-candidate.sh` | Assembles and verifies a candidate under `out/`; never writes `/boot` or `/run`. |
| `tracer/sep_probe.py`, `tracer/trace_sep.py` | August proxy/HV drafts, retained for repair and validation before hardware use. |

`patches/0003-m1n1-log-sep-getrand.patch` targets m1n1 v1.5.2, commit
`e266c09ee50971828c6a7ba02bb7f36a24a7692e`.

- Adds `asc_get_mailbox_status()` to read only the existing A2I/I2A control
  registers through the ASC object's discovered mailbox base.
- Adds a `SEPDBG` build tag and initialization result.
- Captures status before send, after send, and after the receive attempt.
  Reports the first exchange and failures, plus completion byte counts.
- Logs reply endpoint/type without printing RNG payloads. The existing
  unexpected-reply log is also changed to omit its payload.
- Adds no extra GETRAND requests, FIFO draining, CPU-control writes, or resets.
  It retains upstream's reply acceptance rule (command type 116); when
  interpreting logs, also check that the reported endpoint is 0xff.
- Prints transaction diagnostics after the exchange. Extra MMIO reads and
  logging between exchanges still perturb timing; this is diagnostic code.

**Timeout correction:** `SEP_TIMEOUT = 1000` is **1000 microseconds (1 ms)**.
`asc_recv_timeout()` takes `delay_usec`, not milliseconds. Earlier notes claiming
1000 ms are incorrect. `asc_send()` separately waits up to 200 ms for FIFO space.
Keep the timeout unchanged for the baseline; any longer-timeout experiment
should be a separately identified build.

The source was cloned and patched under `build/m1n1` on macOS. `build/` is
gitignored and will not transfer with the repo; the patch is the portable result.
The macOS clone includes its submodules. No image of this September revision
has been built, packaged, installed, or boot-tested. The August notes separately
report installed experimental builds. This merge/reassessment changes neither
boot files nor security policy.

The patch's blank context lines retain their required leading space.
Compilation and behavioral tests are pending; see merge validation below.

The macOS system Make is 3.81, which warns about the grouped target syntax in
m1n1's Makefile. A newer Make download was interrupted before it ran. LLVM is
present but standalone Homebrew LLD is absent. Moving to Linux avoids completing
that host-tool setup. No dependency download or build is left running.

## Existing tool issues to fix before hardware use

Source review against the local v1.5.2 checkout found:

- The historical build wrapper mutates its source checkout, uses the older
  diagnostic markers, and calls the installer immediately. Replace that flow
  with source verification, build manifests, and candidate staging. Its
  `CHAINLOADING=1` enables m1n1's Rust disk chainloader; appended U-Boot payloads
  do not require that option. Do not apply the two GETRAND variants together.
- Patch 0004 must be ported separately if ADT diagnostics are added to the
  September build. Record property existence and lengths before decoding;
  keep provenance logging distinct from claims about whether SEP is running.
- The probe constructs `SEP`, whose constructor calls `dart_init`, and drains
  the receive FIFO before sending GET_STATUS. Split passive status inspection
  from active mailbox probing and avoid unrelated DART initialization.
- Its drain retains old messages in `sep.msgs[0xff]`, and the response path
  accepts any message on that endpoint as success. Require a fresh STATUS_OK,
  bound send/drain/receive work, and use monotonic deadlines. Test stale replies,
  wrong reply types, a full transmit FIFO, continuous incoming traffic, and
  timeout without hardware.
- Both tools call `u.adt.pmgr_dev_get_addr`, which is absent from v1.5.2's ADT
  implementation. Resolve the PMGR register through that version's device and
  power-state tables, verify it against the target ADT, and confirm the tracer
  actually attaches before interpreting a missing PMGR event.
- The macOS wrapper has `run_guest.py -l` and `tee -a` writing the same log.
  Give the output one writer or separate files, and validate mailbox decoding,
  PMGR callback forwarding, and guest startup in a focused mock/harness first.

The existing `--reset` path is not the next experiment. Observing a PMGR value
does not establish that toggling its target nibble is a valid SEP reset sequence.

## Resume on Linux

From this repo, use a dedicated checkout so existing m1n1 work stays separate:

```sh
git clone --depth 1 --branch v1.5.2 --recurse-submodules --shallow-submodules https://github.com/AsahiLinux/m1n1.git build/m1n1
git -C build/m1n1 rev-parse HEAD
git -C build/m1n1 apply --check ../../patches/0003-m1n1-log-sep-getrand.patch
git -C build/m1n1 apply ../../patches/0003-m1n1-log-sep-getrand.patch
git -C build/m1n1 diff --check
make --version
make -C build/m1n1 ARCH= RELEASE=0 CHAINLOADING=0 M1N1_VERSION_TAG=v1.5.2-sepdbg-1 -j2
```

If `build/m1n1` already exists, inspect its commit and changes before proceeding;
do not overwrite it or apply the patch twice. GNU Make 4.3+ understands the
grouped targets. Native ARM64 GCC/binutils should suffice for this stage-2
build; `CHAINLOADING=0` does not link the Rust chainloader. `RELEASE=0` retains
the framebuffer console for diagnostics. Use a distinct build tag after any
diagnostic changes. Expected outputs are `build/m1n1/build/m1n1.bin` and
`build/m1n1/build/m1n1.macho`. Compilation on Linux is still unverified.

Before a hardware test, finish the remaining Step 1 work:

- Check patch application on a clean pinned tree, compile both outputs, and
  inspect the binary for the build tag and `SEPDBG` strings.
- Exercise initialization failure, send failure, receive timeout, unexpected
  reply, partial completion, and success in a focused host-side harness. Check
  that no uninitialized reply is decoded or random payload printed.
- Completed 2026-09-08/09: the repeatable build wrapper was exercised against
  the pinned checkout and produced `out/m1n1-baseline/v1.5.2-sepdbg-1/`.
  `m1n1.bin` SHA-256 is
  `84f2f2a18ec52006983153a0614cf0e682cfbac73695254175123e5109c9a2a0`.
  The build emitted only expected GNU ld `.ARM.attributes` warnings.
- Completed 2026-09-09: candidate packaging was exercised with the staged
  patched DTBs and `/usr/lib/asahi-boot/u-boot-nodtb.bin`. It verified the
  m1n1 and every DTB prefix (110 files) without writing `/boot` or `/run`.
  Candidate SHA-256 is recorded in `out/boot-candidate.bin.manifest`.
- Hardware boot and console capture remain pending; the candidate has not
  been installed.
  `scripts/build-dtb.sh` prepares DTBs on Linux, but neither it nor
  `scripts/install-boot-bin.sh` compiles m1n1.
- Upstream `update-m1n1` accepts `M1N1=/path/to/m1n1.bin` and an explicit target
  filename. Stage into `out/` first. It writes `/run/m1n1.conf`, so even staging
  may need sudo. `/etc/default/update-m1n1` can override environment variables:
  verify the actual candidate prefix against the intended m1n1 binary rather
  than assuming the override was honored. Verify the DTBs too.
- Keep the known bootable image and record its hash before installing the
  verified candidate. The merged installer accepts an `M1N1` override, but it
  installs directly and does not verify the effective binary or DTB selection.
  Finish staging and verification before relying on it for the new build.

## Merge validation (2026-09-08)

- Both variants apply and reverse cleanly on fresh copies of the relevant
  v1.5.2 source files; the historical variant followed by patch 0004 also passes.
- Applying the September patch reproduces the local `build/m1n1` source edits
  exactly. Its generated source diff passes whitespace checks.
- All shell scripts pass `bash -n`; both tracer files parse as Python. These
  are syntax checks, not validation of imports, proxy APIs, or hardware behavior.
- Local Markdown links, documentation/script whitespace checks, and the
  conflict-marker scan pass. Compilation and hardware tests remain future work.

## References checked on 2026-09-08

- [Asahi SEP boot flow](https://asahilinux.org/docs/hw/soc/sep/)
- [Upstream SEP driver](https://github.com/AsahiLinux/linux/blob/asahi/drivers/soc/apple/sep.rs)
- [m1n1 v1.5.2 SEP source](https://github.com/AsahiLinux/m1n1/blob/v1.5.2/src/sep.c)
- [m1n1 v1.5.2 ASC source and timeout units](https://github.com/AsahiLinux/m1n1/blob/v1.5.2/src/asc.c)
- [Boot image packaging](https://github.com/AsahiLinux/asahi-scripts/blob/main/update-m1n1)
- [Asahi M2 support: SEP WIP, Touch ID TBA](https://asahilinux.org/docs/platform/feature-support/m2/)
- [Apple biometric security](https://support.apple.com/guide/security/biometric-security-sec067eb0c9e/1/web/1)

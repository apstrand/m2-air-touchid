# `drivers/soc/apple/sep.rs` — what the in-tree driver does

Source: AsahiLinux/linux, branch `asahi`, 370 lines of Rust.
Its own `module_platform_driver!` description: *"Secure enclave processor stub driver"*.

Kconfig (`drivers/soc/apple/Kconfig`):

```
config APPLE_SEP
	tristate "Apple Secure Element Processor"
	depends on ARCH_APPLE || COMPILE_TEST
	depends on PM
	depends on RUST
	select RUST_APPLE_RTKIT
	select RUST_APPLE_MAILBOX
	help
	  A security co-processor persent on Apple SoCs, controlling transparent
	  disk encryption, secure boot, HDCP, biometric auth and probably more.
```

"biometric auth" is what the *hardware* does. The driver does none of it.

## probe() requirements

```rust
let res = of.reserved_mem_region_to_resource_byname(c"sepfw")?;   // needs memory-region + sepfw name
...
build_shmem():
    fwnode.property_read_array_vec(c"local-policy-manifest", ...)  // needs lpol from ADT
    fwnode.property_read_array_vec(c"iboot-manifest", ...)         // needs ibot from ADT
```

All three are injected by m1n1's `dt_set_sep()`, which is gated on the `sep`
alias existing in the FDT. On a stock machine none of them are present — see
`../README.md`.

## Boot sequence the driver drives

Mailbox message layout: `ep = msg0 & 0xFF`, `type = (msg0 >> 16) & 0xFF`,
`param = (msg0 >> 24) & 0xFF`, `data = msg0 >> 32`.

| const | value | |
|---|---|---|
| `EP_BOOT` | 0xFF | boot ROM endpoint (same one m1n1 uses for GETRAND) |
| `EP_SHMEM` | 0xFE | shared memory setup |
| `EP_DISCOVER` | 0xFD | endpoint advertisement |
| `MSG_BOOT_TZ0` | 0x5 | → acked by 0x69, then 0xD2 |
| `MSG_BOOT_IMG4` | 0x6 | → acked by 0x6A |
| `MSG_SET_SHMEM` | 0x18 | |

1. `probe()` → `start()` sends `MSG_BOOT_TZ0` on `EP_BOOT`.
2. `MSG_BOOT_TZ0_ACK2` (0xD2) → `load_fw_and_shmem()`:
   `dma_map_resource()` the sepfw region, send `MSG_BOOT_IMG4` with the IOVA
   (`>> 12`), then `MSG_SET_SHMEM` with the shmem IOVA.
3. SEPOS comes up and starts advertising endpoints on `EP_DISCOVER`.

The 0x30000 shmem block is built by `build_shmem()` with four tagged sections:
`CNIP` (panic buffer, 0x8000 @ 0x4000), `OPLA` (local policy manifest),
`IPIS` (iBoot manifest), `llun` (terminator — "null" backwards).

## Where it stops

```rust
fn process_message(&self, msg: Message) {
    let ep = msg.msg0 & MSG_EP_MASK;
    match ep {
        EP_BOOT => self.process_boot_msg(msg),
        EP_DISCOVER => self.process_discover_msg(msg),
        _ => {}                    // <-- everything else dropped on the floor
    }
}
```

and inside `process_discover_msg`, the `MSG_ADVERTISE_EP` arm is an empty block
with the `dev_info!` commented out. So the driver learns the endpoint list and
immediately forgets it.

There is no SKS endpoint, no `stac` endpoint (which Asahi's SEP docs suggest is
the Touch ID path — "AppleTrustedAccessory talks to this endpoint, likely for the
Touch ID sensor"), no OOL buffer handling beyond the boot shmem, and no chardev,
input device, or any other userspace interface.

**Conclusion:** enabling the node gets SEPOS booted and gets us a list of endpoint
names. That is the entire payoff of step 1. Everything after that is new code.

## Notes toward step 3

- Asahi's SEP page describes SKS IPC version negotiation between AP and SEP —
  lowest common version wins — so an endpoint handshake is expected before any
  useful traffic.
- Prior art in-tree for the shape of this: `chaos_princess`'s reverse-engineering
  of the SEP endpoint that gates the hardware mic switch (some machines route the
  mic data lines through the SEP; if SEP is unhappy, no mic). That was a stub
  driver toggling one thing, and it is the closest existing example of driving a
  non-boot SEP endpoint.
  > **Correction (2026-08-27, Step 5.5):** not confirmed in the `linux-asahi 7.1.6`
  > tree. There is **no** `sep-endpoint` driver in-tree and `apple,sep` has only one
  > consumer (`sep.rs`), which discards advertised endpoints. If a mic-switch SEP
  > driver exists it is out-of-tree / a different branch — do not treat it as shipped
  > prior art. See `notes/step5-results.md` §5.5.
- Matching happens inside SEPOS. The AP never sees fingerprint images, so the
  eventual userspace shape is a verify-yes/no call, not a libfprint image driver.
- Enrolment almost certainly has to happen in macOS — we do not control the SEP
  firmware that gets loaded, and the enrolment path is part of it.

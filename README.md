# FabricKit

The layer under [iSCSIKit](https://github.com/MacFabric/iSCSIKit) and
[NVMeKit](https://github.com/MacFabric/NVMeKit): what an iSCSI initiator and an
NVMe/TCP host have in common once the protocol is taken away.

- **Transport.** `ConnectionTransport` is the byte-stream seam both engines
  speak. `NetworkTransport` implements it over Network.framework TCP (Nagle
  off, keepalive on, optionally pinned to one network interface with
  `InterfaceBinding`), and `MemoryPipe` is an in-memory pair for tests.
- **CRC32C**, the iSCSI digest and NVMe/TCP's HDGST/DDGST, on the hardware
  instruction (arm64, SSE4.2) with a slice-by-8 fallback.
- **`withDeadline`**, and big-endian `Data` accessors (`beU32`, `setBE32`, …)
  that index from a slice's `startIndex`, so they are safe on a sub-range.
- **One block device surface.** `BlockDeviceBackend`, `BlockDeviceError` and
  `BlockRequest` describe a LUN or a namespace the same way, so a consumer
  need not know which protocol is underneath.
- **Session vocabulary.** `SessionPolicy` (keepalive, recovery attempts and
  backoff, task, login and logout timeouts), `SessionError` and
  `SessionEvent`.

FabricKit has no protocol in it and no policy of its own. You will rarely
import it directly: iSCSIKit and NVMeKit both re-export it.

## FabricTestSupport

Building blocks for mock targets, for test code only: `RAMDisk` (with a
volatile write cache and simulated power loss), `MockTargetServer` (a TCP
listener that serves each accepted connection), `MockTargetFaults`, `FaultBox`
and `FaultSetting`, plus `testPolicy()`, `eventually` and `ConnectGate`.
iSCSIKit's `iSCSIMockTarget` and NVMeKit's `NVMeMockTarget` are built on it.

## Use

```swift
.package(url: "https://github.com/MacFabric/FabricKit", .upToNextMinor(from: "0.1.0")),
```

Before 1.0 a minor release may change the API, so depend up to the next minor
version.

## Requirements

macOS 15 or later, Swift 6 (language mode 6).

## Testing

```sh
swift test --no-parallel
```

Serial on purpose: some tests bound real durations (a 100 ms deadline must
have fired two seconds later), and a saturated machine makes every
continuation late without making any timeout wrong.

## Provenance

Developed as part of [iSCSI-NVMe-TCP](https://github.com/MacFabric/iSCSI-NVMe-TCP),
a user-space iSCSI and NVMe/TCP initiator for macOS, and split out of it with
its history on 2026-11-15. Comments that cite `docs/…` refer to that
repository.

## License

Apache 2.0. See [LICENSE](LICENSE).

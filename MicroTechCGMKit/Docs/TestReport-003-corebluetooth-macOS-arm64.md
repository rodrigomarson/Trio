# MicroTechCGMKit test report 003

Date: 2026-07-14

Feature branch: `feature/microtech-smart2-cgm`

Protocol-core checkpoint: `63a6b0c`

Simulated-transport implementation checkpoint: `98bddbd`

CoreBluetooth-bridge implementation checkpoint: `357424f`

Tested archive checkpoint: `6d32286`

Test host: Apple Silicon Mac

Reported target platform: `arm64e-apple-macos14.0`

Testing Library version: `1902`

Dependency: CryptoSwift `1.10.0`

## Result

Status: **PASS — archive integrity verified, CoreBluetooth adapter compiled, and all 50 XCTest cases passed**

Every entry in `SOURCE_MANIFEST.sha256` was verified before the build. Swift Package Manager resolved CryptoSwift 1.10.0, compiled the package on macOS, linked `MicroTechCGMKitPackageTests`, and executed all 50 XCTest cases with zero failures or unexpected failures.

| Test suite | Tests | Failures |
|---|---:|---:|
| `BluetoothTransportTests` | 5 | 0 |
| `ChecksumTests` | 3 | 0 |
| `CommandTests` | 3 | 0 |
| `ConnectionCoordinatorTests` | 11 | 0 |
| `DeviceDiscoveryTests` | 7 | 0 |
| `LiveGlucosePacketTests` | 7 | 0 |
| `ProtocolCryptoTests` | 5 | 0 |
| `PublicationGateTests` | 3 | 0 |
| `SensorSerialTests` | 4 | 0 |
| `TransportTests` | 2 | 0 |
| **Total** | **50** | **0** |

Reported build time: 14.27 seconds.

The XCTest run reported 0.014 seconds of test execution and 0.017 seconds total.

## Behaviors added to this validation phase

In addition to all phase-2 behaviors, this run validated the platform-independent Bluetooth boundary for:

- forwarding every coordinator transport command to a driver;
- accepting only validated protocol-family advertisements;
- recognizing short and full Bluetooth UUID forms;
- routing connection, characteristic, notification, and value callbacks only for the active peripheral;
- ignoring callbacks from unrelated peripheral identifiers;
- handling connection failure and disconnection deterministically;
- mapping Bluetooth availability and typed, redacted transport failures;
- stopping the coordinator safely after an active transport failure; and
- ignoring stale transport events while the coordinator is idle.

Because the test ran on macOS, `canImport(CoreBluetooth)` was true and the real `MicroTechCoreBluetoothDriver.swift` source was included in the successful package build. The unit tests use a fake driver and therefore do not initiate scanning, request Bluetooth permission, or exercise an actual peripheral.

## Source identity

The test was run from `MicroTechCGMKit-phase3-6d32286`. Before `swift test`, `shasum -a 256 -c SOURCE_MANIFEST.sha256` reported `OK` for every listed source, test, package, checkpoint, and documentation file. This confirms that the submitted result applies to the intended phase-3 archive.

## Interpretation of the final “0 tests” line

After the XCTest run completed successfully, the toolchain printed a separate result from the Swift Testing runner:

```text
Test run with 0 tests in 0 suites passed
```

This package currently contains XCTest tests, not Swift Testing (`@Test`) tests. The separate zero-test result is expected and does not invalidate or replace the preceding 50-test XCTest result.

## Conclusion and scope limitation

The CoreBluetooth bridge phase is complete at the compilation and synthetic-test level. The tested source code is unchanged by this report.

This result does not validate a physical SMART 2.0 sensor, the Brazilian advertisement name, actual characteristic properties, iOS bonding, background restoration, real history-packet framing, glucose accuracy, or Trio/LoopKit integration. Experimental output remains unsuitable for treatment decisions or closed-loop dosing.

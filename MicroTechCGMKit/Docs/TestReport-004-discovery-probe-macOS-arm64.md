# MicroTechCGMKit test report 004

Date: 2026-07-14

Feature branch: `feature/microtech-smart2-cgm`

Protocol-core checkpoint: `63a6b0c`

Simulated-transport implementation checkpoint: `98bddbd`

CoreBluetooth-bridge implementation checkpoint: `357424f`

Read-only discovery-probe implementation checkpoint: `d9a9062`

macOS entry-point visibility correction: `6ec3e73`

Discovery-report privacy hardening: `80c1d45`

Tested archive checkpoint: `cc7a528`

Test host: Apple Silicon Mac

Reported target platform: `arm64e-apple-macos14.0`

Testing Library version: `1902`

Dependency: CryptoSwift `1.10.0`

## Result

Status: **PASS — archive integrity verified, both executable configurations built, all 58 XCTest cases passed, and the macOS app bundle was signed and verified**

Every entry in `SOURCE_MANIFEST.sha256` was verified before the build. Swift Package Manager resolved CryptoSwift 1.10.0 and compiled the `MicroTechDiscoveryProbe` debug product in 7.25 seconds. The test package built in 7.38 seconds and executed all 58 XCTest cases with zero failures or unexpected failures.

| Test suite | Tests | Failures |
|---|---:|---:|
| `BluetoothTransportTests` | 5 | 0 |
| `ChecksumTests` | 3 | 0 |
| `CommandTests` | 3 | 0 |
| `ConnectionCoordinatorTests` | 11 | 0 |
| `DeviceDiscoveryTests` | 8 | 0 |
| `DiscoveryReportTests` | 7 | 0 |
| `LiveGlucosePacketTests` | 7 | 0 |
| `ProtocolCryptoTests` | 5 | 0 |
| `PublicationGateTests` | 3 | 0 |
| `SensorSerialTests` | 4 | 0 |
| `TransportTests` | 2 | 0 |
| **Total** | **58** | **0** |

The XCTest run reported 0.018 seconds of test execution and 0.021 seconds total.

The app-bundle script then:

- built the `MicroTechDiscoveryProbe` release product in 12.75 seconds;
- created `.build/MicroTechDiscoveryProbe.app`;
- validated `Contents/Info.plist` successfully;
- applied an ad-hoc code signature; and
- completed `codesign --verify --deep --strict` with exit status zero and no output.

## Behaviors added to this validation phase

In addition to all phase-3 behaviors, this run validated the synthetic discovery and reporting boundary for:

- accepting both short and full protocol-service UUID forms;
- recognizing only known protocol-family names with a valid serial-shaped suffix;
- rejecting malformed names, unknown families, missing services, and unknown characteristics;
- normalizing and sorting captured metadata deterministically;
- explicitly representing empty metadata;
- redacting a ten-character serial suffix;
- fully redacting unstructured local names;
- not exposing extra content from malformed known-family names; and
- formatting the report without sensor values, key material, or unredacted identifiers.

The real CoreBluetooth probe executable compiled in both Debug and Release configurations. It was not launched during this checkpoint.

## Source identity

The test was run from `MicroTechCGMKit-phase4-cc7a528`. Before any build, `shasum -a 256 -c SOURCE_MANIFEST.sha256` reported `OK` for every listed source, test, package, checkpoint, tool, and documentation file. This confirms that the submitted result applies to the privacy-hardened phase-4 archive.

## Interpretation of the final “0 tests” line

After the XCTest run completed successfully, the toolchain printed a separate result from the Swift Testing runner:

```text
Test run with 0 tests in 0 suites passed
```

This package currently contains XCTest tests, not Swift Testing (`@Test`) tests. The separate zero-test result is expected and does not invalidate or replace the preceding 58-test XCTest result.

## Safety outcome and scope limitation

The probe was not launched. No Bluetooth permission was requested, no scan or connection occurred, and no physical sensor or personal health data was accessed. The returned evidence did not contain a sensor serial, peripheral identifier, key material, or glucose value.

Phase 4 is complete at the pre-hardware compilation, synthetic-test, packaging, and signature-verification level. This result does not validate a physical SMART 2.0 sensor, the Brazilian advertisement name, actual GATT services or characteristic properties, iOS bonding, background restoration, real history-packet framing, glucose accuracy, or Trio/LoopKit integration. Experimental output remains unsuitable for treatment decisions or closed-loop dosing.

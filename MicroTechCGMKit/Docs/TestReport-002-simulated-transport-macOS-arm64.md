# MicroTechCGMKit test report 002

Date: 2026-07-14

Feature branch: `feature/microtech-smart2-cgm`

Protocol-core checkpoint: `63a6b0c`

Simulated-transport implementation checkpoint: `98bddbd`

Tested archive checkpoint: `5c5eab1`

Test host: Apple Silicon Mac

Reported target platform: `arm64e-apple-macos14.0`

Testing Library version: `1902`

Dependency: CryptoSwift `1.10.0`

## Result

Status: **PASS — archive integrity verified and all 41 XCTest cases passed**

Every entry in `SOURCE_MANIFEST.sha256` was verified before the build. Swift Package Manager resolved CryptoSwift 1.10.0, completed the debug build, linked `MicroTechCGMKitPackageTests`, and executed all 41 XCTest cases with zero failures or unexpected failures.

| Test suite | Tests | Failures |
|---|---:|---:|
| `ChecksumTests` | 3 | 0 |
| `CommandTests` | 3 | 0 |
| `ConnectionCoordinatorTests` | 9 | 0 |
| `DeviceDiscoveryTests` | 5 | 0 |
| `LiveGlucosePacketTests` | 7 | 0 |
| `ProtocolCryptoTests` | 5 | 0 |
| `PublicationGateTests` | 3 | 0 |
| `SensorSerialTests` | 4 | 0 |
| `TransportTests` | 2 | 0 |
| **Total** | **41** | **0** |

Reported build time: 13.44 seconds.

The XCTest run reported 0.016 seconds of test execution and 0.019 seconds total.

## Behaviors added to this validation phase

In addition to the protocol-core behaviors recorded in test report 001, this run validated:

- discovery matching for the standard Continuous Glucose Monitoring service UUID and known protocol-family advertisement prefixes;
- strict rejection of missing services, unknown family names, and invalid serial suffixes;
- deterministic new-pairing command sequencing;
- session-key validation and encrypted synchronization commands;
- deterministic reconnect behavior that reuses an existing master key;
- paged synthetic backfill, deduplication, and five-minute publication cadence;
- safe failure for missing characteristics, invalid session checksums, unexpected history pages, and empty non-final history pages;
- deterministic timeout and retry backoff behavior;
- live-packet safety filtering and publication gating;
- fake-transport command recording; and
- redaction of secret key bytes from diagnostic descriptions.

## Source identity

The test was run from the checkpoint-specific directory `MicroTechCGMKit-phase2-5c5eab1`. Before `swift test`, `shasum -a 256 -c SOURCE_MANIFEST.sha256` reported `OK` for every listed source, test, package, checkpoint, and documentation file. This confirms that the submitted result applies to the intended phase-2 archive rather than a previously extracted directory.

## Interpretation of the final “0 tests” line

After the XCTest run completed successfully, the toolchain printed a separate result from the Swift Testing runner:

```text
Test run with 0 tests in 0 suites passed
```

This package currently contains XCTest tests, not Swift Testing (`@Test`) tests. The separate zero-test result is expected and does not invalidate or replace the preceding 41-test XCTest result.

## Conclusion and scope limitation

The simulated transport and connection-coordinator phase is complete at the synthetic-test level. The tested source code is unchanged by this report.

This result does not validate CoreBluetooth, iOS bonding, communication with a physical SMART 2.0 sensor, real history-packet framing, background reconnection, glucose accuracy, or Trio/LoopKit integration. Experimental output remains unsuitable for treatment decisions or closed-loop dosing.

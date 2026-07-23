# MicroTechCGMKit test report 001

Date: 2026-07-14

Feature branch: `feature/microtech-smart2-cgm`

Expected implementation checkpoint: `63a6b0c`

Test host: Apple Silicon Mac

Reported target platform: `arm64e-apple-macos14.0`

Testing Library version: `1902`

Dependency: CryptoSwift `1.10.0`

## Result

Status: **PASS, with source-identity verification pending**

The Swift package resolved CryptoSwift 1.10.0, completed a debug build, linked `MicroTechCGMKitPackageTests`, and executed all 25 XCTest cases with zero failures or unexpected failures.

| Test suite | Tests | Failures |
|---|---:|---:|
| `ChecksumTests` | 3 | 0 |
| `CommandTests` | 3 | 0 |
| `LiveGlucosePacketTests` | 7 | 0 |
| `ProtocolCryptoTests` | 5 | 0 |
| `PublicationGateTests` | 3 | 0 |
| `SensorSerialTests` | 4 | 0 |
| **Total** | **25** | **0** |

Reported build time: 13.61 seconds.

Reported XCTest execution time: 0.005 seconds, 0.007 seconds total.

## Behaviors validated

- CRC8/MAXIM and CRC16-CCITT-FALSE vectors;
- command identifiers, payload byte order, and trailing CRC wire order;
- strict processed-glucose packet decoding;
- signed trend conversion;
- packed glucose, warm-up, validity, unknown flags, and ended-sensor handling;
- rejection of invalid CRCs and every truncated live-packet length;
- serial normalization and rejection of invalid serial input;
- serial-derived key request and IV vectors;
- NIST AES-CFB128 vector;
- synthetic encrypted session-key packet and CRC8 validation;
- rejection of invalid AES key length and invalid session-key checksum;
- deterministic five-minute publication gating;
- duplicate and out-of-order minute-index rejection.

## Interpretation of the final “0 tests” line

After the XCTest run completed successfully, the toolchain printed a second result from the newer Swift Testing runner:

```text
Test run with 0 tests in 0 suites passed
```

This is expected because this package currently contains XCTest tests, not Swift Testing (`@Test`) tests. It does not invalidate or replace the preceding 25-test XCTest result.

## Source-identity caveat

The submitted terminal transcript first reported:

```text
unzip: cannot find or open MicroTechCGMKit_experimental_63a6b0c.zip
```

The following `cd MicroTechCGMKit` command nevertheless succeeded, which means the tests ran from a pre-existing `~/Downloads/MicroTechCGMKit` directory rather than a directory extracted during this command sequence.

The suite names and 25-test count match checkpoint `63a6b0c`, so the result is strong implementation evidence. Exact byte-for-byte identity with the supplied ZIP or git checkpoint remains to be confirmed before this report is treated as a reproducible release-artifact test.

## Next verification

Repeat the test from either:

1. a freshly extracted copy of `MicroTechCGMKit_experimental_63a6b0c.zip`; or
2. a Trio clone with commit `63a6b0c` applied on `feature/microtech-smart2-cgm`.

Record the package path, git commit when applicable, SHA-256 of the ZIP, Xcode version, Swift version, macOS version, and complete `swift test` result.

## Scope limitation

This report validates only the transport-independent synthetic protocol core. It does not validate CoreBluetooth, iOS bonding, a SMART 2.0 sensor, live glucose accuracy, backfill, background operation, or Trio/LoopKit integration. Experimental output remains unsuitable for treatment decisions or closed-loop dosing.

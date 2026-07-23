# MicroTechCGMKit test report 001

Date: 2026-07-14

Feature branch: `feature/microtech-smart2-cgm`

Protocol-core checkpoint: `63a6b0c`

Tested archive checkpoint: `fc752f2`

Test host: Apple Silicon Mac

Reported target platform: `arm64e-apple-macos14.0`

Testing Library version: `1902`

Dependency: CryptoSwift `1.10.0`

## Result

Status: **PASS — reproduced from the fresh checkpoint archive**

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

Initial reported build time: 13.61 seconds.

Reproducibility-run build time: 13.24 seconds.

Both runs reported 0.005 seconds of XCTest execution and 0.007 seconds total.

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

## Reproducibility and source identity

The submitted terminal transcript first reported:

```text
unzip: cannot find or open MicroTechCGMKit_experimental_63a6b0c.zip
```

The following `cd MicroTechCGMKit` command nevertheless succeeded, which means the tests ran from a pre-existing `~/Downloads/MicroTechCGMKit` directory rather than a directory extracted during this command sequence.

That first run was therefore treated as provisional even though its suite names and 25-test count matched checkpoint `63a6b0c`.

The archive for checkpoint `fc752f2` was then downloaded again. Safari automatically extracted it as `~/Downloads/MicroTechCGMKit-2` because a `MicroTechCGMKit` directory already existed. The fresh directory was identified by both:

- `Package.swift`; and
- the checkpoint-specific `Docs/TestReport-001-macOS-arm64.md` file.

Running `swift test` in that fresh directory resolved CryptoSwift 1.10.0, rebuilt the package, and repeated all 25 XCTest cases with zero failures or unexpected failures at 2026-07-14 20:49:35 local host time.

Expected generated ZIP SHA-256: `9616d9218fabff3dedb5e9d609789f0714d198baf41cfc3962ed2ac50c7a882e`. The Mac did not hash the ZIP because Safari automatically extracted the download, but checkpoint identity and reproducible package behavior were independently confirmed from the fresh directory.

Future test archives should include a source manifest inside the extracted directory so Safari auto-extraction does not prevent local integrity verification.

## Scope limitation

This report validates only the transport-independent synthetic protocol core. It does not validate CoreBluetooth, iOS bonding, a SMART 2.0 sensor, live glucose accuracy, backfill, background operation, or Trio/LoopKit integration. Experimental output remains unsuitable for treatment decisions or closed-loop dosing.

# MicroTechCGMKit test report 004 — attempt 002

Date: 2026-07-14

Feature branch: `feature/microtech-smart2-cgm`

Read-only discovery-probe implementation checkpoint: `d9a9062`

macOS entry-point visibility correction: `6ec3e73`

Tested archive checkpoint: `c47f6b4`

Test host: Apple Silicon Mac

Reported target platform: `arm64e-apple-macos14.0`

Testing Library version: `1902`

Dependency: CryptoSwift `1.10.0`

## Result

Status: **STOPPED AT PRIVACY TEST — executable compiled; 57 tests ran with 1 failure**

Every entry in `SOURCE_MANIFEST.sha256` was verified successfully. The `MicroTechDiscoveryProbe` debug product then compiled successfully in 6.51 seconds. The test package built in 7.67 seconds and executed all 57 expected XCTest cases.

Fifty-six tests passed. One privacy test failed:

```text
DiscoveryReportTests.testDoesNotExposeUnstructuredLocalName
expected: <redacted-local-name>
actual:   Sen<redacted-10-character-suffix>
```

## Cause and correction

The redaction function treated any local name longer than 10 ASCII alphanumeric characters as a prefix plus a serial-shaped suffix. For the unstructured fixture `SensitiveName`, that preserved its first three characters. The test correctly rejected this partial disclosure.

The correction now preserves a family prefix only when it matches a known MicroTech family. A malformed known-family name is reduced to the known prefix plus an invalid-name redaction marker. An unstructured name without a safe separator is fully redacted. A new regression test ensures that extra content in a malformed SMART-family name is not exposed.

Privacy-hardening commit: `80c1d45`

The corrected suite contains 58 XCTest cases.

## Safety outcome

The `set -e` sequence stopped immediately after the failing test command. Therefore:

- the release app-bundle build did not run;
- property-list validation did not run;
- code signing and signature verification did not run;
- the executable was not launched;
- no Bluetooth permission was requested;
- no scan or peripheral connection occurred; and
- no physical sensor or health data was accessed.

Phase 4 remains pending until a corrected, manifest-verified checkpoint completes the full test plan.

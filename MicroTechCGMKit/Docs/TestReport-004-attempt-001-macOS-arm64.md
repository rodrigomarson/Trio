# MicroTechCGMKit test report 004 — attempt 001

Date: 2026-07-14

Feature branch: `feature/microtech-smart2-cgm`

Read-only discovery-probe implementation checkpoint: `d9a9062`

Tested archive checkpoint: `1da8841`

Test host: Apple Silicon Mac

Dependency: CryptoSwift `1.10.0`

## Result

Status: **STOPPED AT COMPILE — no tests or probe execution occurred**

Every entry in `SOURCE_MANIFEST.sha256` was verified successfully. Swift Package Manager resolved CryptoSwift 1.10.0 and then stopped while emitting the `MicroTechDiscoveryProbe` module.

The compiler reported that the two top-level constants inferred private implementation types but were themselves declared with the default internal visibility:

```text
constant must be declared private or fileprivate because its type
'ProbeConfiguration' uses a private type

constant must be declared private or fileprivate because its type
'ReadOnlyMetadataProbe' uses a private type
```

The affected constants were the executable entry-point instances named `configuration` and `probe`.

## Cause and correction

The executable's private helper types were intentional, but their two top-level instances also needed explicit private visibility under the Mac compiler. The minimal correction adds `private` to those constants without changing scanning, filtering, reporting, privacy, or Bluetooth behavior.

Correction commit: `6ec3e73`

## Safety outcome

The `set -e` test sequence stopped at `swift build --product MicroTechDiscoveryProbe`. Therefore:

- no XCTest cases ran from this checkpoint;
- the app bundle was not created;
- the executable was not launched;
- no Bluetooth permission was requested;
- no scan or peripheral connection occurred; and
- no physical sensor or health data was accessed.

Phase 4 remains pending until a corrected, manifest-verified checkpoint completes the full test plan.

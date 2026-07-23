# MicroTechCGMKit test plan 004

## Goal

Compile the read-only discovery-probe executable, run the complete synthetic suite, and create an ad-hoc-signed macOS app bundle without launching the probe or accessing Bluetooth.

No SMART 2.0 sensor is needed for this checkpoint. None of the commands below runs `MicroTechDiscoveryProbe`.

## Preconditions

- Apple Silicon Mac;
- a current Xcode command-line toolchain;
- the checkpoint-specific phase-4 ZIP; and
- network access if CryptoSwift 1.10.0 is not already cached.

## Commands

Run these commands from the extracted package directory:

```sh
set -e
cat CHECKPOINT.txt
shasum -a 256 -c SOURCE_MANIFEST.sha256
swift build --product MicroTechDiscoveryProbe
swift test
./Tools/build-macos-discovery-probe.sh
/usr/bin/codesign --verify --deep --strict \
  .build/MicroTechDiscoveryProbe.app
```

## Expected result

- every manifest entry reports `OK`;
- CryptoSwift resolves at version 1.10.0;
- the `MicroTechDiscoveryProbe` executable product builds successfully;
- exactly 57 XCTest cases execute with zero failures;
- the release executable builds successfully;
- `Info.plist` passes `plutil -lint`;
- ad-hoc code signing succeeds; and
- `codesign --verify` exits successfully without output.

The toolchain may print a separate final line saying that Swift Testing ran 0 tests in 0 suites. That is expected because this package currently uses XCTest.

## Evidence to return

Copy the complete Terminal output starting with `cat CHECKPOINT.txt` and ending after `codesign --verify`. Do not launch the generated app. This pre-hardware transcript must not contain a sensor serial, peripheral identifier, key material, glucose value, or other personal health information.

## Failure rule

If the manifest, executable build, tests, property-list validation, signing, or signature verification fails, stop at that point and preserve the complete error output. Do not bypass signing, edit the app bundle manually, or run the probe.

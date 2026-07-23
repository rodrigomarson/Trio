# MicroTechCGMKit test plan 003

## Goal

Compile the conditional CoreBluetooth driver on an Apple platform and run the complete transport-independent suite from a manifest-verified phase-3 archive.

No SMART 2.0 sensor is needed for this checkpoint. The test suite does not initiate scanning or request Bluetooth permission because it uses a fake driver. A successful macOS build nevertheless compiles `MicroTechCoreBluetoothDriver.swift` against Apple's CoreBluetooth framework.

## Preconditions

- Apple Silicon Mac;
- a current Xcode command-line toolchain;
- the checkpoint-specific phase-3 ZIP; and
- network access if CryptoSwift 1.10.0 is not already cached.

## Commands

Run these commands from the extracted package directory:

```sh
cat CHECKPOINT.txt
shasum -a 256 -c SOURCE_MANIFEST.sha256
swift test
```

If Safari extracted the ZIP automatically, use the directory whose name begins with `MicroTechCGMKit-phase3-`. Do not reuse an older `MicroTechCGMKit` directory.

## Expected result

- every manifest entry reports `OK`;
- CryptoSwift resolves at version 1.10.0;
- `MicroTechCGMKitPackageTests` links successfully;
- exactly 50 XCTest cases execute;
- zero failures and zero unexpected failures; and
- the target platform reports Apple Silicon macOS.

The toolchain may print a separate final line saying that Swift Testing ran 0 tests in 0 suites. That is expected because this package currently uses XCTest.

## Evidence to return

Copy the complete Terminal output starting with `cat CHECKPOINT.txt` and ending after the final test result. The transcript must not contain a real sensor serial, peripheral identifier, key material, glucose value, or other personal health information.

## Failure rule

If the manifest, compilation, link, count, or any test fails, stop at that point. Preserve the complete error output and do not attempt hardware scanning from this checkpoint.

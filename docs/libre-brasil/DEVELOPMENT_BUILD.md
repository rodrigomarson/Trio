# Trio Libre Brazil development build

## Build identity

| Item | Value |
| --- | --- |
| Upstream baseline | Trio `dev` at `40d45894db5c53ca6b9e67237b2c6d57ea31670c` |
| Upstream development version | `0.8.4.16` |
| This development version | `0.8.4.17` |
| Apple development team | `6KLJLLTX3K` |
| Bundle identifier | `org.nightscout.6KLJLLTX3K.trio` |
| Shared scheme | `Trio` |
| Distribution | Xcode Cloud to TestFlight |

This branch is the first safe diagnostic stage for direct support of the Brazilian
FreeStyle Libre 2 Plus. It does not yet convert Brazilian sensor frames into glucose
values. Its purpose is to identify the sensor reliably, preserve the captured NFC
data, and avoid sending an unverified European streaming command to the sensor.

## Evidence boundary

The initial classifier is based on Brazilian Libre 2 Plus captures with patch info
`2B 0A 3A 08 1F E1` and product family 3. Community investigations also report that
the official LibreLink path recognizes these sensors while current European direct
algorithms reject them. See the related xDrip investigations
[#3545](https://github.com/NightscoutFoundation/xDrip/discussions/3545) and
[#4028](https://github.com/NightscoutFoundation/xDrip/discussions/4028).

These observations identify a distinct protocol family; they do not establish a safe
streaming activation or decryption algorithm. That uncertainty is why this build
captures read-only NFC evidence before adding a Brazilian protocol driver.

## What changed

- Recognizes patch-info values beginning with `0x2B` as Libre 2 Plus Brazil.
- Classifies the sensor protocol before any NFC streaming command is sent.
- Keeps the existing European Libre 2 pairing and decryption path unchanged.
- Blocks the European `A1/1E` enable-streaming command for the Brazilian variant.
- Reads all 43 NFC blocks sequentially, preventing a partial-FRAM race during pairing.
- Stores a versioned diagnostic containing the UID, patch info, sensor type, encrypted
  FRAM, timestamp, and whether a streaming command was attempted.
- Shows the detected Brazilian sensor explicitly in the setup screen and provides a
  Share action for the diagnostic JSON.
- Applies the LibreTransmitter change from the Trio repository itself, so the same
  source is used on a local Mac and in Xcode Cloud without requiring a second fork.

## Repository layout

The Trio repository continues to pin the official LibreTransmitter submodule commit.
The Brazilian changes are stored as `ci_scripts/libre_brasil.patch.b64`. Both Xcode
Cloud and local development decode and apply that patch with
`ci_scripts/apply_libre_brasil_patch.sh`.

Xcode Cloud automatically discovers `ci_scripts/ci_post_clone.sh` after cloning the
repository. For a local clone, run:

```sh
git clone --recurse-submodules --branch rodrigo-libre-brasil-dev \
  https://github.com/rodrigomarson/Trio.git
cd Trio
./scripts/apply_libre_brasil_patch.sh
open Trio.xcworkspace
```

The patch script is idempotent: running it again after a successful application is
safe.

## Local Mac validation

1. Select the shared `Trio` scheme and an iPhone destination in Xcode.
2. Confirm that signing resolves to team `6KLJLLTX3K` with automatic signing enabled.
3. Resolve Swift packages. The Swift-JWT dependency uses HTTPS in this branch.
4. Build the `Trio` scheme, then run the LibreTransmitter unit tests.
5. Archive once locally if signing or entitlement changes need to be diagnosed before
   starting an Xcode Cloud build.

The existing app identifier and entitlements are intentionally preserved so the
development build follows the same Apple Developer, HealthKit, NFC, Bluetooth,
Background Modes, Push Notifications, App Groups, and Keychain configuration already
used by Trio.

## Xcode Cloud and TestFlight

Use the existing Trio workflow with this branch as its source branch and the shared
`Trio` scheme. The post-clone script applies the LibreTransmitter patch before package
resolution and compilation. Configure the workflow to archive for iOS and deploy a
successful build to the intended internal TestFlight group.

The project version is `0.8.4.17` and its local build number starts at `17`. Xcode Cloud
must still use a build number that is higher than every build already uploaded for
the same app version. If App Store Connect reports a duplicate build number, set the
workflow's next build number above the current TestFlight maximum and rebuild.

## Sensor test procedure

Use a development sensor and do not make treatment decisions from this experimental
build.

1. Install the build from TestFlight.
2. In Trio, open CGM setup, select Libre, and choose the direct connection path.
3. Scan the Brazilian Libre 2 Plus with NFC.
4. Confirm that Trio reports **Libre 2 Plus Brazil** rather than **No Sensor Detected**.
5. Confirm that the screen states the European streaming command was not sent.
6. Share the diagnostic JSON and retain it with the app version and sensor model.

Expected Brazilian result: detection and diagnostic export, with no attempt to enable
European streaming. Expected European Libre 2 regression result: the existing direct
pairing path remains available.

## Next protocol stage

The next implementation stage begins only after the Brazilian diagnostic is reviewed.
It should add a separate Brazilian protocol adapter behind the existing capability
router, with fixtures and tests for patch parsing, NFC frame handling, streaming
activation, decryption, glucose extraction, and sensor-state transitions. The
European adapter should remain unchanged and covered by regression tests.

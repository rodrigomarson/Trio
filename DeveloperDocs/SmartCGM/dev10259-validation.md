# SMART integration candidate: official dev 1.0.2.59

## Pinned scope

This candidate is based on official Trio `dev` commit
`23bb3be3634e3d3f3fe2e9bcf525c3d4425b24ae` (dev 1.0.2.59). The validated
SMART integration was merged in the isolated
`candidate/rodrigo-smart-cgmkit-dev-1.0.2.59` worktree by commit
`dcbd10964`, then adapted to the LoopKit next-dev APIs by commit `1dc5e8683`.

All Xcode commands used `Trio.xcworkspace`. The previous dev 1.0.2.33
candidate and the installed production application were not modified. No
installation, push, pull request, Xcode Cloud action, or public distribution
was performed.

## Official compatibility work

The official delta removes the LoopAlgorithm submodule, moves device plugins to
LoopKit next-dev APIs, makes CGM deletion asynchronous, changes glucose values
and trend rates from `HKQuantity` to `LoopQuantity`, adds explicit instance
plugin identifiers, and requires explicit catalog identifiers for managed CGMs.

The SMART port therefore:

- raises SmartCGMKit's iOS deployment target from 16.0 to 17.6 to match Trio and
  LoopKit;
- preserves the static SMART identifier while exposing the new instance plugin
  identifier and dependency hook;
- exposes signal-loss and inoperable state through the new DeviceManager API;
- adopts async deletion and async alert acknowledgement;
- migrates delivered glucose, trend rate, display formatting, and backfill to
  `LoopQuantity`;
- confines onboarding and completion UI calls to the main actor; and
- supplies the SMART identifier explicitly to Trio's official CGM catalog.

The official suspended-pump behavior and Bool-returning enactment path are kept.
The persisted SMART automatic-insulin interlock still runs before determination
enactment and before SMB or temp-basal delivery. No pump driver, therapy setting,
or dosing algorithm was intentionally changed by this port.

## Libre 2 Plus Brazil preservation

Official dev 1.0.2.59 advances LibreTransmitter to `fb8e4ad`, which does not
identify the Brazilian Libre 2 Plus protocol variant. The safety patch was
reapplied on that official pin as local LibreTransmitter commit
`55b0d467066602f6231909274ad24b4e58fd9efc`.

The port retains the explicit `libre2BR` classification, validates patch data
before indexing it, and refuses the unsupported Brazilian direct connection
before sending the European enable-streaming command. It also retains bounded
pairing diagnostics and the user-facing safe fallback. The official simulator
pairing command helper and string-catalog version were preserved during the
conflict resolution.

The safety revision is published on the owner's LibreTransmitter fork as branch
`candidate/libre-brasil-trio-next-dev-10259`, and this Trio candidate points the
LibreTransmitter submodule at that reachable revision. It remains intentionally
separate from any upstream contribution until maintainers accept an equivalent
change.

## Validation performed on November 6, 2026

- SmartCGMKit Debug build for generic iOS device: succeeded.
- Trio Release build for generic iOS device: succeeded.
- SmartCGMKit test targets, build-for-testing: succeeded.
- Complete `Trio Tests` target graph, build-for-testing: succeeded.
- Required Xcode system components were installed and the CoreSimulator
  compatibility failure was cleared.
- SmartCGMKit execution: 55 tests in 3 suites passed.
- Focused device-catalog execution: 15 tests in 1 suite passed after adding the
  SMART manager to the catalog test's persisted-identifier inventory.
- Complete serialized `Trio Tests` execution: 1,001 tests in 131 suites passed.
- Restored Trio's prior Xcode Cloud version-consistency fix after the current
  project file had regressed Live Activity and Watch targets to hard-coded
  version/build values. All application targets now inherit `APP_VERSION` and
  `APP_BUILD_NUMBER`; the complete 1,001-test suite passed again after the fix.
- Unsigned arm64 Release archive: succeeded at
  `/tmp/TrioSmartDev10259-20261106.xcarchive`.
- Archive application version: 1.0.2; build number: 1.
- Signed distribution candidate: version 1.0.2, build 24. The app, Live Activity
  extension, watch app, and watch complication all carry build 24; deep signature
  validation passed; all four embedded provisioning profiles are current; the
  application group, HealthKit, and push-notification entitlements are present;
  and SmartCGMKit, SmartCGMKitUI, LibreTransmitter, and LibreTransmitterUI are
  embedded.
- `git diff --check`: passed.

The first complete test execution exposed one test-inventory omission:
`DeviceCatalogTests` did not include `SmartCGMManager` in its expected plugin
identifier table even though the SMART catalog entry and its dedicated test were
correct. The test inventory now uses `SmartCGMManager.pluginIdentifier`; focused
and complete reruns pass. No production runtime, pump, therapy, or algorithm
code changed in this correction.

Cloud preflight also found that the current project file had lost the earlier
Trio fix that keeps the iOS app, Live Activity extension, watch app, watch
complication, and watch tests on the same marketing version and build number.
The known project-level correction was restored. This prevents App Store Connect
version-mismatch rejection and ensures a TestFlight install updates one coherent
Trio application family.

The LibreTransmitter revision and Trio candidate are reachable from the owner's
forks, and a clean recursive clone resolved packages and completed a generic
device Release build. Xcode 27.2 confirms that the Apple account is signed in,
the Trio product is available, and the enabled `Trio Manual Build` workflow is
still present. Xcode Cloud nevertheless refuses access until the Account Holder
reviews Apple's updated Developer Program License Agreement. A second local App
Store Connect export attempt failed at the same account-access gate before any
binary was uploaded. No cloud build, TestFlight upload, or device installation
occurred.

Thread Sanitizer was disabled only through the generic-device build command
because it is unsupported for generic iOS/watchOS archive targets; no project
setting was changed for that workaround.

## Remaining gates

Before cloud distribution, the Account Holder must review Apple's updated
Developer Program License Agreement. After Apple restores account access, point
the existing reviewed `Trio Manual Build` workflow at the published candidate
branch and verify that build 24 reaches TestFlight. Installation must be an
in-place TestFlight update of the existing Trio application identity, followed
by production-state and runtime checks; no parallel application identity is
permitted.

Automated compilation and archive evidence do not prove runtime restoration,
physical SMART activation, warmup, replacement, handover, notification
delivery, longitudinal background BLE reliability, pump connectivity, loop
completion, clinical readiness, or maintainer acceptance.

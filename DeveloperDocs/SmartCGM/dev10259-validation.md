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

This local submodule revision is not published upstream. A fresh external clone
cannot reproduce it until an accepted or otherwise reachable revision replaces
the local-only pin. That remains a publication blocker, not a local build
failure.

## Validation performed on November 6, 2026

- SmartCGMKit Debug build for generic iOS device: succeeded.
- Trio Release build for generic iOS device: succeeded.
- SmartCGMKit test targets, build-for-testing: succeeded.
- Complete `Trio Tests` target graph, build-for-testing: succeeded.
- Unsigned arm64 Release archive: succeeded at
  `/tmp/TrioSmartDev10259-20261106.xcarchive`.
- Archive application version: 1.0.2; build number: 1.
- `git diff --check`: passed.

The current Xcode reports that the installed CoreSimulator framework is older
than the version required by this Xcode. Simulator devices are therefore
disabled. The test targets compiled, but tests were not executed in this
checkpoint. Thread Sanitizer was disabled only through the generic-device build
command because it is unsupported for generic iOS/watchOS archive targets; no
project setting was changed for that workaround.

## Remaining gates

Before installation, restore an executable test destination and run the focused
SMART suites plus the complete serialized Trio suite. Then review archive
signing, entitlements, bundle/app-group identity, and production-state backup
and integrity evidence. Installation requires separate explicit authorization.

Automated compilation and archive evidence do not prove runtime restoration,
physical SMART activation, warmup, replacement, handover, notification
delivery, longitudinal background BLE reliability, pump connectivity, loop
completion, clinical readiness, or maintainer acceptance.

# SMART integration evolution ledger

This ledger is mandatory input for every Trio x SMART/MicroTech/LinX task,
regardless of chat, branch, worktree, production candidate, or upstream pull
request. It prevents a migration from treating an older checkout as the latest
validated implementation.

## Required workflow

1. Fetch and pin the requested official Trio `dev` commit.
2. Reconstruct every later SMART commit, build, test, physical observation, and
   incident report before changing code or claiming that a capability is absent.
3. Compare the candidate against this ledger and the latest validated production
   implementation. Preserve every item below unless its replacement is explicit,
   documented, and supported by equal or stronger evidence.
4. Use `Trio.xcworkspace` for every Xcode command. Never use `Trio.xcodeproj`.
5. Keep the production and upstream-collaboration lines synchronized through
   reviewable ports. Neither line may silently lose features from the other.
6. Record the official base, commits, validation evidence, remaining physical
   gates, and production/publication boundary in English after every evolution.

## Preservation checklist

- Passive one-minute BLE advertisements and `providesBLEHeartbeat = false`.
- Timer fallback, restoration, reconnect, foreground, and background policies.
- Safe activation: inspect/adopt an active sensor; start only a stopped sensor;
  confirm the resulting session before displaying warmup.
- Parallel replacement: keep the outgoing sensor and its history active while
  the new SMART warms; hand over only after reliable confirmation.
- Visible activation, warmup, remaining-time, signal, validation, handover,
  expiry, and replacement states without misleading instructions.
- Replacement reminders at 24 hours, 120 minutes, and 65 minutes, including
  restoration reconciliation and non-destructive notification cleanup.
- Bounded advertisement history and manual long backfill.
- One-time calibration ownership and the host calibration persistence pipeline.
- Reading cadence, optional regularization, trend calculation, and source/date
  identity through storage and export.
- Persisted automatic-insulin interlock before enactment and SMB, including
  divergence hold, reacquisition, restart restoration, and minimum reliable
  deliveries before release.
- No pump-driver, therapeutic-setting, or LoopAlgorithm changes as an incidental
  consequence of a SMART migration.
- Production bundle identity and application data preserved by an in-place
  installation, preceded by container backup and SQLite integrity verification.

## Validated continuation point

### Official Trio dev 1.0.2.4 — October 11, 2026

- Official base: `1bacd86fb19dc325dff044b8cfe52fb7da6c8b98`.
- SMART port: `a138faf898ef7b60a4bb2eb26fe87785930892d8`.
- Warmup/status/diagnostics improvements: `45db7bdda`.
- Mandatory continuity ledger: `40d49355d`.
- SmartCGMKit: 55 tests passed.
- Focused Trio host integration and sensor-state log: 12 tests passed.
- Complete Trio suite: 810 tests in 112 suites passed.
- Unsigned arm64 Release archive passed.
- Official LoopAlgorithm, LoopKit, MedtrumKit, LibreLoop, LibreTransmitter, and
  RoundWhiteDiscKit pins were retained.
- Signed build 22 was installed in place on the production iPhone after explicit
  authorization. The app bundle and app group identities were preserved.
- Pre-install and post-install app-container copies passed SQLite integrity and
  persisted-state validation. The installation retained the existing application
  database identity.
- The post-install runtime produced a fresh SMART reading, delivered it through
  Trio, kept the pump connection healthy, and completed a loop successfully.

This point adds correct parallel-warmup precedence, active/pending/stopped
session validity, stale-communication rejection, and integration with Trio's
generic CGM sensor-state log. A reliable outgoing SMART remains the current CGM
observation during parallel warmup.

### Official Trio dev 1.0.2.59 candidate — November 6, 2026

- Official base: `23bb3be3634e3d3f3fe2e9bcf525c3d4425b24ae`.
- SMART merge: `dcbd10964`.
- LoopKit next-dev compatibility: `1dc5e8683`.
- LibreTransmitter Brazil safety port: `55b0d467066602f6231909274ad24b4e58fd9efc`
  on official LibreTransmitter `fb8e4ad`.
- SmartCGMKit generic-device build: passed.
- Complete Trio generic-device Release build: passed.
- SmartCGMKit and complete Trio test target graphs: build-for-testing passed.
- Xcode system components were installed and CoreSimulator execution was
  restored.
- SmartCGMKit: 55 tests in 3 suites passed.
- Device catalog: 15 focused tests passed after adding the SMART manager to the
  test inventory.
- Complete serialized Trio suite: 1,001 tests in 131 suites passed.
- Restored the prior Trio Xcode Cloud fix that makes the Live Activity and Watch
  targets inherit the app version/build instead of hard-coded `1.0 (1)` values;
  the complete 1,001-test suite passed again.
- Unsigned arm64 Release archive: passed.
- Signed version 1.0.2 build 24 archive: passed deep-signature, provisioning,
  entitlement, embedded-framework, and aligned app/extension build-number
  checks.
- Historical Xcode Cloud state confirms the Trio product, enabled `Trio Manual
  Build` workflow, and two successful July 2026 cloud builds. The Apple account
  is signed in, but Apple blocks both Xcode Cloud access and local App Store
  Connect export until the Account Holder reviews the updated Developer Program
  License Agreement. Both attempts stopped before upload.
- The LibreTransmitter pin and Trio candidate are published on the owner's
  forks. A clean recursive clone resolved packages and completed a generic
  device Release build. No cloud build, TestFlight upload, installation, pull
  request, or public distribution occurred.

This candidate preserves SMART activation, warmup, replacement, restoration,
reminders, calibration ownership, bounded history, divergence protection, and
the persisted automatic-insulin interlock while adopting LoopKit's async device
deletion, instance plugin identity, `LoopQuantity`, and DeviceManager status
surface. It also preserves the explicit safe refusal for Libre 2 Plus Brazil.
The local LibreTransmitter revision remains a fresh-clone/publication blocker.
See [`dev10259-validation.md`](dev10259-validation.md) for the full boundary.

## Evidence boundaries

Automated tests, builds, archives, and simulator launches do not prove physical
notification presentation, longitudinal iOS background BLE reliability,
complete sensor replacement, natural divergence/reacquisition, Nightscout note
delivery, clinical readiness, human provenance approval, or maintainer
acceptance. Those gates must remain explicit.

App-container backups do not include Keychain or HealthKit data. The build 22
production installation was separately authorized and completed; any later
installation, push, PR creation, Xcode Cloud activity, or public distribution
remains a separately authorized action.

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

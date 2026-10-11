# SMART integration candidate: official dev 1.0.2.4

## Pinned scope

This candidate is based on the official `nightscout/Trio` `dev` commit
`1bacd86fb19dc325dff044b8cfe52fb7da6c8b98` (dev 1.0.2.4). The validated
SMART integration was reapplied in an isolated worktree and recorded as local
commit `a138faf898ef7b60a4bb2eb26fe87785930892d8`. The production checkout and
installed application were initially left unchanged while the candidate was
validated. After explicit authorization, signed build 22 was installed in place
on the production iPhone; the outcome is recorded in
[`dev1024-installation.md`](dev1024-installation.md).

All Xcode commands use `Trio.xcworkspace`. The official 1.0.2.4 submodule pins,
including LoopAlgorithm, LoopKit, MedtrumKit, LibreLoop, LibreTransmitter, and
RoundWhiteDiscKit, are unchanged. This candidate does not add Libre 2 Plus
Brazil support and does not change pump drivers, therapeutic settings, or the
dosing algorithm.

## Changes added after the 1.0.2.4 port

- A pending SMART replacement now takes visual precedence over the stopped or
  stale outgoing sensor. The main screen and SMART settings screen consistently
  show the confirmed parallel warmup and its remaining time.
- The settings screen suppresses the obsolete activation prompt while the new
  sensor is already warming and explains that Trio will switch only after
  reliable readings.
- `CGMManagerStatus` now distinguishes an active session, a pending replacement,
  and a stopped sensor instead of always claiming that the session is valid.
  Its communication date is the newest observation from either relevant sensor.
- SmartCGMKit exposes a host-neutral sensor observation. Trio maps it into the
  official `CGMSensorStateLog`, including activation, warmup, signal loss,
  replacement confirmation, and handover/reacquisition states. The existing
  Nightscout upload preference remains authoritative and disabled by default.
- During parallel warmup, a reliable outgoing SMART reading remains the current
  CGM observation. Expected replacement warmup therefore cannot incorrectly
  mark the active glucose source as unreliable.
- The existing automated coverage for the 24-hour, 120-minute, and 65-minute
  replacement reminders remains in the SmartCGMKit test suite.

## Preserved safety behavior

The port preserves passive BLE delivery (`providesBLEHeartbeat = false`), the
timer fallback, one-time calibration ownership, bounded history/backfill,
restart restoration, two-reading handover confirmation, divergence hold and
reacquisition, and the persisted automatic-insulin interlock before enactment
and SMB. A pending sensor cannot replace the active source until reliable
handover criteria are met.

## Automated validation

Validation was performed on October 11, 2026 with serialized execution and
fresh Derived Data directories:

- SmartCGMKit: 55 tests in 3 suites passed.
- Focused Trio host integration and CGM state log: 12 tests in 2 suites passed.
- Complete `Trio Tests` scheme: 810 tests in 112 suites passed.
- Unsigned Release archive: succeeded for arm64 iOS at
  `/tmp/TrioSmartDev1024-20261011.xcarchive`.
- `git diff --check`: passed.

The archive retains the official development version values: short version
1.0.2, development version 1.0.2.4, and build number 1. It is a compile artifact,
not a signed installation candidate.

A separate signed Release archive and exported IPA were then produced from
commit `40d49355d` with build number 22. Code signing, entitlement, bundle and app
group identity, pre-install backup, database integrity, in-place installation,
post-install state restoration, a fresh SMART reading, and a completed Trio loop
all passed. These production checks do not replace the automated validation
above.

## Remaining gates

The explicitly authorized production installation was performed. No push, pull
request, Xcode Cloud action, or public distribution was performed.

Automated tests and an archive do not prove real notification presentation,
longitudinal background BLE recovery, a complete future physical parallel
replacement, natural divergence/reacquisition, notification delivery,
Nightscout note delivery, clinical readiness, or maintainer acceptance. Those
gates remain separate and must be reported as such before publication.

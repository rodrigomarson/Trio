# Private SMART production candidate: dev 1.0.1.9 / build 21

## Pinned scope

Official `nightscout/Trio` dev was fetched on October 5, 2026. Base: `cf4754b4a`, following version bump `4066afd71`. The production baseline is installed dev 1.0.1.8/build20, binary commit `40f0d75b560aa3fd211a2148ebead764f380bfb3`. An isolated worktree reapplies that validated production delta onto the official base. This is a private production candidate, not the upstream contribution branch.

The official delta includes PR1472 (manual glucose/calibration representation), PR1420 (optional Nightscout sensor-state notes), PR1434 (treatment entry and keyboard scrolling), and PR1571 (override list identity and finite-value guards). The sensor-state upload setting defaults to false; the official observer supports G6/G7 and returns unavailable for SMART. No claim of new SMART state uploads is made.

SmartCGMKit sources, UI, tests and policies are byte-identical to installed build20. No source was taken from Hristos/LinxCGMKit-Trio. The sole merge conflict was an official documentation comment on the Nightscout upload result; the comment and official Bool-returning API were preserved. The full SMART history reconstruction and notification incident evidence remain in the previous worktree's `DeveloperDocs/SmartCGM/dev1018-audit.md` and `dev1018-installation.md`, and the private audit directory.

## Preservation acceptance

Activation/adoption policy, warmup, old sensor as the active source during parallel replacement, reliable automatic handover, restart restoration, 24h/120min/65min reminders and completion, divergence hold/reacquisition, physical protocol validation, calibration ownership, bounded backfill and BLE reconnect policies are retained. The build20 reminder repair (snooze preservation, foreground/fetch reconciliation, session anchor validation, accepted-request verification and visible status) is retained without changes.

The installed timer fallback and `providesBLEHeartbeat = false` are preserved. Automatic-insulin interlocks before enactment/SMB are unchanged. No pump-driver or LoopAlgorithm delta exists against the official base, and those submodule pins are unchanged from installed build20. No therapeutic settings, pump operations or dosing behavior were deliberately changed. The upstream glucose classification change is exercised with a storage/export round-trip regression test: sensor glucose remains sgv, manual glucose remains mbg and isManual, with original dates preserved.

## Validation and installation boundary

Tests and Release verification are in progress. Evidence is stored outside the repository at `/Users/rodrigomarson/Development/Trio_Smart_Audits/2026-10-05-dev1019-build21`. Installation is not yet performed. The original task requires final specific installation confirmation after review of the candidate and tests. Prior approval and installation concerned build20. Build20 remains available for rollback together with its backups. A fresh backup and integrity check must precede any approved in-place build21 installation.

Existing open physical gates remain: notification delivery, background operation and Bluetooth recovery over time, full parallel replacement/handover, natural divergence/reacquisition, and resource-write observation. Automated tests and an archive do not close these gates. The historical diagnostic-write resource issue is not claimed fixed.

# SMART 2.0 Trio production-candidate test plan

## Scope

This plan validates the selectable SMART MedLevensohn 2.0 integration on an
iPhone before it is promoted to treatment use. The integration uses direct
Bluetooth; it does not require the official app, Android, Nightscout, or a
relay.

## Build gates

Run these gates on a Mac or the repository's macOS build workflow:

```sh
cd MicroTechCGMKit
swift test
cd ..
xcodebuild \
  -workspace Trio.xcworkspace \
  -scheme Trio \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Expected results:

- 59 MicroTechCGMKit XCTest cases pass;
- the Trio Release target resolves the local `MicroTechCGMKit` package;
- `SmartCGMManager.swift` compiles in the Trio application target;
- no source-format or project-file validation errors occur.

The signed repository workflow may then archive the app and upload the selected
branch to TestFlight. Do not trigger that workflow until the branch has been
reviewed and intentionally published.

## iPhone setup

1. Install the candidate build on an iPhone running iOS 17 or later.
2. Keep the official SMART app closed so only one central attempts to connect.
3. In Trio, open CGM settings and select **SMART MedLevensohn 2.0**.
4. Enter the exact 10-character sensor serial printed on the sensor or package.
5. Leave Trio open for the first pairing.
6. Open the SMART settings screen and confirm that the state progresses through
   searching, authenticating, and **Receiving live glucose**.

The master pairing key must not appear in logs, settings, raw manager state, or
screenshots. Only the masked serial may be used in diagnostic logs.

## Physical acceptance gates

Record timestamps and results for each gate:

| Gate | Pass condition |
|---|---|
| Discovery | Trio finds the expected `Smart-<serial>` peripheral and service `181F`. |
| Authentication | Key exchange and session-key validation complete without a protocol or checksum error. |
| Live reading | A valid F003 packet creates a Trio glucose reading within six minutes. |
| Plausibility | At least three consecutive Trio readings match the official app or meter closely enough for investigation; discrepancies are documented. |
| Deduplication | No duplicate glucose rows appear for the same sensor minute. |
| Relaunch | Force-quitting and reopening Trio restores the configured manager and reconnects. |
| Background | With the phone locked for at least 20 minutes, readings resume without re-entering the serial. |
| Bluetooth cycle | Turning Bluetooth off and on produces a warning, retry, and eventual recovery. |
| Sensor removal | Removing SMART stops scanning and deletes the stored pairing credential. |

## Stop conditions

Stop the test and preserve the Trio device log if any of these occur:

- the advertised local name or required characteristics differ from the
  modeled protocol;
- authentication repeats continuously or the sensor becomes unavailable to the
  official app;
- decoded glucose is implausible, changes discontinuously, or differs
  materially from the comparison source;
- duplicate or stale readings enter Trio;
- Trio crashes, blocks another CGM from reconnecting, or cannot remove the
  manager cleanly.

Until every physical gate passes, keep closed-loop dosing disabled for this CGM
and treat the build as a production candidate rather than validated production
support.

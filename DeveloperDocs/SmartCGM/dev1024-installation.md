# SMART dev 1.0.2.4 production installation

## Scope and authorization

On October 11, 2026, the user explicitly authorized installation of the
validated Trio dev 1.0.2.4 SMART candidate on the production iPhone. The
installation was performed in place. It did not authorize a push, pull request,
Xcode Cloud action, public distribution, pump-driver change, therapeutic-setting
change, or dosing-algorithm change.

Every Xcode operation used `Trio.xcworkspace`.

## Installed artifact

- Official Trio base: `1bacd86fb19dc325dff044b8cfe52fb7da6c8b98`.
- Candidate commit at build time: `40d49355d`.
- User-facing version: 1.0.2.
- Development version: 1.0.2.4.
- Build number: 22.
- Bundle identifier: `org.nightscout.6KLJLLTX3K.trio`.
- Signed archive:
  `/Users/rodrigomarson/Development/Trio_Production_Builds/Trio-1.0.2.4-22-SmartCGMKit-candidate.xcarchive`.
- Exported IPA:
  `/Users/rodrigomarson/Development/Trio_Production_Builds/Trio-1.0.2.4-22-SmartCGMKit-iPhone/Trio.ipa`.
- IPA SHA-256:
  `c59cb4005f8e4972e937eb4273fbffebb5f45452903391c171a84bf1c0b5f0b6`.

The signed archive and exported application retained the production team,
bundle identifier, app group, HealthKit entitlements, and development push
environment. Code-signature verification passed.

## Pre-install protection

The installed version before this update was Trio 1.0.1 build 21. Two app-data
copies were retained, including a final copy immediately before installation:

- `/Users/rodrigomarson/Development/Trio_Smart_Audits/2026-10-11-dev1024-production-update/app-data`
- `/Users/rodrigomarson/Development/Trio_Smart_Audits/2026-10-11-dev1024-production-update/preinstall-final-app-data`

The main SQLite database returned `ok` from `PRAGMA integrity_check` and the
persisted CGM and pump manager property lists passed structural validation.
App-container backups do not include Keychain or HealthKit data; that limitation
must not be represented as a full-device backup.

## Installation outcome

The signed build was installed successfully over the existing application. The
bundle and app group identifiers stayed unchanged, and the device reported the
same application database identity after installation. A post-install container
copy was retained at:

`/Users/rodrigomarson/Development/Trio_Smart_Audits/2026-10-11-dev1024-production-update/postinstall-app-data`

The post-install database again passed `PRAGMA integrity_check`. The CGM and
pump manager property lists remained valid, and the restored CGM manager was
`SmartCGMManager`.

## Immediate runtime evidence

The application launched as dev 1.0.2.4 build 22 from commit `40d4935`.
Immediately after launch, Trio reported a valid SMART sensor session. During the
observation window:

- recurring pump heartbeats reported a healthy connection;
- a fresh SMART glucose sample entered the Trio CGM pipeline;
- Trio recognized and stored the new glucose;
- a normal determination was generated; and
- the loop completed successfully.

No new error, fatal-error, crash, or assertion-failure entry appeared after the
build 22 launch in the captured observation window. Older communication errors
present earlier in the same historical log predate this launch and are not
attributed to build 22.

The official Smart application was not opened for this check, and the sensor
serial is intentionally omitted from this record.

## Evidence and remaining gates

Build, export, installation, and runtime evidence is retained under:

`/Users/rodrigomarson/Development/Trio_Smart_Audits/2026-10-11-dev1024-production-update`

This immediate end-to-end gate passed. Longitudinal background BLE operation,
real notification presentation, the next complete physical parallel
replacement, natural divergence/reacquisition, and long-duration reliability
still require observation. No push, pull request, Xcode Cloud action, or public
distribution was performed.

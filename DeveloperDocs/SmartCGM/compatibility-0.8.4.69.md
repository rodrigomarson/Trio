# Smart CGM compatibility with Trio 0.8.4.69

## Scope

This branch is based on the official Trio `dev` commit `68b3b9ef2` (`APP_DEV_VERSION = 0.8.4.69`). It preserves the
separate Trio Test application identity and carries the Smart / LinX work forward without changing the production Trio
application or its data container.

This document is a migration audit, not a declaration of medical or production readiness. Release compilation and a
controlled sensor-device validation remain required before the branch can be considered a release candidate.

## Compatibility decisions

### Retained and adapted

| Area | Decision | Reason |
| --- | --- | --- |
| Smart advertisement parser and deduplication | Retain | Isolated protocol code with captured-payload and checksum tests. |
| Smart BLE scanner and active GATT operations | Retain | Required for direct readings, activation and bounded history retrieval. The restoration identifier now follows the app bundle identifier so Trio and Trio Test do not share a literal identifier. |
| Smart CGM plug-in registration | Adapt to 0.8.4.69 | Uses the current `CGMType`, `PluginSource`, `PluginManager` and direct glucose-delivery path. |
| One-minute Smart input with Trio persistence cadence | Retain | Smart provides the heartbeat; the legacy polling timer is suspended only for this active Smart manager. Other CGM sources keep the official timer behavior. |
| Calibration persistence | Retain with identity guard | State refreshes from the same manager no longer erase calibrations. A physical sensor or manager replacement still clears them. |
| Smoothing and regularization | Retain | Sensor-specific processing remains upstream of the official storage and algorithm pipeline, with bypasses for rapid changes and low glucose. |
| Activation, warm-up, backfill and parallel handover | Retain | These are Smart-specific lifecycle functions and do not replace official Libre 2+ support. |
| Automatic-insulin handover interlock | Retain | The hold is temporary, releases under the documented time/confirmation policy and then requires three recent readings from the new sensor. |
| Replacement notifications | Retain | Smart-specific 24-hour, 120-minute, 65-minute and successful-handover notifications. |
| Live Activity current-glucose updates | Retain as a separate change | Uses current CGM sample time, bounds the six-hour chart payload, coalesces equivalent updates and reconciles ActivityKit state on foreground entry. |
| Diagnostic log handle reuse | Retain as a separate battery change | Avoids reopening and inspecting the file for every log line. Access to the cached handle and formatter is serialized. |
| Treatment-download timer suspension | Retain as a separate battery change | The timer is stopped when Nightscout downloads are disabled and resumes without changing the enabled path. |
| OpenAPS file fallback | Adapt to 0.8.4.69 | Keep the missing-file fast path, but replace the old high-priority global queue and synchronous read with the current asynchronous `FileStorage` API. |
| Nightscout glucose date query | Retain as a separate correctness change | Uses the numeric `date` field in milliseconds instead of an ISO `dateString` comparison. |
| Nightscout CGM-state upload ledger | Retain as a separate correctness change | Marks state as uploaded only after a successful upload and bounds the local ledger. |

User-visible Smart errors, UIKit labels, status text and local-notification content are routed through Trio's localization
API. The upstream PR still needs reviewed translations for Trio's supported languages; the private Portuguese wording is
not a reason to keep a second, non-localizable UI path.

### Already solved or replaced by 0.8.4.68/69

The following changes from the earlier private branch must not be reintroduced:

| Earlier private change | 0.8.4.69 replacement | Decision |
| --- | --- | --- |
| Custom HealthKit upload coordinator | Current HealthKit setup controllers and Core Data publishers | Discard old coordinator. |
| Custom Tidepool glucose upload coordinator | `TidepoolUploadSerializer` and the current upload flow | Discard old coordinator. |
| Nightscout device-status debounce/subscriber workaround | `NightscoutUploadSerializer` and the current upload pipelines | Discard old subscriber workaround. |
| Home-screen hook used to trigger legacy uploads | Current storage publishers and service-specific pipelines | Discard old hook. |
| Live Activity expired placeholder recreation | Activity creation with real glucose content plus ActivityKit reconciliation | Discard placeholder path. |
| Old CGM selection assumptions | Official 0.8.4.69 CGM model list, including Libre 2+ | Keep the official list and add Smart through current plug-in registration only. |

The discard decisions are backed by the official history, rather than by file-name similarity alone. In particular,
`6ce76424d` replaced service-level Core Data publishers, `52787dfa8` introduced `TidepoolUploadSerializer`, `e8055bbfb`
repaired the Tidepool upload lifecycle and `977e9b6af` serialized Nightscout upload pipelines. The Libre integration also
changed its delivery policy in `ceae78b2e`. Reapplying the older private coordinators on top of those commits would create
two owners for the same background work and could increase both duplicate uploads and battery consumption.

The legacy Live Activity `isInitialState` placeholder has also been removed from the compatibility branch. New activities
are requested only with real glucose content, so retaining an unreachable expired-placeholder rendering path offered no
fallback and preserved the exact defective screen reported during device testing.

### Private test-app infrastructure

These changes are necessary for the separately installable Trio Test build but must not be included in an upstream Smart
feature pull request:

- personal developer team, bundle identifiers, app group and URL scheme;
- alternate Trio Test display name and icon;
- TestFlight build numbers and Xcode Cloud scripts;
- signing/provisioning changes;
- dependency lockfile changes that are not required by Smart source code;
- Apple Watch embedding validation added specifically for the private distribution workflow.

The `Smart2Sensor` image also stays outside an upstream pull request until its redistribution rights are documented.

## Live Activity review

The 0.8.4.69 code receives several related Core Data updates for a single loop. The compatibility branch coalesces those
updates for 12 seconds, avoids sending identical content repeatedly and renders at most 120 points sampled over the full
six-hour window. The newest two readings are always preserved.

The previous implementation could reach its seven-hour recreation threshold while Trio was backgrounded, decline both
an update and a replacement, and leave the Lock Screen unchanged until the app was opened. The updated policy continues to
update an existing ActivityKit session in the background and recreates it when the app is active. A foreground transition
forces reconciliation even when the glucose payload is unchanged, which also repairs an ActivityKit-ended session.

ActivityKit still controls the system lifetime of an activity. A local app cannot guarantee indefinite replacement while
suspended, so device validation must include a period longer than eight hours and a foreground reopen.

## Battery review

The retained changes reduce work without changing the clinical cadence:

- Smart advertisements remain the glucose heartbeat, so no second one-minute polling cycle runs for Smart;
- polling remains enabled for all CGM sources that require it;
- history/activation GATT connections are bounded and disconnected after the operation;
- the Live Activity chart fetch is capped at 360 source points and 120 rendered points;
- equivalent ActivityKit updates are coalesced;
- diagnostic logging reuses one locked file handle per day;
- Nightscout treatment polling is stopped when downloads are disabled;
- OpenAPS fallback reads use the current asynchronous storage API instead of wrapping synchronous I/O on a high-priority global queue;
- utility queues are used for background fetch work.

No further custom upload coordinators are justified on 0.8.4.69. Optimizations to HealthKit, Nightscout or Tidepool should
be made inside the official serializer/publisher architecture and measured independently.

## Remaining validation gates

Completed locally on this branch:

- targeted parser, calibration, smoothing, storage and Live Activity policy tests;
- the complete Trio test suite, run serially with the simulator keychain available: 629 passed, 4 skipped and 0 failed;
- unsigned Release compilation of the iPhone application and its packaged Live Activity and Watch extensions.

Remaining device gates:

1. Controlled Trio Test validation with the official Smart app fully closed.
2. Direct-reading continuity, background recovery, backfill and calibration checks.
3. Sensor replacement validation, including temporary insulin hold and three-reading reacquisition.
4. Live Activity validation across the ActivityKit lifetime boundary.
5. Battery comparison on the same device and workload.

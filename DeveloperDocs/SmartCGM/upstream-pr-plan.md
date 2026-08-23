# Smart CGM upstream pull request plan

The private compatibility branch contains several independent changes. They should not be submitted as one pull request.
Small, dependency-ordered pull requests make review, rollback and clinical validation safer.

## PR 1 - Smart advertisement protocol core

Include:

- advertisement parsing, checksums and deduplication;
- captured-payload unit tests;
- protocol documentation for the tested Smart / LinX model.

Exclude active GATT, UI, insulin decisions, personal assets and signing. This PR is pure protocol/data handling.

## PR 2 - Smart direct CGM plug-in

Depends on PR 1. Include:

- scanner and plug-in registration through the 0.8.4.69 interfaces;
- direct glucose delivery and restoration behavior;
- Smart-only timer suppression and manager-identity calibration guard;
- connection-state and heartbeat tests.

User-visible runtime text is now routed through Trio's localization API. Before submission, add and review translations
for Trio's supported languages and document the BLE privacy/restoration model.

## PR 3 - Smart processing and calibration

Depends on PR 2. Include:

- smoothing/regularization policy and tests;
- calibration input validation, persistence and sensor-change reset;
- Smart calibration UI using the existing Trio components.

Keep any sensor-agnostic storage policy in its own PR. Do not bundle a global algorithm behavior change with Smart support.

## PR 4 - Smart lifecycle and replacement safety

Depends on PR 2. Include:

- bounded GATT activation and history retrieval;
- warm-up and parallel old/new sensor handover;
- replacement notifications;
- temporary automatic-insulin interlock and deterministic release/reacquisition policy;
- lifecycle, failure-path and state-restoration tests.

This is the highest-risk PR. It needs protocol evidence, real-device traces with secrets removed, explicit failure states and
a reviewer-visible explanation of every condition that blocks or releases automatic insulin.

## Independent PR - Live Activity reliability and efficiency

No Smart dependency. Include:

- bounded six-hour chart sampling;
- update coalescing/deduplication;
- current-CGM timestamp semantics;
- background update/foreground recreation policy;
- ActivityKit reconciliation and policy tests.

## Independent PR - Background battery efficiency

No Smart lifecycle dependency. Include separately measurable changes:

- utility queue/timer placement;
- treatment timer suspension while Nightscout downloads are disabled;
- OpenAPS fallback reads through the existing asynchronous storage API;
- locked daily log-file handle reuse.

Do not include the obsolete custom HealthKit, Tidepool or Nightscout coordinators. The 0.8.4.69 serializers/publishers already
own those responsibilities.

## Independent PR - Nightscout correctness

No Smart dependency. Include:

- numeric `find[date][$gte]` query construction and tests;
- success-only CGM-state upload ledger and retention tests.

## Upstream exclusions

- `Config.xcconfig` personal values;
- private bundle identifiers/app groups;
- Trio Test name/icon;
- TestFlight/Xcode Cloud workflow and build numbering;
- redistribution-unverified sensor artwork;
- unrelated dependency lockfile changes;
- production-device history or logs.

No upstream branch should be pushed and no pull request should be opened until the owner explicitly approves the exact
commit range and proposed PR text.

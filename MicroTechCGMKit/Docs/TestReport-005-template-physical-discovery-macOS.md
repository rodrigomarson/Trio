# MicroTechCGMKit test report 005 — template

Date: `<YYYY-MM-DD>`

Feature branch: `feature/microtech-smart2-cgm`

Validated source checkpoint: `ac3720b`

Archive SHA-256: `5246cdeadcb1a057ca1f6561d2ad07d4be8c67973a3d956e9f1bb18a509a70b8`

Test host: `<Apple Silicon model class; do not include device serial>`

macOS version: `<version>`

Sensor product and model: `<non-sensitive label text>`

Sensor state: `<unopened | normally activated/warming up | normally active>`

## Result

Status: **`<A METADATA COMPLETED | B UNEXPECTED METADATA | C TIMEOUT | D TYPED FAILURE | E SAFETY STOP>`**

One-sentence outcome: `<concise result without identifiers or glucose data>`

## Package and manual evidence

- manufacturer/product: `<value>`
- model or hardware revision: `<value or not stated>`
- stated application and version: `<value or not stated>`
- regulatory registration: `<non-sensitive value or not stated>`
- documented activation sequence: `<short summary>`
- documented Bluetooth/pairing behavior: `<short summary or not stated>`
- redacted image set reviewed: `<yes/no>`

Never include the sensor serial, UDI, barcode, QR code, lot, order information, or patient information in this report.

## Source and build identity

- archive hash matched: `<yes/no>`
- every source-manifest entry reported `OK`: `<yes/no>`
- XCTest result: `<58 passed / other>`
- release app bundle built: `<yes/no>`
- property list passed validation: `<yes/no>`
- ad-hoc signature verified: `<yes/no>`

## Safety preconditions

- sensor followed its normal manufacturer-defined workflow: `<yes/no/not applicable>`
- sensor was not activated solely for research: `<yes/no>`
- official application was closed only for the bounded attempt: `<yes/no/not applicable>`
- no pairing, PIN, or bonding request was accepted: `<yes/no>`
- only one probe attempt was made: `<yes/no>`
- official application resumed its normal connection afterward: `<yes/no/not assessed>`

## Redacted discovery evidence

Report SHA-256: `<hash or not produced>`

Terminal outcome category: `<saved report or typed failure category>`

| Observation | Current assumption | Observed result |
|---|---|---|
| Local-name family | `Smart-` with redacted suffix | `<redacted result>` |
| Advertised protocol service | `181F` | `<UUIDs or not observed>` |
| Discovered protocol service | `181F` | `<UUIDs or not observed>` |
| Key-exchange characteristic | `F001` | `<UUID and properties or not observed>` |
| Command characteristic | `F002` | `<UUID and properties or not observed>` |
| Live-glucose characteristic | `F003` | `<UUID and properties or not observed>` |
| Additional services/characteristics | none assumed | `<redacted metadata or none>` |

Do not infer characteristic purpose from UUID or properties alone. Mark any mismatch as an observation requiring later analysis.

## Privacy review

- local name was redacted: `<yes/no>`
- peripheral identifier was redacted: `<yes/no>`
- no manufacturer/service payload was present: `<yes/no>`
- no characteristic value, key, serial, UDI, or glucose appeared: `<yes/no>`
- evidence is safe to retain in the repository: `<yes/no>`

If any answer is `no`, do not attach the raw evidence. Describe only the category of the privacy failure.

## Interpretation

`<State what the evidence confirms, contradicts, and leaves unknown. Separate direct observation from inference.>`

## Decision before another hardware action

`<Document the exact proposed next step, its safety boundary, and the review required.>`

## Scope limitation

This checkpoint does not establish glucose accuracy, protocol authentication, history framing, activation behavior, iOS background operation, LoopKit integration, or suitability for treatment decisions or closed-loop dosing.

# Trio × Brazilian Libre 2 Plus — development build

## Build identity

| Item | Value |
| --- | --- |
| Installed base | `rodrigo-v0.8.4` at `55d984f11704e0fd516c7d6a7f27671d038d995a` |
| Base release | `0.8.4` (build `1`) |
| Development version | `0.8.4.18` (build `18`) |
| Apple development team | `6KLJLLTX3K` |
| Bundle identifier | `org.nightscout.6KLJLLTX3K.trio` |
| Shared scheme | `Trio` |
| Distribution path | Xcode Cloud / TestFlight |

## Exact status

This branch is an integration and safety build. It is **not yet a functional
native Brazilian Libre 2 Plus CGM source** and must not be used as the only
glucose source.

The build identifies the confirmed Brazilian Gen2 profile, validates the two
read-only NFC responses, and routes the complete in-memory evidence through a
license-neutral provider boundary. The production default provider is
unavailable and fails closed. No pairing success is published for the Brazilian
profile.

The missing component is an independently authorized Apple arm64 or portable
Gen2 provider that completes all of the following:

1. NFC authentication and sensor-state transition;
2. streaming configuration and BLE identification;
3. secure BLE session establishment;
4. streaming-frame authentication and decryption;
5. glucose extraction and sensor lifecycle state.

The public Juggluco repository does not provide this component as portable
source. Its open Gen2 control flow calls native `V1`/`V2` operations from an
Abbott Android library. Android ELF/JNI libraries cannot be linked into an iOS
application. Current DiaBLE sources recognize Gen2 profiles but still leave
challenge processing and secure streaming-session creation unimplemented.

The provider contract and acceptance criteria are documented in
[`AUTHORIZED_PROVIDER_CONTRACT.md`](AUTHORIZED_PROVIDER_CONTRACT.md). The
current checkpoint and reproducible hashes are documented in
[`CONTINUITY_2026-08-21.md`](CONTINUITY_2026-08-21.md).

Primary-source references:

- [Juggluco repository](https://github.com/j-kaltes/Juggluco)
- [Current DiaBLE Gen2 implementation](https://github.com/gui-dos/DiaBLE)
- [Current LibreTransmitter upstream](https://github.com/loopandlearn/LibreTransmitter)

## Implemented changes

- Recognizes only the observed Brazilian Plus generation within the `0x2B`
  family; other `0x2B` profiles remain unknown.
- Selects a protocol driver before any state-changing NFC command is sent.
- Preserves the existing European Libre 2 pairing and decryption path.
- Blocks the European `A1/1E` streaming command for Brazilian Gen2 sensors.
- Reads and validates only the Brazilian Gen2 session counter (`A1/22`, six
  bytes) and challenge (`A1/20`, 25 bytes).
- Models empty, partial, and complete evidence and rejects conflicting
  duplicates or unexpected lengths.
- Adds bounded provider input/result, capability, opaque-output descriptor, BLE
  identifier, and UUID state-token types.
- Adds `AuthorizedLibre2ProviderAdapter` as the sole license-neutral injection
  seam for a future authorized backend.
- Maps unavailable and unknown provider states to a fully empty, unavailable
  result and never infers pairing success.
- Keeps `UnavailableLibre2VendorBridge` as the production default.
- Stops safely even when a future backend reports `success` or
  `alreadyActive`; the operational NFC/BLE/glucose path remains gated.
- Reads all 43 European FRAM blocks sequentially, removing the previous race.
- Stores a versioned diagnostic containing only control-flow metadata, byte
  counts, public error codes, capabilities, and output-category names.
- Excludes UID, patch info, FRAM, NFC payloads, challenge, authentication data,
  BLE address, and provider state from new diagnostics and logs.
- Displays the detected Brazilian profile and shares only sanitized JSON.
- Adds unit coverage for profile routing, European regression, response lengths,
  evidence state, bridge limits, unavailable behavior, adapter normalization,
  state-token forwarding, and diagnostic privacy.
- Restores the concrete `LibreTransmitterTests` unit-test target referenced by
  the shared Xcode scheme; its source, product, phases, dependency, and build
  configurations are all checked by the post-clone validator.
- Runs a source-safety audit after applying the patch in CI.

## Repository structure

The Trio repository remains pinned to the official LibreTransmitter submodule
at `20f6d0e171450b294b202cefa8edaf2c5e4a5150`. Brazilian changes are stored in
`ci_scripts/libre_brasil.patch.b64` and applied by
`ci_scripts/apply_libre_brasil_patch.sh`. Xcode Cloud invokes the patch and
source validation from `ci_scripts/ci_post_clone.sh`.

For a local clone:

```sh
git clone --recurse-submodules --branch rodrigo-v0.8.4-libre-brasil-dev \
  https://github.com/rodrigomarson/Trio.git
cd Trio
./ci_scripts/apply_libre_brasil_patch.sh .
./ci_scripts/validate_libre_brasil_sources.sh .
open Trio.xcworkspace
```

Both scripts are idempotent for an already-patched checkout.

## Validation procedure

1. Apply the patch to a clean checkout of the fixed submodule commit.
2. Run `validate_libre_brasil_sources.sh` and `git diff --check` in both
   repositories.
3. Resolve Swift packages in the `Trio` workspace.
4. Build the `LibreTransmitter` shared scheme for an iOS simulator.
5. Run `LibreTransmitterTests`.
6. Build the `Trio` scheme for a physical iPhone without starting an NFC scan.
7. Confirm that the European Libre 2 regression tests remain green.
8. Generate the archive through the existing Xcode Cloud workflow.
9. Do not describe or distribute the build as native Brazilian CGM support
   until the full provider conformance gate passes.

The repository workflow now also applies the Brazilian patch on pushes to this
development branch and can be started manually. Local Linux validation cannot
replace Xcode compilation or a physical NFC/BLE test.

## Provider conformance gate

A backend is not eligible to replace the safe default unless all items are
evidenced:

- Apple arm64 library or portable source with documented origin and rights;
- no Android/JNI runtime dependency;
- complete NFC activation and authentication path;
- complete BLE authentication, streaming, and decryption path;
- explicit retry, terminal failure, success, and already-active states;
- sanitized BLE identifier and opaque handling of authentication material;
- sensor warm-up, active, expired, removed, and error-state coverage;
- fixture tests and on-device tests using a development sensor;
- no raw secret, key, challenge, or authenticated-payload logging;
- unchanged European Libre 2 behavior;
- no pairing-success publication before a glucose stream is independently
  validated.

## Xcode Cloud and TestFlight

Use the existing Trio workflow with this development branch and the shared
`Trio` scheme. The post-clone script applies and validates the LibreTransmitter
patch before compilation.

The local development version is `0.8.4.18`, build `18`. App Store Connect must
receive a build number greater than every build already uploaded for the same
marketing version. If build `18` is already present, select the next available
number in the workflow and update both version fields before the next archive.

## On-device Brazilian diagnostic test

Use a sensor reserved for development. Do not make treatment decisions from
this experimental path.

1. Install the successful build through TestFlight.
2. In Trio, select Libre direct connection and scan the Brazilian Libre 2 Plus.
3. Confirm that Trio reports **Libre 2 Plus Brazil** rather than
   **No Sensor Detected**.
4. Confirm that both read-only responses pass their exact length checks.
5. Confirm that the European streaming command was not sent.
6. Confirm that the result is the explicit provider-unavailable safe stop.
7. Export the diagnostic and verify that it contains byte counts and metadata
   only—never UID, patch info, FRAM, NFC response payloads, BLE address, or
   authentication material.
8. Record the app version and commercial sensor model separately.

The European regression result remains the existing direct pairing path.

## Emergency continuity path

Until the native provider exists, the deployable bridge remains:

```text
Brazilian Libre 2 Plus → Juggluco on Android → Nightscout → Trio on iPhone
```

This is a fallback, not the final architecture. A fresh sensor used by this
bridge must be activated in Juggluco rather than the experimental Trio build.
Keep Android background activity enabled, disable battery optimization for
Juggluco, use the Nightscout base URL without `/api`, and avoid duplicate Trio
glucose uploads while Nightscout is the CGM source.

Verify two consecutive current values in Juggluco, Nightscout, and Trio before
enabling closed loop. Treat stale, missing, or clinically inconsistent readings
as unavailable and confirm with a blood-glucose meter.

References:

- [Juggluco Nightscout uploader instructions](https://www.juggluco.nl/Jugglucohelp/NightPost.html?lang=en)
- [Abbott Brazil Libre 2 product information](https://www.freestyle.abbott/pt-br/products/freestyle-libre-2.html)

## Next native step

The next implementation step starts only when a complete iOS-compatible backend
has documented origin, authorization, and license. It must satisfy the contract
for Gen2 NFC activation/authentication, BLE session establishment, stream
processing, glucose extraction, reconnection, and lifecycle transitions.

Until that backend passes deterministic and physical-device tests, provider
`success` and `alreadyActive` results remain safe stops. The European adapter
remains unchanged and regression-covered.

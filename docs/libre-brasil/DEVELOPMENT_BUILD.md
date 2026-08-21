# Trio × Brazilian Libre 2 Plus — development build

## Build identity

| Item | Value |
| --- | --- |
| Installed base | `rodrigo-v0.8.4` at `55d984f11704e0fd516c7d6a7f27671d038d995a` |
| Base release | `0.8.4` (build `1`) |
| Development version | `0.8.4.18` |
| Apple development team | `6KLJLLTX3K` |
| Bundle identifier | `org.nightscout.6KLJLLTX3K.trio` |
| Shared scheme | `Trio` |
| Distribution path | Xcode Cloud / TestFlight |

## Exact status

This branch is an integration and safety build. It is **not yet a functional
native Brazilian Libre 2 Plus CGM source**.

The build identifies the confirmed Brazilian Gen2 profile, validates the two
read-only NFC responses, and routes them through a license-neutral provider
boundary. The production default provider is unavailable and fails closed. No
pairing success is published for the Brazilian profile.

The missing component is an independently authorized Apple arm64/portable Gen2
provider that completes all of the following:

1. NFC authentication and sensor-state transition;
2. streaming configuration and BLE identification;
3. secure BLE session establishment;
4. streaming-frame authentication/decryption;
5. glucose extraction and sensor lifecycle state.

The public Juggluco repository does not provide this component as portable
source. Its build instructions require `libcalibrat2.so` and/or
`libcalibrate.so` extracted from an Android APK. Android ELF/JNI libraries
cannot be linked into an iOS application. The current DiaBLE source still
leaves Gen2 challenge processing and secure streaming session creation as
TODOs.

Primary-source references:

- [Juggluco repository and build requirements](https://github.com/j-kaltes/Juggluco)
- [DiaBLE Gen2 BLE TODOs](https://github.com/gui-dos/DiaBLE/blob/main/DiaBLE/Abbott.swift)
- [Current LibreTransmitter upstream](https://github.com/loopandlearn/LibreTransmitter)

## Implemented changes

- Recognizes patch-info values beginning with `0x2B` as Brazilian Libre 2 Plus.
- Selects a protocol driver before any state-changing NFC command is sent.
- Preserves the existing European Libre 2 pairing and decryption path.
- Blocks the European `A1/1E` streaming command for Brazilian Gen2 sensors.
- Reads all 43 European FRAM blocks sequentially, removing the previous race.
- Reads and validates only the Brazilian Gen2 session-counter (`A1/22`, six
  bytes) and challenge (`A1/20`, 25 bytes) prefix.
- Never logs or persists the raw Gen2 counter or challenge bytes.
- Adds bounded evidence, provider input/result, capability, opaque descriptor,
  and state-token types.
- Adds `AuthorizedLibre2ProviderAdapter` as the sole license-neutral injection
  seam for a future authorized backend.
- Maps unknown provider states to `unavailable` and never infers pairing success.
- Keeps the default backend unavailable and preserves a visible safe stop.
- Adds unit coverage for classification, exact evidence sizes, incomplete input,
  unavailable behavior, adapter normalization, and dependency injection.

## Repository structure

The Trio repository remains pinned to the official LibreTransmitter submodule.
Brazilian changes are stored in `ci_scripts/libre_brasil.patch.b64` and applied
by `ci_scripts/apply_libre_brasil_patch.sh`. Xcode Cloud invokes the script from
`ci_scripts/ci_post_clone.sh`.

For a local clone:

```sh
git clone --recurse-submodules --branch rodrigo-v0.8.4-libre-brasil-dev \
  https://github.com/rodrigomarson/Trio.git
cd Trio
./ci_scripts/apply_libre_brasil_patch.sh .
open Trio.xcworkspace
```

The patch script is idempotent.

## Validation procedure

1. Apply the patch to a clean checkout.
2. Run `git -C LibreTransmitter diff --check`.
3. Resolve Swift packages in the `Trio` workspace.
4. Build the `LibreTransmitter` shared scheme for an iOS simulator.
5. Run `LibreTransmitterTests`.
6. Build the `Trio` scheme for an iPhone without starting an NFC session.
7. Confirm that the European Libre 2 regression tests remain green.
8. Do not distribute a build as Brazilian Libre 2 Plus capable until the full
   provider conformance gate below passes.

## Provider conformance gate

A backend is not eligible to replace the safe default unless all items are
evidenced:

- Apple arm64 library or portable source with documented origin and rights;
- no Android/JNI runtime dependency;
- complete NFC activation/authentication path;
- complete BLE authentication, streaming, and decryption path;
- explicit retry, terminal failure, success, and already-active states;
- sanitized BLE identifier and opaque handling of authentication material;
- sensor warm-up, active, expired, removed, and error state coverage;
- fixture tests and on-device tests using a development sensor;
- no raw secret, key, challenge, or authenticated payload logging;
- unchanged European Libre 2 behavior;
- no pairing-success publication before a glucose stream is independently
  validated.

## Immediate continuity path

Until the native provider exists, the supported emergency architecture is:

```text
Brazilian Libre 2 Plus → Juggluco on Android → Nightscout → Trio on iPhone
```

Juggluco can activate and receive the sensor directly, and its documented
Nightscout uploader sends streaming values as they arrive. Trio's built-in
`Nightscout as CGM` source polls every minute.

Configuration rules:

- Activate the fresh sensor in Juggluco, not in the experimental Trio build.
- Keep Android background activity enabled and battery optimization disabled.
- Use the Nightscout base URL only, without `/api` or a trailing path.
- Keep Juggluco `test V3` off when the existing instance already uses V1.
- Keep Juggluco `Give Amounts` off unless treatment mapping is intentionally
  configured.
- Keep Trio glucose upload off while Nightscout is the glucose source to avoid
  duplicate/feedback uploads.
- Verify two consecutive, current values in Juggluco, Nightscout, and Trio
  before enabling closed loop.
- Treat stale, missing, or clinically inconsistent readings as unavailable and
  confirm with a blood-glucose meter.

References:

- [Juggluco Nightscout uploader instructions](https://www.juggluco.nl/Jugglucohelp/NightPost.html?lang=en)
- [Abbott Brazil Libre 2 Plus product information](https://www.freestyle.abbott/pt-br/products/freestyle-libre-2.html)

This emergency bridge does not change the final native architecture. It keeps a
validated glucose source available while the authorized Gen2 provider remains
the blocking dependency.

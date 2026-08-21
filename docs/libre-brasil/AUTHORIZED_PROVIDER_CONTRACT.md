# Brazilian Libre 2 Gen2 authorized-provider contract

## Status

The Trio-owned integration boundary is implemented. The default provider is
unavailable and fails closed. No production pairing success is published for the
Brazilian Gen2 route.

This boundary is intentionally license-neutral. It contains no Juggluco
implementation code, proprietary sensor algorithm, authentication key, activation
payload generator, protected payload parser, or glucose decoder.

## Route

```text
Brazilian profile gate
  -> A1/22 + A1/20 read-only acquisition
  -> strict length and evidence-state validation
  -> Libre2VendorBridgeInput
  -> optional authorized backend
  -> normalized Libre2VendorBridgeResult
  -> safe stop until the operational NFC/BLE/data path is integrated
```

The European Libre 2 route does not enter this bridge.

## Bounded input

`Libre2VendorBridgeInput` accepts only:

- an 8-byte sensor UID in memory;
- a 6-byte patch-information value in memory;
- a complete validated read-only evidence object containing:
  - a 6-byte A1/22 response;
  - a 25-byte A1/20 response;
- an optional UUID used only as a lookup key for provider-owned state.

These values must not be logged, serialized, or persisted by Trio or the provider.

## Normalized output

The provider returns a Trio-owned result with:

- status: unavailable, retry, terminal failure, success, or already active;
- declared capabilities: scan, streaming, warm-up state, and backup state;
- an optional normalized BLE identifier;
- descriptors stating only that opaque BLE-authentication, stream-configuration, or
  next-state outputs exist;
- an optional next UUID lookup token.

Unknown backend statuses normalize to unavailable. Authentication and stream
configuration bytes are never returned through the public Trio result.

## Runtime safety

- No European activation or streaming command may be sent after the Brazilian gate.
- Only A1/22 and A1/20 are executed by the current Brazilian path.
- The default `UnavailableLibre2VendorBridge` must remain the production default
  until an authorized backend is deliberately injected.
- Backend `.success` and `.alreadyActive` remain safe-stop outcomes in
  `SensorPairingService`; they are not pairing success.
- Diagnostics contain only call-path metadata, byte counts, public error codes,
  capability names, and output-category names.
- UID, patch info, NFC payloads, FRAM, BLE packets, BLE address, authentication data,
  and provider state must never enter diagnostics or logs.

## Backend acceptance gate

A backend is not ready until all of the following are evidenced:

- Apple arm64 iOS library or portable source is available.
- The implementation is independent of Android/JNI at runtime.
- Origin, authorization, distribution rights, and license obligations are documented.
- Retry, terminal failure, success, and already-active outcomes are explicit.
- State-token continuity works without exposing provider state bytes.
- Unknown results fail closed.
- Simulator compile, device build, and deterministic contract tests pass.
- The operational NFC activation, BLE authentication/session, stream decoding,
  glucose publication, reconnection, warm-up, expiry, and failure transitions are
  covered by device evidence.
- European Libre 2 regression tests pass unchanged.

## Remaining blocker

No independently authorized, permissively distributable, complete iOS Gen2 backend
has been linked. The open Juggluco orchestration delegates the required Gen2
transformations and glucose processing to an Abbott native library; its Java/C++
control flow is therefore not a standalone algorithm that can be translated into
Swift.

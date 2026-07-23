# CoreBluetooth transport design

## Purpose

This phase adds the smallest Apple-platform Bluetooth boundary needed to exercise the existing transport-independent coordinator. It does not add a Trio CGM manager, persist keys, decode unconfirmed history responses, or publish data for dosing.

The implementation is split so that command and event routing can be tested without constructing Apple `CBPeripheral` objects:

```text
MicroTechConnectionCoordinator
        | transport commands
        v
MicroTechBluetoothTransport
        | driver operations
        v
MicroTechCoreBluetoothDriver -> CoreBluetooth

CoreBluetooth callbacks
        | typed driver events
        v
MicroTechBluetoothTransport
        | validated coordinator events
        v
caller-owned MicroTechConnectionCoordinator
```

The caller remains responsible for feeding each event from `MicroTechBluetoothTransport.eventHandler` back into its coordinator and applying the resulting effects. This explicit boundary prevents the Bluetooth layer from persisting secrets or publishing glucose by itself.

## Command mapping

| Coordinator transport command | CoreBluetooth operation |
|---|---|
| Scan | Scan for service `181F` only |
| Stop scanning | Stop the active central scan |
| Connect | Use the discovered peripheral or retrieve it by identifier, then connect |
| Discover characteristics | Discover service `181F`, then request `F001`, `F002`, and `F003` |
| Enable notifications | Call `setNotifyValue(true, ...)` for the mapped characteristic |
| Read | Call `readValue(...)` for the mapped characteristic |
| Write | Call `writeValue(...)` using the requested response mode |
| Disconnect | Stop scanning and cancel the active peripheral connection |

CoreBluetooth may report Bluetooth SIG base UUIDs in short or full form. The bridge accepts both forms for service `181F` and characteristics `F001`, `F002`, and `F003`.

## Event filtering and safety

- Discovery is limited to advertisements accepted by `MicroTechDiscoveredDevice`, including a known family prefix, a strict 10-character serial suffix, and service `181F`.
- Connection, characteristic, notification, value, and disconnection callbacks from any identifier other than the active peripheral are ignored.
- Apple error text is not propagated through protocol events. Failures are reduced to typed, non-sensitive categories.
- The CoreBluetooth layer does not log payload bytes, master keys, session keys, glucose values, or serial-derived cryptographic material.
- A transport failure moves the coordinator to a failed state and requests disconnection.
- The transport uses a dedicated serial dispatch queue. Its active-identifier boundary is lock-protected because the initial command can originate on a different caller queue.

## Validation boundary

The platform-independent bridge has synthetic tests for:

- every coordinator command;
- validated and rejected advertisements;
- short and full characteristic UUIDs;
- active-peripheral isolation;
- notification and value routing;
- disconnect and connection-failure routing; and
- typed transport failures.

`MicroTechCoreBluetoothDriver.swift` is conditionally compiled only where CoreBluetooth is available. A successful `swift test` run on macOS will therefore compile the real Apple adapter in addition to running the synthetic bridge tests. The driver cannot be exercised against a real peripheral until the SMART 2.0 arrives.

## Deliberately deferred

- confirmation of the Brazilian sensor's advertised local name and service list;
- confirmation that characteristics `F001`, `F002`, and `F003` expose the assumed read, write, and notify properties;
- iOS Bluetooth bonding prompts and reconnect behavior;
- state restoration and background execution policy;
- application-level timeout scheduling;
- secure master-key persistence;
- parsing of real history-range and history-page responses;
- Trio/LoopKit manager, setup UI, and glucose-store integration; and
- any use of experimental values for treatment or closed-loop dosing.

## First hardware capture

The first sensor session should collect metadata only before enabling protocol writes:

1. advertised local name;
2. advertised service UUIDs;
3. peripheral identifier;
4. discovered services;
5. characteristic UUIDs and CoreBluetooth properties; and
6. notification-subscription results.

Payload capture and key exchange should begin only after those identifiers match the documented assumptions. Captured reports must redact sensor serials, peripheral identifiers, keys, exact glucose values, and other personal health data before they are added to the repository.

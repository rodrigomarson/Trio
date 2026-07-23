# Read-only SMART 2.0 discovery probe

## Purpose

`MicroTechDiscoveryProbe` prepares the first physical-sensor inspection without performing protocol authentication or requesting glucose data. It scans only for the standard Continuous Glucose Monitoring service, accepts only an advertisement that passes the existing strict SMART-family name and serial-shape checks, connects, discovers GATT metadata, writes a redacted report, and exits.

The probe is a temporary research tool. It is not a Trio CGM manager and must not be distributed as a medical-device integration.

## Operations the probe performs

- scans with the `181F` service filter;
- validates a `Smart-` family local name with a 10-character ASCII alphanumeric suffix;
- connects to the matching peripheral;
- discovers all advertised GATT services;
- discovers characteristic UUIDs and their CoreBluetooth property flags;
- writes a deterministic redacted text report; and
- disconnects.

## Operations the probe never performs

- characteristic-value reads;
- notification or indication subscriptions;
- key exchange or pairing commands;
- characteristic writes;
- sensor activation or clock changes;
- glucose publication; or
- Trio/LoopKit integration.

Service and characteristic discovery necessarily exchange standard GATT metadata with the peripheral. “Read-only” in this document means that the probe does not request characteristic values or send application-protocol commands.

## Privacy boundary

The saved report contains only:

- a redacted local name that preserves the family prefix but not the serial suffix;
- advertised and discovered service UUIDs;
- characteristic UUIDs; and
- characteristic property names.

The report never receives or renders the peripheral identifier, manufacturer data, service-data payloads, RSSI, key material, characteristic values, glucose values, or Apple error text. Unknown local-name content is redacted before it is printed.

## Build without running

From the package directory on a Mac:

```sh
swift build --product MicroTechDiscoveryProbe
swift test
./Tools/build-macos-discovery-probe.sh
```

The build script creates an ad-hoc-signed app bundle under `.build` with the required Bluetooth usage description. It does not launch the probe.

## Run only after the sensor arrives

Keep the official sensor application closed so that it does not compete for the same connection. From the package directory:

```sh
.build/MicroTechDiscoveryProbe.app/Contents/MacOS/MicroTechDiscoveryProbe \
  --output "$HOME/Downloads/MicroTechDiscoveryReport.txt" \
  --timeout 60
```

macOS may request Bluetooth permission the first time. Grant it only to the clearly named `MicroTech Discovery Probe` bundle. The command stops after one validated SMART-family device is inspected or after the timeout.

Before sharing the report, verify that the local-name line contains a redaction marker and no sensor serial. Stop immediately if any unexpected identifier or value appears.

## Expected pre-hardware validation

The phase-4 checkpoint must prove that:

- the executable target compiles on macOS;
- all synthetic tests pass;
- report ordering is deterministic;
- known and unknown local-name shapes are redacted;
- a sensor serial cannot appear in the formatted report; and
- the app bundle can be created and ad-hoc signed without launching it.

Physical service and characteristic assumptions remain unvalidated until the sensor is present.

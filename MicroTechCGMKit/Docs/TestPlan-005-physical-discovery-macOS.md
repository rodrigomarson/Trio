# MicroTechCGMKit test plan 005

## Goal

Perform the first physical SMART 2.0 inspection with the already validated macOS discovery probe. The run may collect only redacted advertisement and GATT metadata. It must not read characteristic values, subscribe to notifications, initiate protocol authentication, write commands, activate the sensor, or publish glucose.

This is an evidence-gathering checkpoint, not a compatibility or medical-device test.

## Validated starting point

- feature branch checkpoint: `ac3720b`;
- validated archive: `MicroTechCGMKit_phase4_validated_ac3720b.zip`;
- archive SHA-256: `5246cdeadcb1a057ca1f6561d2ad07d4be8c67973a3d956e9f1bb18a509a70b8`;
- expected XCTest count: 58;
- phase-4 result: Debug and Release builds passed, the app bundle was ad-hoc signed and verified, and the executable was not launched.

## Known unknowns before the sensor arrives

The following must remain unconfirmed until physical evidence is collected:

- whether the Brazilian sensor advertises Bluetooth before normal activation;
- the exact advertised local-name format;
- whether service `181F` appears in the advertisement;
- the complete discovered service list;
- the characteristic UUIDs and their properties;
- whether metadata discovery causes an unexpected bonding or pairing prompt; and
- whether the official application temporarily competes for the peripheral connection.

Do not weaken the service or name filters merely to obtain a result. A timeout is valid evidence and must be analyzed before the probe is changed.

## Safety boundary

The experimental output must never be used for treatment decisions or insulin dosing. Do not activate, insert, replace, or otherwise change the normal use of a sensor solely for this research run. Follow the manufacturer-supplied Brazilian instructions for all activation and clinical-use steps.

Do not run the probe if temporarily closing the official application or briefly connecting another Bluetooth central would create an unacceptable monitoring interruption. After the probe exits, reopen the official application and confirm that its normal connection has resumed before doing any further research work.

Stop immediately if macOS requests Bluetooth pairing, a PIN, or bonding confirmation. Metadata discovery is not expected to require any of those actions.

## Stage A — package and manual inspection

Complete this stage before opening or activating the sensor:

1. Preserve the original packaging and manufacturer instructions.
2. Photograph the front and back of the box, sensor applicator, relevant manual pages, and regulatory labels.
3. Keep the original images private.
4. Create redacted copies that hide the sensor serial, UDI, QR codes, barcodes, order information, patient information, and any other unique identifier.
5. Record only the non-sensitive product name, model, hardware revision, stated application name/version, regulatory registration, and documented activation or pairing sequence.
6. Check whether the manual says when Bluetooth advertising begins and whether the sensor permits more than one client connection.

If the manual contradicts this plan, stop and review the conflict before using the probe.

## Stage B — source preflight on the Mac

Use the validated archive rather than an older extracted folder. From Terminal:

```sh
cd "$HOME/Downloads"
shasum -a 256 MicroTechCGMKit_phase4_validated_ac3720b.zip
```

The result must exactly match the archive SHA-256 listed above. Extract the ZIP if necessary, then run:

```sh
cd "$HOME/Downloads/MicroTechCGMKit-phase4-validated-ac3720b"
(
set -e
shasum -a 256 -c SOURCE_MANIFEST.sha256
swift test
./Tools/build-macos-discovery-probe.sh
/usr/bin/codesign --verify --deep --strict \
  .build/MicroTechDiscoveryProbe.app
)
```

Proceed only if every manifest entry reports `OK`, exactly 58 XCTest cases pass, the app bundle is prepared, and signature verification returns successfully without output.

Do not launch the executable during the preflight.

## Stage C — one metadata-only run

This stage may occur only after Stage A has been reviewed and the sensor is in the state reached through its normal manufacturer-defined workflow. Do not activate a sensor only to satisfy this test.

1. Keep the sensor near the Mac.
2. Close the official sensor application immediately before the run only if doing so is safe for the intended use of the sensor.
3. Keep the complete Terminal output.
4. Run exactly one 60-second attempt:

```sh
cd "$HOME/Downloads/MicroTechCGMKit-phase4-validated-ac3720b"
.build/MicroTechDiscoveryProbe.app/Contents/MacOS/MicroTechDiscoveryProbe \
  --output "$HOME/Downloads/MicroTechDiscoveryReport-phase5.txt" \
  --timeout 60
```

macOS may request Bluetooth permission for `MicroTech Discovery Probe`. Grant only that named permission. If the system instead requests device pairing, a PIN, or bonding confirmation, cancel it, press Control-C in Terminal, and stop the phase.

The probe must either save one redacted report and exit or stop with one typed failure category. Do not rerun it, broaden the scan, open Bluetooth-inspection software, or send any protocol command during this phase.

## Stage D — privacy and recovery checks

After the process exits:

1. Reopen the official application.
2. Confirm that its normal sensor connection resumes before continuing the research review.
3. Do not use the experimental report for treatment decisions.
4. If a report was produced, inspect it locally before sharing it:

```sh
sed -n '1,240p' "$HOME/Downloads/MicroTechDiscoveryReport-phase5.txt"
shasum -a 256 "$HOME/Downloads/MicroTechDiscoveryReport-phase5.txt"
```

The report is shareable only if all of the following are true:

- `Local name` contains a redaction marker and no serial from the label;
- `Peripheral identifier` is exactly `<redacted>`;
- no manufacturer-data or service-data payload appears;
- no characteristic value, key material, glucose value, patient information, barcode, or UDI appears; and
- the remaining content is limited to service UUIDs, characteristic UUIDs, and characteristic property names.

If any sensitive or unexpected value appears, do not upload the report. Preserve it privately, describe only the type of leak, and stop for a redaction fix.

## Evidence to return

Return these items together, after the privacy check:

- the complete Terminal transcript from the single attempt;
- `MicroTechDiscoveryReport-phase5.txt`, if produced;
- the report SHA-256, if produced;
- redacted packaging and manual images from Stage A;
- the Mac model class and macOS version, without account or device serial information;
- the qualitative sensor state: unopened, normally activated/warming up, or normally active; and
- whether the official application resumed its normal connection after the probe exited.

Do not include a glucose value, trend, alarm, sensor serial, peripheral UUID, UDI, barcode, patient name, account name, or order information.

## Outcome classification

### A — metadata report completed

Record the exact redacted services, characteristics, and properties. Compare them with the current assumptions, but make no protocol changes until the report is documented and reviewed.

### B — metadata completed with unexpected UUIDs or properties

Treat the difference as a discovery, not a failure. Record it and stop. Do not read the new characteristic or infer its meaning from properties alone.

### C — timeout or no validated SMART candidate

Record the sensor state, official-application state, and timeout. Stop. The next step is to analyze the manual and the strict discovery assumptions; it is not to remove privacy or service filters during the same session.

### D — connection, permission, or discovery failure

Record only the probe's typed failure category. Do not collect Apple error text or use a generic Bluetooth explorer as a workaround.

### E — pairing prompt, privacy leak, or official-application recovery problem

Cancel or terminate the probe and stop all hardware research. This outcome requires a design review before another attempt.

## Completion rule

Phase 5 ends after the first attempt and its evidence review, regardless of outcome. Create `TestReport-005-physical-discovery-macOS.md` from the supplied template before changing any identifier, filter, command, or transport behavior.

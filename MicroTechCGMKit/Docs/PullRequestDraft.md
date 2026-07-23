# Draft pull request — experimental MicroTech SMART 2.0 protocol research

## Suggested title

`[Draft/RFC] Add experimental MicroTech SMART 2.0 CGM protocol package`

## Status

**Local draft only. Do not submit as production-ready CGM support.**

The current branch is intended to make the interoperability research reviewable and reproducible while hardware validation is still in progress. It does not add a selectable CGM source to Trio and must not be described as medical-device compatibility.

## Summary

This draft adds a self-contained experimental Swift package for researching direct support for MicroTech GX-01S-family continuous glucose monitors. The initial Brazilian target is the MedLevensohn SMART 2.0.

The package separates protocol processing, connection coordination, Bluetooth transport, synthetic tests, and a temporary metadata-only macOS probe. This keeps unvalidated hardware assumptions outside Trio's production CGM and dosing paths.

## Problem

SMART 2.0 is available to Brazilian users but Trio has no direct, reviewed driver for this sensor family. A production integration cannot be designed safely from product branding alone: the actual Brazilian Bluetooth advertisement, GATT layout, pairing behavior, packet framing, and lifecycle behavior must be confirmed with traceable physical evidence.

## What this draft contains

- strict ten-character ASCII sensor-serial parsing;
- CRC8/MAXIM and CRC16-CCITT-FALSE implementations;
- serial-derived key-request and message-IV helpers;
- AES-128-CFB128 framing with a fresh IV per message;
- session-key packet validation;
- safe encoding for the currently modeled non-destructive commands;
- strict processed-live-glucose packet decoding;
- a pure five-minute publication gate matching Trio's current dosing-data cadence;
- a CoreBluetooth-independent connection coordinator;
- deterministic new-pairing, reconnect, retry, timeout, and paged-backfill simulation;
- a fake transport and platform-independent command/event bridge;
- a conditional Apple CoreBluetooth driver;
- a temporary macOS discovery probe limited to redacted GATT metadata;
- 58 synthetic XCTest cases; and
- design documents, test plans, source manifests, and macOS validation reports.

## What this draft deliberately does not contain

- a Trio or LoopKit CGM manager;
- user interface, settings, onboarding, or sensor selection;
- sensor activation or clock-setting support;
- production key storage or state restoration;
- verified history-response parsing;
- calibration, raw history, OTA, manufacturing, reset, or storage-clear commands;
- iOS background-restoration behavior;
- physical-sensor compatibility evidence;
- glucose-accuracy evidence; or
- any path that feeds experimental samples to dosing or closed-loop operation.

## Architecture

The research package is embedded in this feature branch only to preserve one reviewable history while the protocol boundary is validated. It is not proposed as the final Trio directory layout.

The preferred production direction, subject to maintainer agreement, is a separately reviewed sensor-driver repository integrated through Trio's existing CGM dependency architecture. Protocol parsing should remain independent of CoreBluetooth and LoopKit. A Trio adapter should be added only after the physical protocol and lifecycle behavior are confirmed.

## Validation evidence

| Phase | Scope | Result | Report |
|---|---|---|---|
| 1 | protocol primitives and processed packet decoder | 25/25 XCTest, reproduced from verified archive | `TestReport-001-macOS-arm64.md` |
| 2 | simulated transport and connection coordinator | 41/41 XCTest | `TestReport-002-simulated-transport-macOS-arm64.md` |
| 3 | platform bridge and conditional CoreBluetooth compilation | 50/50 XCTest | `TestReport-003-corebluetooth-macOS-arm64.md` |
| 4 | privacy-hardened metadata probe, Debug/Release builds, app signing | 58/58 XCTest; app signature verified; probe not launched | `TestReport-004-discovery-probe-macOS-arm64.md` |
| 5 | first physical metadata-only inspection | pending sensor arrival | `TestPlan-005-physical-discovery-macOS.md` |

All completed macOS checkpoints used checkpoint-specific archives with `SOURCE_MANIFEST.sha256` verification. CryptoSwift is pinned to version 1.10.0.

## How to review the synthetic package

```sh
cd MicroTechCGMKit
shasum -a 256 -c SOURCE_MANIFEST.sha256
swift test
swift build --product MicroTechDiscoveryProbe
```

The package currently expects exactly 58 XCTest cases. A separate Swift Testing result that reports zero tests is normal because the suite uses XCTest.

## Safety and privacy controls

- Experimental output is explicitly excluded from treatment and dosing use.
- The hardware probe does not read characteristic values, subscribe, authenticate, or write.
- Peripheral identifiers, serial suffixes, manufacturer data, service data, RSSI, Apple error text, keys, and glucose values are excluded from its report model.
- Unknown and malformed local names are redacted.
- A failed privacy test is preserved in the history together with its correction and successful regression run.
- Physical work has an explicit stop-on-first-result plan before any protocol interaction.

## Provenance

The implementation is based on an interoperability description, standard cryptographic and checksum algorithms, and synthetic fixtures. No captured patient data, device keys, or production sensor values are committed. GPL implementation source, comments, tests, naming, and file structure must not be copied into this package.

## Questions for maintainers

1. Should the eventual driver live in a separate repository and be integrated as a submodule or Swift package, matching other Trio CGM drivers?
2. Is CryptoSwift 1.10.0 acceptable for this isolated protocol implementation, or should the final driver use an existing Trio cryptographic dependency?
3. Which LoopKit CGM-manager boundary should a future adapter target after hardware validation?
4. What physical evidence and lifecycle scenarios should be mandatory before a production integration PR is opened?
5. Should the temporary macOS discovery tool remain in the research repository, move to a separate tooling repository, or be omitted from the final driver?
6. Do maintainers want an early Draft/RFC before hardware protocol validation, or only after metadata and read-only live-notification evidence are available?

## Acceptance gates before this can become an integration PR

- [x] protocol primitives covered by synthetic tests;
- [x] coordinator behavior covered by deterministic simulation;
- [x] Apple CoreBluetooth adapter compiles;
- [x] metadata-only probe passes privacy tests and macOS packaging checks;
- [ ] Brazilian SMART 2.0 advertisement and GATT metadata confirmed;
- [ ] pairing and reconnect behavior confirmed without unsafe writes;
- [ ] packet headers and lifecycle states confirmed from authorized physical evidence;
- [ ] history framing confirmed;
- [ ] secret persistence and iOS state restoration designed and reviewed;
- [ ] Trio/LoopKit adapter implemented behind a non-production feature boundary;
- [ ] integration tests and failure recovery completed;
- [ ] clinical-use language, privacy behavior, and user warnings reviewed by maintainers.

## Draft checklist

- [x] code and project documentation are in English;
- [x] protocol logic is transport-independent;
- [x] hardware assumptions are identified explicitly;
- [x] synthetic fixtures contain no captured device or health data;
- [x] source identity is recorded with manifests and checkpoint commits;
- [x] failed experiments are preserved rather than overwritten;
- [ ] phase-5 physical metadata report reviewed;
- [ ] maintainer architecture direction recorded;
- [ ] final repository placement agreed;
- [ ] production integration scope defined.

## Reviewer note

The most useful outcome of an early review is architectural direction, not approval to use this code with therapy. Please treat all sensor compatibility statements as pending until the physical checkpoints are complete.

# MicroTechCGMKit experimental protocol core

This directory contains the pre-hardware, transport-independent protocol core for direct MicroTech GX-01S-family CGM support. The first Brazilian validation target is the MedLevensohn SMART 2.0.

It is intentionally embedded in the Trio feature branch while the protocol and hardware behavior are being validated. It is not the proposed final Trio layout. After maintainer agreement, it should become a separately reviewed driver repository and be integrated into Trio as a submodule, matching the existing CGM architecture.

## Current scope

- strict 10-character sensor serial validation;
- serial-derived key request and message IV;
- CRC8/MAXIM and CRC16-CCITT-FALSE;
- AES-128-CFB128 framing with a fresh IV per message;
- session-key packet validation;
- safe encoding of non-destructive MVP commands;
- safe decoding of processed live glucose packets;
- a pure five-minute publication gate for Trio's current dosing-data cadence;
- synthetic unit-test vectors with no captured device keys or personal data.

## Deliberately excluded

- CoreBluetooth transport and iOS bonding;
- sensor activation and clock writes;
- history response parsing until its exact Brazilian packet header is captured;
- calibration, raw history, OTA, manufacturing parameters, reset, and storage clearing;
- LoopKit manager/UI integration;
- any claim of medical-device compatibility.

## Run the tests

From Terminal on a Mac with a current Xcode toolchain:

```sh
cd MicroTechCGMKit
swift test
```

Alternatively, open `Package.swift` in Xcode and run the `MicroTechCGMKit` package tests.

CryptoSwift 1.10.0 is pinned to match the dependency currently resolved by Trio's workspace.

## Validation status

Two Apple Silicon macOS runs built successfully and passed all 25 XCTest cases. The second run used a fresh, checkpoint-specific archive extraction, closing the initial source-identity caveat. See [test report 001](Docs/TestReport-001-macOS-arm64.md).

## Safety and provenance

No experimental output is suitable for treatment decisions or closed-loop dosing. The implementation is written from an interoperability specification and uses standard cryptographic/checksum algorithms plus synthetic fixtures. Do not copy GPL implementation source, comments, tests, naming, or file structure into this package.

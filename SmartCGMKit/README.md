# SmartCGMKit

Direct Smart/LinX CGM component extracted from the preserved Trio production-validation implementation.

- `SmartCGMKit` implements `CGMManager` and owns advertisement parsing, bounded Bluetooth activation/history requests, session state, regularization, reminders and handover protection.
- `SmartCGMKitUI` adds `CGMManagerUI`, onboarding/settings/replacement screens and the sensor-specific calibration section.
- `SmartCGMKitTests` tests protocol, lifecycle policies and compatibility with existing persisted state without starting Bluetooth.

The Xcode project defines two framework products. It links the LoopKit and LoopKitUI frameworks supplied by the containing workspace, following the component layout used by this Trio baseline. It has no dependency on the Trio application target. Add both framework products to the app and embed them; import both modules when registering the manager.

The Trio integration uses `Trio.xcworkspace`. For module tests:

```sh
xcodebuild -workspace Trio.xcworkspace -scheme SmartCGMKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

The host must declare Bluetooth background reception and required Bluetooth privacy strings, retain its calibration persistence/application pipeline, and enforce the automatic-insulin interlock. This component is not a pump driver and cannot enforce dosing policy inside an arbitrary host on its own.

The public manager initializers start monitoring. Internal initializers allow deterministic state-restoration tests without radio or notification scheduling. Existing manager identifiers, state keys, Bluetooth restoration IDs and notification IDs are deliberately retained for in-place migration compatibility.

This is a local engineering candidate. Simulator tests do not validate sensor hardware, iOS background delivery, energy consumption or production readiness. See the host's `DeveloperDocs/SmartCGM` for the migration inventory and validation record.

import Foundation
import Swinject
import Testing

@testable import Trio

@Suite("Calibration Service Tests", .serialized) struct CalibrationTests: Injectable {
    let fileStorage = BaseFileStorage()
    @Injected() var calibrationService: CalibrationService!
    let resolver = TrioApp().resolver

    init() {
        injectServices(resolver)
    }

    @Test("Can create simple calibration") func testCreateSimpleCalibration() {
        // Given
        calibrationService.removeAllCalibrations()
        let calibration = Calibration(x: 100.0, y: 102.0)

        // When
        calibrationService.addCalibration(calibration)

        // Then
        #expect(calibrationService.calibrations.isNotEmpty)
        #expect(calibrationService.slope == 1)
        #expect(calibrationService.intercept == 2)
        #expect(calibrationService.calibrate(value: 104) == 106)
    }

    @Test("Can handle multiple calibrations") func testCreateMultipleCalibration() {
        // Given
        calibrationService.removeAllCalibrations()
        let calibration = Calibration(x: 100.0, y: 120)
        let calibration2 = Calibration(x: 120.0, y: 130.0)

        // When
        calibrationService.addCalibration(calibration)
        calibrationService.addCalibration(calibration2)

        // Then
        #expect(abs(calibrationService.slope - 0.8) < 0.0001)
        #expect(abs(calibrationService.intercept - 37) < 0.0001)
        #expect(abs(calibrationService.calibrate(value: 80) - 101) < 0.0001)

        // When removing last
        calibrationService.removeLast()
        #expect(calibrationService.calibrations.count == 1)

        // When removing all
        calibrationService.removeAllCalibrations()
        #expect(calibrationService.calibrations.isEmpty)
    }

    @Test("Handles calibration bounds correctly") func testCalibrationBounds() {
        // Given
        calibrationService.removeAllCalibrations()

        // When no calibrations exist
        #expect(calibrationService.slope == 1, "Default slope should be 1")
        #expect(calibrationService.intercept == 0, "Default intercept should be 0")

        // When adding extreme values
        let extremeCalibration1 = Calibration(x: 0.0, y: 1000.0) // Should be clamped
        let extremeCalibration2 = Calibration(x: 1000.0, y: 0.0) // Should be clamped

        calibrationService.addCalibration(extremeCalibration1)
        calibrationService.addCalibration(extremeCalibration2)

        // Then check bounds
        #expect(calibrationService.slope >= 0.8, "Slope should not be less than minimum")
        #expect(calibrationService.slope <= 1.25, "Slope should not be more than maximum")
        #expect(calibrationService.intercept >= -100, "Intercept should not be less than minimum")
        #expect(calibrationService.intercept <= 100, "Intercept should not be more than maximum")
    }

    @Test("Uses offset-only calibration when sensor points are too close") func testCloseCalibrationPoints() {
        calibrationService.removeAllCalibrations()
        calibrationService.addCalibration(Calibration(x: 100, y: 105))
        calibrationService.addCalibration(Calibration(x: 101, y: 106))

        #expect(calibrationService.slope == 1)
        #expect(calibrationService.intercept == 5)
        #expect(calibrationService.calibrate(value: 110) == 115)
    }

    @Test("Keeps only the ten most recent calibration points") func testCalibrationHistoryLimit() {
        calibrationService.removeAllCalibrations()

        for value in 0 ... 11 {
            calibrationService.addCalibration(
                Calibration(x: Double(80 + value * 5), y: Double(82 + value * 5))
            )
        }

        #expect(calibrationService.calibrations.count == 10)
        #expect(calibrationService.calibrations.first?.x == 90)
        #expect(calibrationService.calibrations.last?.x == 135)
    }

    @Test("Clears Smart calibration when the physical sensor changes") func testSmartSensorChangeClearsCalibration() {
        calibrationService.removeAllCalibrations()
        calibrationService.addCalibration(Calibration(x: 100, y: 110))

        Foundation.NotificationCenter.default.post(name: .smartSensorDidChange, object: nil)

        #expect(calibrationService.calibrations.isEmpty)
        #expect(calibrationService.slope == 1)
        #expect(calibrationService.intercept == 0)
    }

    @Test(
        "Preserves calibration for repeated state updates from the same CGM manager"
    ) func testSameManagerStateUpdatePreservesCalibration() {
        let manager = NSObject()

        let shouldReset = CGMCalibrationResetPolicy.shouldResetForManagerUpdate(
            currentManagerIdentifier: ObjectIdentifier(manager),
            newManagerIdentifier: ObjectIdentifier(manager)
        )

        #expect(!shouldReset)
    }

    @Test("Resets calibration when the CGM manager is actually replaced") func testManagerReplacementResetsCalibration() {
        let currentManager = NSObject()
        let replacementManager = NSObject()

        let shouldReset = CGMCalibrationResetPolicy.shouldResetForManagerUpdate(
            currentManagerIdentifier: ObjectIdentifier(currentManager),
            newManagerIdentifier: ObjectIdentifier(replacementManager)
        )

        #expect(shouldReset)
    }

    @Test(
        "Resets calibration when a CGM manager is configured for the first time"
    ) func testFirstManagerConfigurationResetsCalibration() {
        let manager = NSObject()

        let shouldReset = CGMCalibrationResetPolicy.shouldResetForManagerUpdate(
            currentManagerIdentifier: nil,
            newManagerIdentifier: ObjectIdentifier(manager)
        )

        #expect(shouldReset)
    }
}

import XCTest
@testable import MicroTechCGMKit

final class SensorSerialTests: XCTestCase {
    func testNormalizesLowercaseAscii() throws {
        let serial = try MicroTechSensorSerial("a1b2c3d4e5")
        XCTAssertEqual(serial.normalizedValue, "A1B2C3D4E5")
        XCTAssertEqual(serial.mappedValues, [10, 1, 11, 2, 12, 3, 13, 4, 14, 5])
    }

    func testRejectsWrongLength() {
        XCTAssertThrowsError(try MicroTechSensorSerial("123456789")) { error in
            XCTAssertEqual(error as? MicroTechProtocolError, .invalidSerialLength(actual: 9))
        }
    }

    func testRejectsNonAsciiLookalike() {
        XCTAssertThrowsError(try MicroTechSensorSerial("A1B2C3D4É5"))
    }

    func testRejectsPunctuation() {
        XCTAssertThrowsError(try MicroTechSensorSerial("A1B2C3D4-5"))
    }
}

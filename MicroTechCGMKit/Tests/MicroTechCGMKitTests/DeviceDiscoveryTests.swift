import Foundation
import XCTest
@testable import MicroTechCGMKit

final class DeviceDiscoveryTests: XCTestCase {
    func testRecognizesKnownProtocolFamilyNames() throws {
        let cases: [(String, MicroTechDeviceFamily)] = [
            ("Smart-A1B2C3D4E5", .smart),
            ("LinX-A1B2C3D4E5", .linX),
            ("AiDEX X-A1B2C3D4E5", .aiDEXX),
            ("Lumi-A1B2C3D4E5", .lumi)
        ]

        for (localName, expectedFamily) in cases {
            let device = MicroTechDiscoveredDevice(
                identifier: UUID(),
                localName: localName,
                advertisedServiceUUIDs: [MicroTechBluetoothIdentifiers.service]
            )

            XCTAssertEqual(device?.family, expectedFamily)
            XCTAssertEqual(device?.serial, try MicroTechSensorSerial("A1B2C3D4E5"))
        }
    }

    func testAcceptsShortServiceUUID() {
        XCTAssertNotNil(
            MicroTechDiscoveredDevice(
                identifier: UUID(),
                localName: "Smart-A1B2C3D4E5",
                advertisedServiceUUIDs: ["181f"]
            )
        )
    }

    func testRejectsMissingProtocolService() {
        XCTAssertNil(
            MicroTechDiscoveredDevice(
                identifier: UUID(),
                localName: "Smart-A1B2C3D4E5",
                advertisedServiceUUIDs: ["180D"]
            )
        )
    }

    func testRejectsUnknownFamilyName() {
        XCTAssertNil(
            MicroTechDiscoveredDevice(
                identifier: UUID(),
                localName: "Other-A1B2C3D4E5",
                advertisedServiceUUIDs: ["181F"]
            )
        )
    }

    func testRejectsInvalidSerialSuffix() {
        XCTAssertNil(
            MicroTechDiscoveredDevice(
                identifier: UUID(),
                localName: "Smart-A1B2C3D4-5",
                advertisedServiceUUIDs: ["181F"]
            )
        )
    }
}

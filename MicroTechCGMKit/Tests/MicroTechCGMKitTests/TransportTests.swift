import XCTest
@testable import MicroTechCGMKit

final class TransportTests: XCTestCase {
    func testSimulatedTransportRecordsCoordinatorCommands() throws {
        let serial = try MicroTechSensorSerial("A1B2C3D4E5")
        var coordinator = MicroTechConnectionCoordinator(serial: serial)
        let transport = MicroTechSimulatedTransport()

        let effects = coordinator.handle(.start, using: transport)

        XCTAssertEqual(
            effects,
            [.transport(.scan(serviceUUID: MicroTechBluetoothIdentifiers.service))]
        )
        XCTAssertEqual(
            transport.performedCommands,
            [.scan(serviceUUID: MicroTechBluetoothIdentifiers.service)]
        )

        transport.reset()
        XCTAssertTrue(transport.performedCommands.isEmpty)
    }

    func testSecretDescriptionNeverContainsKeyBytes() throws {
        let secret = try MicroTechSecret(
            keyBytes: [UInt8](hexadecimalString: "00112233445566778899aabbccddeeff")
        )

        XCTAssertEqual(secret.description, "<redacted 16-byte secret>")
        XCTAssertEqual(secret.debugDescription, "<redacted 16-byte secret>")
        XCTAssertFalse(secret.description.contains("001122"))
    }
}

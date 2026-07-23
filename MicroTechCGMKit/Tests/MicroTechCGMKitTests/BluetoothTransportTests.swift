import Foundation
import XCTest
@testable import MicroTechCGMKit

final class BluetoothTransportTests: XCTestCase {
    private let deviceIdentifier = UUID(
        uuidString: "28EB6FC0-E6B8-42F6-8785-AE703510AE10"
    )!

    func testForwardsEveryCoordinatorCommandToTheDriver() {
        let driver = FakeBluetoothDriver()
        let transport = MicroTechBluetoothTransport(driver: driver)

        transport.perform(.scan(serviceUUID: MicroTechBluetoothIdentifiers.service))
        transport.perform(.stopScanning)
        transport.perform(.connect(identifier: deviceIdentifier))
        transport.perform(
            .discoverCharacteristics(serviceUUID: MicroTechBluetoothIdentifiers.service)
        )
        transport.perform(.enableNotifications(.liveGlucose))
        transport.perform(.read(.command))
        transport.perform(
            .write(
                bytes: [0x10, 0x20],
                characteristic: .command,
                withResponse: true
            )
        )
        transport.perform(.disconnect)

        XCTAssertEqual(
            driver.operations,
            [
                .scan(MicroTechBluetoothIdentifiers.service),
                .stopScanning,
                .connect(deviceIdentifier),
                .discoverCharacteristics(MicroTechBluetoothIdentifiers.service),
                .enableNotifications(.liveGlucose),
                .read(.command),
                .write([0x10, 0x20], .command, true),
                .disconnect
            ]
        )
    }

    func testDiscoveryOnlyEmitsValidatedProtocolDevices() {
        let driver = FakeBluetoothDriver()
        var events: [MicroTechCoordinatorEvent] = []
        let transport = MicroTechBluetoothTransport(driver: driver) {
            events.append($0)
        }

        driver.emit(
            .discovered(
                identifier: deviceIdentifier,
                localName: nil,
                advertisedServiceUUIDs: ["181F"]
            )
        )
        driver.emit(
            .discovered(
                identifier: deviceIdentifier,
                localName: "Other-A1B2C3D4E5",
                advertisedServiceUUIDs: ["181F"]
            )
        )
        driver.emit(
            .discovered(
                identifier: deviceIdentifier,
                localName: "Smart-A1B2C3D4E5",
                advertisedServiceUUIDs: ["180D"]
            )
        )
        driver.emit(
            .discovered(
                identifier: deviceIdentifier,
                localName: "Smart-A1B2C3D4E5",
                advertisedServiceUUIDs: ["181F"]
            )
        )

        XCTAssertEqual(events.count, 1)
        guard case let .discovered(device)? = events.first else {
            return XCTFail("Expected one validated discovery event")
        }
        XCTAssertEqual(device.identifier, deviceIdentifier)
        XCTAssertEqual(device.family, .smart)
        _ = transport
    }

    func testMapsActivePeripheralCallbacksAndIgnoresOtherDevices() {
        let driver = FakeBluetoothDriver()
        var events: [MicroTechCoordinatorEvent] = []
        let transport = MicroTechBluetoothTransport(driver: driver) {
            events.append($0)
        }
        let otherIdentifier = UUID()

        transport.perform(.connect(identifier: deviceIdentifier))
        driver.emit(.connected(identifier: otherIdentifier))
        driver.emit(.connected(identifier: deviceIdentifier))
        driver.emit(
            .characteristicsDiscovered(
                identifier: deviceIdentifier,
                serviceUUID: "181f",
                characteristicUUIDs: [
                    "f001",
                    MicroTechCharacteristic.command.rawValue,
                    "F003",
                    "F099"
                ]
            )
        )
        driver.emit(
            .notificationStateChanged(
                identifier: deviceIdentifier,
                characteristicUUID: "F003",
                isEnabled: false
            )
        )
        driver.emit(
            .notificationStateChanged(
                identifier: deviceIdentifier,
                characteristicUUID: "F003",
                isEnabled: true
            )
        )
        driver.emit(
            .valueUpdated(
                identifier: deviceIdentifier,
                characteristicUUID: "F003",
                bytes: [0x01, 0x02]
            )
        )

        XCTAssertEqual(
            events,
            [
                .connected,
                .characteristicsDiscovered([.keyExchange, .command, .liveGlucose]),
                .notificationsEnabled(.liveGlucose),
                .valueReceived(characteristic: .liveGlucose, bytes: [0x01, 0x02])
            ]
        )
        _ = transport
    }

    func testDisconnectAndConnectionFailureOnlyApplyToTheActiveDevice() {
        let driver = FakeBluetoothDriver()
        var events: [MicroTechCoordinatorEvent] = []
        let transport = MicroTechBluetoothTransport(driver: driver) {
            events.append($0)
        }

        transport.perform(.connect(identifier: deviceIdentifier))
        driver.emit(.connectionFailed(identifier: UUID()))
        driver.emit(.connectionFailed(identifier: deviceIdentifier))
        driver.emit(.disconnected(identifier: deviceIdentifier))

        XCTAssertEqual(events, [.disconnected])
        _ = transport
    }

    func testMapsAvailabilityAndRedactedTransportFailures() {
        let driver = FakeBluetoothDriver()
        var events: [MicroTechCoordinatorEvent] = []
        let transport = MicroTechBluetoothTransport(driver: driver) {
            events.append($0)
        }

        driver.emit(.bluetoothUnavailable)
        driver.emit(.failed(.notificationSetupFailed(.command)))

        XCTAssertEqual(
            events,
            [
                .bluetoothUnavailable,
                .transportFailed(.notificationSetupFailed(.command))
            ]
        )
        _ = transport
    }
}

private final class FakeBluetoothDriver: MicroTechBluetoothDriver {
    enum Operation: Equatable {
        case scan(String)
        case stopScanning
        case connect(UUID)
        case discoverCharacteristics(String)
        case enableNotifications(MicroTechCharacteristic)
        case read(MicroTechCharacteristic)
        case write([UInt8], MicroTechCharacteristic, Bool)
        case disconnect
    }

    var eventHandler: ((MicroTechBluetoothDriverEvent) -> Void)?
    private(set) var operations: [Operation] = []

    func scan(for serviceUUID: String) {
        operations.append(.scan(serviceUUID))
    }

    func stopScanning() {
        operations.append(.stopScanning)
    }

    func connect(identifier: UUID) {
        operations.append(.connect(identifier))
    }

    func discoverCharacteristics(serviceUUID: String) {
        operations.append(.discoverCharacteristics(serviceUUID))
    }

    func enableNotifications(for characteristic: MicroTechCharacteristic) {
        operations.append(.enableNotifications(characteristic))
    }

    func read(_ characteristic: MicroTechCharacteristic) {
        operations.append(.read(characteristic))
    }

    func write(
        bytes: [UInt8],
        to characteristic: MicroTechCharacteristic,
        withResponse: Bool
    ) {
        operations.append(.write(bytes, characteristic, withResponse))
    }

    func disconnect() {
        operations.append(.disconnect)
    }

    func emit(_ event: MicroTechBluetoothDriverEvent) {
        eventHandler?(event)
    }
}

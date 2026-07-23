import Foundation

public enum MicroTechBluetoothDriverEvent: Equatable, Sendable {
    case bluetoothUnavailable
    case discovered(
        identifier: UUID,
        localName: String?,
        advertisedServiceUUIDs: [String]
    )
    case connected(identifier: UUID)
    case connectionFailed(identifier: UUID)
    case disconnected(identifier: UUID)
    case characteristicsDiscovered(
        identifier: UUID,
        serviceUUID: String,
        characteristicUUIDs: [String]
    )
    case notificationStateChanged(
        identifier: UUID,
        characteristicUUID: String,
        isEnabled: Bool
    )
    case valueUpdated(
        identifier: UUID,
        characteristicUUID: String,
        bytes: [UInt8]
    )
    case failed(MicroTechTransportFailure)
}

public protocol MicroTechBluetoothDriver: AnyObject {
    var eventHandler: ((MicroTechBluetoothDriverEvent) -> Void)? { get set }

    func scan(for serviceUUID: String)
    func stopScanning()
    func connect(identifier: UUID)
    func discoverCharacteristics(serviceUUID: String)
    func enableNotifications(for characteristic: MicroTechCharacteristic)
    func read(_ characteristic: MicroTechCharacteristic)
    func write(
        bytes: [UInt8],
        to characteristic: MicroTechCharacteristic,
        withResponse: Bool
    )
    func disconnect()
}

/// Bridges platform Bluetooth operations to the transport-independent coordinator.
///
/// The caller owns the coordinator and must feed each event from `eventHandler`
/// back into it. This transport never persists keys or publishes glucose values.
public final class MicroTechBluetoothTransport: MicroTechTransport {
    public var eventHandler: ((MicroTechCoordinatorEvent) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedEventHandler
        }
        set {
            lock.lock()
            storedEventHandler = newValue
            lock.unlock()
        }
    }

    private let driver: MicroTechBluetoothDriver
    private let lock = NSLock()
    private var storedEventHandler: ((MicroTechCoordinatorEvent) -> Void)?
    private var activeIdentifier: UUID?

    public init(
        driver: MicroTechBluetoothDriver,
        eventHandler: ((MicroTechCoordinatorEvent) -> Void)? = nil
    ) {
        self.driver = driver
        storedEventHandler = eventHandler
        driver.eventHandler = { [weak self] event in
            self?.handleDriverEvent(event)
        }
    }

    public func perform(_ command: MicroTechTransportCommand) {
        switch command {
        case let .scan(serviceUUID):
            setActiveIdentifier(nil)
            driver.scan(for: serviceUUID)

        case .stopScanning:
            driver.stopScanning()

        case let .connect(identifier):
            setActiveIdentifier(identifier)
            driver.connect(identifier: identifier)

        case let .discoverCharacteristics(serviceUUID):
            driver.discoverCharacteristics(serviceUUID: serviceUUID)

        case let .enableNotifications(characteristic):
            driver.enableNotifications(for: characteristic)

        case let .read(characteristic):
            driver.read(characteristic)

        case let .write(bytes, characteristic, withResponse):
            driver.write(
                bytes: bytes,
                to: characteristic,
                withResponse: withResponse
            )

        case .disconnect:
            setActiveIdentifier(nil)
            driver.disconnect()
        }
    }

    private func handleDriverEvent(_ event: MicroTechBluetoothDriverEvent) {
        switch event {
        case .bluetoothUnavailable:
            emit(.bluetoothUnavailable)

        case let .discovered(identifier, localName, advertisedServiceUUIDs):
            guard let localName,
                  let device = MicroTechDiscoveredDevice(
                      identifier: identifier,
                      localName: localName,
                      advertisedServiceUUIDs: advertisedServiceUUIDs
                  )
            else {
                return
            }
            emit(.discovered(device))

        case let .connected(identifier):
            guard identifier == currentActiveIdentifier() else {
                return
            }
            emit(.connected)

        case let .connectionFailed(identifier), let .disconnected(identifier):
            guard identifier == currentActiveIdentifier() else {
                return
            }
            setActiveIdentifier(nil)
            emit(.disconnected)

        case let .characteristicsDiscovered(identifier, serviceUUID, characteristicUUIDs):
            guard identifier == currentActiveIdentifier(),
                  MicroTechBluetoothIdentifiers.isProtocolService(serviceUUID)
            else {
                return
            }

            let characteristics = Set(
                characteristicUUIDs.compactMap(MicroTechCharacteristic.init(bluetoothUUID:))
            )
            emit(.characteristicsDiscovered(characteristics))

        case let .notificationStateChanged(identifier, characteristicUUID, isEnabled):
            guard identifier == currentActiveIdentifier(),
                  isEnabled,
                  let characteristic = MicroTechCharacteristic(
                      bluetoothUUID: characteristicUUID
                  )
            else {
                return
            }
            emit(.notificationsEnabled(characteristic))

        case let .valueUpdated(identifier, characteristicUUID, bytes):
            guard identifier == currentActiveIdentifier(),
                  let characteristic = MicroTechCharacteristic(
                      bluetoothUUID: characteristicUUID
                  )
            else {
                return
            }
            emit(
                .valueReceived(characteristic: characteristic, bytes: bytes)
            )

        case let .failed(failure):
            emit(.transportFailed(failure))
        }
    }

    private func currentActiveIdentifier() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return activeIdentifier
    }

    private func setActiveIdentifier(_ identifier: UUID?) {
        lock.lock()
        activeIdentifier = identifier
        lock.unlock()
    }

    private func emit(_ event: MicroTechCoordinatorEvent) {
        let handler = eventHandler
        handler?(event)
    }
}

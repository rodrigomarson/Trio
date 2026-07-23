#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

/// Thin Apple-platform adapter. Protocol interpretation remains in
/// `MicroTechConnectionCoordinator` and is intentionally not duplicated here.
public final class MicroTechCoreBluetoothDriver: NSObject, MicroTechBluetoothDriver {
    public var eventHandler: ((MicroTechBluetoothDriverEvent) -> Void)?

    private let queue: DispatchQueue
    private let restorationIdentifier: String?
    private let restoredPeripheralLocalName: String?
    private var pendingScanServiceUUID: String?
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var activePeripheral: CBPeripheral?
    private var characteristics: [MicroTechCharacteristic: CBCharacteristic] = [:]

    private lazy var centralManager = CBCentralManager(
        delegate: self,
        queue: queue,
        options: restorationIdentifier.map {
            [CBCentralManagerOptionRestoreIdentifierKey: $0] as [String: Any]
        }
    )

    public init(
        queue: DispatchQueue = DispatchQueue(
            label: "org.nightscout.trio.microtech-core-bluetooth"
        ),
        restorationIdentifier: String? = nil,
        restoredPeripheralLocalName: String? = nil
    ) {
        self.queue = queue
        self.restorationIdentifier = restorationIdentifier
        self.restoredPeripheralLocalName = restoredPeripheralLocalName
        super.init()
    }

    public func scan(for serviceUUID: String) {
        execute { [weak self] in
            guard let self else { return }
            pendingScanServiceUUID = serviceUUID
            beginPendingScanIfPossible()
        }
    }

    public func stopScanning() {
        execute { [weak self] in
            guard let self else { return }
            pendingScanServiceUUID = nil
            if centralManager.isScanning {
                centralManager.stopScan()
            }
        }
    }

    public func connect(identifier: UUID) {
        execute { [weak self] in
            guard let self else { return }

            let peripheral = discoveredPeripherals[identifier] ??
                centralManager.retrievePeripherals(withIdentifiers: [identifier]).first

            guard let peripheral else {
                emit(.failed(.deviceUnavailable))
                return
            }

            discoveredPeripherals[identifier] = peripheral
            activePeripheral = peripheral
            characteristics.removeAll()
            peripheral.delegate = self

            switch peripheral.state {
            case .connected:
                emit(.connected(identifier: identifier))
            case .disconnected:
                centralManager.connect(peripheral, options: nil)
            case .connecting, .disconnecting:
                break
            @unknown default:
                emit(.failed(.deviceUnavailable))
            }
        }
    }

    public func discoverCharacteristics(serviceUUID: String) {
        execute { [weak self] in
            guard let self else { return }
            guard let peripheral = activePeripheral else {
                emit(.failed(.serviceDiscoveryFailed))
                return
            }
            peripheral.discoverServices([CBUUID(string: serviceUUID)])
        }
    }

    public func enableNotifications(for characteristic: MicroTechCharacteristic) {
        execute { [weak self] in
            guard let self else { return }
            guard let peripheral = activePeripheral else {
                emit(.failed(.notificationSetupFailed(characteristic)))
                return
            }
            guard let cbCharacteristic = characteristics[characteristic] else {
                emit(.failed(.notificationSetupFailed(characteristic)))
                return
            }
            guard cbCharacteristic.properties.contains(.notify) ||
                cbCharacteristic.properties.contains(.indicate)
            else {
                emit(.failed(.notificationSetupFailed(characteristic)))
                return
            }
            peripheral.setNotifyValue(true, for: cbCharacteristic)
        }
    }

    public func read(_ characteristic: MicroTechCharacteristic) {
        execute { [weak self] in
            guard let self else { return }
            guard let peripheral = activePeripheral else {
                emit(.failed(.readFailed(characteristic)))
                return
            }
            guard let cbCharacteristic = characteristics[characteristic] else {
                emit(.failed(.readFailed(characteristic)))
                return
            }
            guard cbCharacteristic.properties.contains(.read) else {
                emit(.failed(.readFailed(characteristic)))
                return
            }
            peripheral.readValue(for: cbCharacteristic)
        }
    }

    public func write(
        bytes: [UInt8],
        to characteristic: MicroTechCharacteristic,
        withResponse: Bool
    ) {
        execute { [weak self] in
            guard let self else { return }
            guard let peripheral = activePeripheral else {
                emit(.failed(.writeFailed(characteristic)))
                return
            }
            guard let cbCharacteristic = characteristics[characteristic] else {
                emit(.failed(.writeFailed(characteristic)))
                return
            }

            let requiredProperty: CBCharacteristicProperties = withResponse ?
                .write : .writeWithoutResponse
            guard cbCharacteristic.properties.contains(requiredProperty) else {
                emit(.failed(.writeFailed(characteristic)))
                return
            }

            peripheral.writeValue(
                Data(bytes),
                for: cbCharacteristic,
                type: withResponse ? .withResponse : .withoutResponse
            )
        }
    }

    public func disconnect() {
        execute { [weak self] in
            guard let self else { return }
            pendingScanServiceUUID = nil
            if centralManager.isScanning {
                centralManager.stopScan()
            }

            guard let peripheral = activePeripheral else {
                return
            }
            if peripheral.state != .disconnected {
                centralManager.cancelPeripheralConnection(peripheral)
            }
            activePeripheral = nil
            characteristics.removeAll()
        }
    }

    private func execute(_ operation: @escaping () -> Void) {
        queue.async(execute: operation)
    }

    private func beginPendingScanIfPossible() {
        guard centralManager.state == .poweredOn,
              let serviceUUID = pendingScanServiceUUID
        else {
            return
        }

        if centralManager.isScanning {
            centralManager.stopScan()
        }
        centralManager.scanForPeripherals(
            withServices: [CBUUID(string: serviceUUID)],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func emit(_ event: MicroTechBluetoothDriverEvent) {
        eventHandler?(event)
    }

    private func advertisedServiceUUIDs(
        from advertisementData: [String: Any]
    ) -> [String] {
        let keys = [
            CBAdvertisementDataServiceUUIDsKey,
            CBAdvertisementDataOverflowServiceUUIDsKey,
            CBAdvertisementDataSolicitedServiceUUIDsKey
        ]

        var result = keys.flatMap { key in
            (advertisementData[key] as? [CBUUID] ?? []).map(\.uuidString)
        }

        if let pendingScanServiceUUID,
           !result.contains(where: {
               MicroTechBluetoothIdentifiers.isProtocolService($0)
           })
        {
            result.append(pendingScanServiceUUID)
        }

        return result
    }
}

extension MicroTechCoreBluetoothDriver: CBCentralManagerDelegate {
    public func centralManager(
        _ central: CBCentralManager,
        willRestoreState dictionary: [String: Any]
    ) {
        let peripherals = dictionary[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for peripheral in peripherals {
            discoveredPeripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self

            guard let localName = peripheral.name ?? restoredPeripheralLocalName else {
                continue
            }
            emit(
                .discovered(
                    identifier: peripheral.identifier,
                    localName: localName,
                    advertisedServiceUUIDs: [MicroTechBluetoothIdentifiers.service]
                )
            )
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            beginPendingScanIfPossible()
        case .poweredOff, .unauthorized, .unsupported:
            emit(.bluetoothUnavailable)
        case .unknown, .resetting:
            break
        @unknown default:
            emit(.bluetoothUnavailable)
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi _: NSNumber
    ) {
        discoveredPeripherals[peripheral.identifier] = peripheral

        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ??
            peripheral.name
        emit(
            .discovered(
                identifier: peripheral.identifier,
                localName: localName,
                advertisedServiceUUIDs: advertisedServiceUUIDs(from: advertisementData)
            )
        )
    }

    public func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        guard peripheral.identifier == activePeripheral?.identifier else {
            return
        }
        peripheral.delegate = self
        emit(.connected(identifier: peripheral.identifier))
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error _: Error?
    ) {
        guard peripheral.identifier == activePeripheral?.identifier else {
            return
        }
        emit(.connectionFailed(identifier: peripheral.identifier))
        activePeripheral = nil
        characteristics.removeAll()
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error _: Error?
    ) {
        guard peripheral.identifier == activePeripheral?.identifier else {
            return
        }
        emit(.disconnected(identifier: peripheral.identifier))
        activePeripheral = nil
        characteristics.removeAll()
    }
}

extension MicroTechCoreBluetoothDriver: CBPeripheralDelegate {
    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        guard peripheral.identifier == activePeripheral?.identifier else {
            return
        }
        guard error == nil else {
            emit(.failed(.serviceDiscoveryFailed))
            return
        }
        guard let service = peripheral.services?.first(where: {
            MicroTechBluetoothIdentifiers.isProtocolService($0.uuid.uuidString)
        }) else {
            emit(.failed(.serviceDiscoveryFailed))
            return
        }

        let requestedCharacteristics = MicroTechCharacteristic.allCases.map {
            CBUUID(string: $0.rawValue)
        }
        peripheral.discoverCharacteristics(requestedCharacteristics, for: service)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard peripheral.identifier == activePeripheral?.identifier else {
            return
        }
        guard error == nil else {
            emit(.failed(.characteristicDiscoveryFailed))
            return
        }

        let discovered = service.characteristics ?? []
        for characteristic in discovered {
            if let identifier = MicroTechCharacteristic(
                bluetoothUUID: characteristic.uuid.uuidString
            ) {
                characteristics[identifier] = characteristic
            }
        }

        emit(
            .characteristicsDiscovered(
                identifier: peripheral.identifier,
                serviceUUID: service.uuid.uuidString,
                characteristicUUIDs: discovered.map { $0.uuid.uuidString }
            )
        )
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral.identifier == activePeripheral?.identifier,
              let identifier = MicroTechCharacteristic(
                  bluetoothUUID: characteristic.uuid.uuidString
              )
        else {
            return
        }
        guard error == nil, characteristic.isNotifying else {
            emit(.failed(.notificationSetupFailed(identifier)))
            return
        }

        emit(
            .notificationStateChanged(
                identifier: peripheral.identifier,
                characteristicUUID: characteristic.uuid.uuidString,
                isEnabled: true
            )
        )
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral.identifier == activePeripheral?.identifier,
              let identifier = MicroTechCharacteristic(
                  bluetoothUUID: characteristic.uuid.uuidString
              )
        else {
            return
        }
        guard error == nil, let value = characteristic.value else {
            emit(.failed(.readFailed(identifier)))
            return
        }

        emit(
            .valueUpdated(
                identifier: peripheral.identifier,
                characteristicUUID: characteristic.uuid.uuidString,
                bytes: [UInt8](value)
            )
        )
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral.identifier == activePeripheral?.identifier,
              error != nil,
              let identifier = MicroTechCharacteristic(
                  bluetoothUUID: characteristic.uuid.uuidString
              )
        else {
            return
        }
        emit(.failed(.writeFailed(identifier)))
    }
}
#endif

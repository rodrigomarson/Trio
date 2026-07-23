#if os(macOS) && canImport(CoreBluetooth)
import CoreBluetooth
import Darwin
import Foundation
import MicroTechCGMKit

private struct ProbeConfiguration {
    let outputURL: URL
    let timeout: TimeInterval

    init(arguments: [String]) {
        var outputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("MicroTechDiscoveryReport.txt")
        var timeout: TimeInterval = 60

        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--output" where index + 1 < arguments.count:
                outputURL = URL(fileURLWithPath: arguments[index + 1])
                index += 2
            case "--timeout" where index + 1 < arguments.count:
                if let value = TimeInterval(arguments[index + 1]), value >= 10 {
                    timeout = value
                }
                index += 2
            default:
                index += 1
            }
        }

        self.outputURL = outputURL
        self.timeout = timeout
    }
}

private final class ReadOnlyMetadataProbe: NSObject {
    private let configuration: ProbeConfiguration
    private var centralManager: CBCentralManager!
    private var selectedPeripheral: CBPeripheral?
    private var selectedLocalName: String?
    private var advertisedServices: [String] = []
    private var discoveredServices: [String] = []
    private var characteristicMetadata: [MicroTechCharacteristicMetadata] = []
    private var pendingServiceUUIDs: Set<String> = []
    private var timeoutTimer: Timer?
    private var finished = false

    init(configuration: ProbeConfiguration) {
        self.configuration = configuration
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil, options: nil)
        timeoutTimer = Timer.scheduledTimer(
            withTimeInterval: configuration.timeout,
            repeats: false
        ) { [weak self] _ in
            self?.finishFailure("timeout-before-metadata-completed")
        }
    }

    private func advertisedServiceUUIDs(from advertisementData: [String: Any]) -> [String] {
        let keys = [
            CBAdvertisementDataServiceUUIDsKey,
            CBAdvertisementDataOverflowServiceUUIDsKey,
            CBAdvertisementDataSolicitedServiceUUIDsKey
        ]
        var values = keys.flatMap { key in
            (advertisementData[key] as? [CBUUID] ?? []).map(\.uuidString)
        }
        if !values.contains(where: MicroTechBluetoothIdentifiers.isProtocolService) {
            values.append(MicroTechBluetoothIdentifiers.service)
        }
        return values
    }

    private func mappedProperties(
        _ properties: CBCharacteristicProperties
    ) -> Set<MicroTechCharacteristicProperty> {
        var result: Set<MicroTechCharacteristicProperty> = []
        let mappings: [(CBCharacteristicProperties, MicroTechCharacteristicProperty)] = [
            (.broadcast, .broadcast),
            (.read, .read),
            (.writeWithoutResponse, .writeWithoutResponse),
            (.write, .write),
            (.notify, .notify),
            (.indicate, .indicate),
            (.authenticatedSignedWrites, .authenticatedSignedWrites),
            (.extendedProperties, .extendedProperties),
            (.notifyEncryptionRequired, .notifyEncryptionRequired),
            (.indicateEncryptionRequired, .indicateEncryptionRequired)
        ]
        for (coreBluetoothProperty, reportProperty) in mappings
            where properties.contains(coreBluetoothProperty)
        {
            result.insert(reportProperty)
        }
        return result
    }

    private func finishSuccess() {
        guard !finished else { return }
        timeoutTimer?.invalidate()

        let report = MicroTechDiscoveryReport(
            localName: selectedLocalName,
            advertisedServiceUUIDs: advertisedServices,
            discoveredServiceUUIDs: discoveredServices,
            characteristics: characteristicMetadata
        )

        do {
            try report.formattedText.write(
                to: configuration.outputURL,
                atomically: true,
                encoding: .utf8
            )
            finished = true
            print(report.formattedText, terminator: "")
            print("Saved redacted report as \(configuration.outputURL.lastPathComponent)")
            finish(exitCode: EXIT_SUCCESS)
        } catch {
            finished = true
            print("Probe stopped safely: could-not-save-redacted-report")
            finish(exitCode: EXIT_FAILURE)
        }
    }

    private func finishFailure(_ category: String) {
        guard !finished else { return }
        finished = true
        timeoutTimer?.invalidate()
        print("Probe stopped safely: \(category)")
        finish(exitCode: EXIT_FAILURE)
    }

    private func finish(exitCode: Int32) {
        centralManager.stopScan()
        if let selectedPeripheral {
            centralManager.cancelPeripheralConnection(selectedPeripheral)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            Darwin.exit(exitCode)
        }
    }
}

extension ReadOnlyMetadataProbe: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("Scanning for a SMART-family candidate advertising service 181F...")
            central.scanForPeripherals(
                withServices: [CBUUID(string: MicroTechBluetoothIdentifiers.service)],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        case .poweredOff, .unauthorized, .unsupported:
            finishFailure("bluetooth-unavailable-or-not-authorized")
        case .unknown, .resetting:
            break
        @unknown default:
            finishFailure("unknown-bluetooth-state")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi _: NSNumber
    ) {
        guard selectedPeripheral == nil else { return }

        let services = advertisedServiceUUIDs(from: advertisementData)
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ??
            peripheral.name
        guard let localName,
              let device = MicroTechDiscoveredDevice(
                  identifier: peripheral.identifier,
                  localName: localName,
                  advertisedServiceUUIDs: services
              ),
              device.family == .smart
        else {
            print(
                "Ignored non-SMART candidate: " +
                    MicroTechDiscoveryReport.redact(localName: localName)
            )
            return
        }

        selectedPeripheral = peripheral
        selectedLocalName = localName
        advertisedServices = services
        central.stopScan()
        peripheral.delegate = self
        print("Connecting to validated SMART candidate using metadata-only mode...")
        central.connect(peripheral, options: nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        guard peripheral.identifier == selectedPeripheral?.identifier else { return }
        print("Connected. Discovering GATT services without reading values...")
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error _: Error?
    ) {
        guard peripheral.identifier == selectedPeripheral?.identifier else { return }
        finishFailure("connection-failed")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error _: Error?
    ) {
        guard !finished, peripheral.identifier == selectedPeripheral?.identifier else {
            return
        }
        finishFailure("disconnected-before-metadata-completed")
    }
}

extension ReadOnlyMetadataProbe: CBPeripheralDelegate {
    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        guard peripheral.identifier == selectedPeripheral?.identifier else { return }
        guard error == nil, let services = peripheral.services, !services.isEmpty else {
            finishFailure("service-discovery-failed")
            return
        }

        discoveredServices = services.map { $0.uuid.uuidString }
        pendingServiceUUIDs = Set(discoveredServices.map { $0.uppercased() })
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard peripheral.identifier == selectedPeripheral?.identifier else { return }
        guard error == nil else {
            finishFailure("characteristic-discovery-failed")
            return
        }

        for characteristic in service.characteristics ?? [] {
            characteristicMetadata.append(
                MicroTechCharacteristicMetadata(
                    serviceUUID: service.uuid.uuidString,
                    characteristicUUID: characteristic.uuid.uuidString,
                    properties: mappedProperties(characteristic.properties)
                )
            )
        }

        pendingServiceUUIDs.remove(service.uuid.uuidString.uppercased())
        if pendingServiceUUIDs.isEmpty {
            finishSuccess()
        }
    }
}

let configuration = ProbeConfiguration(arguments: CommandLine.arguments)
let probe = ReadOnlyMetadataProbe(configuration: configuration)
withExtendedLifetime(probe) {
    RunLoop.main.run()
}
#else
import Foundation

print("MicroTechDiscoveryProbe requires macOS with CoreBluetooth.")
#endif

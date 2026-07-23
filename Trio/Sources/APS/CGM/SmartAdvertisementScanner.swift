import CoreBluetooth
import Foundation

/// Passively listens for the CGM service advertisements emitted by Smart/LinX sensors.
///
/// The sensor puts its current glucose value in manufacturer data, so this scanner never
/// connects to the peripheral and never competes with the manufacturer's application for
/// a GATT connection.
final class SmartAdvertisementScanner: NSObject {
    struct Reading {
        let peripheralIdentifier: UUID
        let localName: String?
        let rssi: Int
        let receivedAt: Date
        let advertisement: SmartAdvertisement
    }

    typealias ReadingHandler = (Reading) -> Void

    private static let cgmService = CBUUID(string: "181F")
    static let managerRestorationIdentifier = "com.nightscout.Trio.smartCGMScanner.manager"
    private static let scanRefreshInterval: TimeInterval = 25

    private let managerQueue = DispatchQueue(label: "com.nightscout.Trio.smartCGMScanner")
    private let readingHandler: ReadingHandler
    private let restorationIdentifier: String?
    private var centralManager: CBCentralManager!
    private var shouldScan = true
    private var refreshWorkItem: DispatchWorkItem?

    init(restorationIdentifier: String? = nil, readingHandler: @escaping ReadingHandler) {
        self.restorationIdentifier = restorationIdentifier
        self.readingHandler = readingHandler
        super.init()

        managerQueue.async {
            let options: [String: Any]? = self.restorationIdentifier.map {
                [CBCentralManagerOptionRestoreIdentifierKey: $0]
            }
            self.centralManager = CBCentralManager(
                delegate: self,
                queue: self.managerQueue,
                options: options
            )
        }
    }

    func start() {
        managerQueue.async {
            self.shouldScan = true
            self.startScanningIfPossible()
            self.scheduleScanRefreshIfNeeded()
        }
    }

    func stop() {
        managerQueue.async {
            self.shouldScan = false
            self.refreshWorkItem?.cancel()
            self.refreshWorkItem = nil
            self.centralManager?.stopScan()
        }
    }

    private func startScanningIfPossible() {
        guard shouldScan, centralManager?.state == .poweredOn, centralManager?.isScanning == false else {
            return
        }

        centralManager.scanForPeripherals(
            withServices: [Self.cgmService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    /// Some LinX firmware/iOS combinations only deliver one discovery callback for a
    /// long-running scan, even when duplicate discoveries are requested. Refreshing the
    /// scan periodically clears that discovery cache without connecting to the sensor.
    private func scheduleScanRefreshIfNeeded() {
        guard shouldScan, refreshWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.shouldScan else { return }
            self.refreshWorkItem = nil
            self.centralManager?.stopScan()
            self.startScanningIfPossible()
            self.scheduleScanRefreshIfNeeded()
        }
        refreshWorkItem = workItem
        managerQueue.asyncAfter(deadline: .now() + Self.scanRefreshInterval, execute: workItem)
    }
}

extension SmartAdvertisementScanner: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_: CBCentralManager) {
        startScanningIfPossible()
    }

    func centralManager(
        _: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard
            let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
            let advertisement = SmartAdvertisement(manufacturerData: manufacturerData)
        else {
            return
        }

        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        readingHandler(
            Reading(
                peripheralIdentifier: peripheral.identifier,
                localName: localName,
                rssi: RSSI.intValue,
                receivedAt: Date(),
                advertisement: advertisement
            )
        )
    }

    func centralManager(_: CBCentralManager, willRestoreState _: [String: Any]) {
        startScanningIfPossible()
    }
}

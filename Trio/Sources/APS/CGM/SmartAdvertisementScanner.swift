import CoreBluetooth
import Foundation

/// Listens for the CGM service advertisements emitted by Smart/LinX sensors.
///
/// Normal glucose delivery remains completely passive. A short GATT connection is made
/// only after an explicit historical-data request or an explicit new-sensor activation.
final class SmartAdvertisementScanner: NSObject {
    struct Reading {
        let peripheralIdentifier: UUID
        let localName: String?
        let rssi: Int
        let receivedAt: Date
        let advertisement: SmartAdvertisement
    }

    struct ActivationCandidate: Equatable {
        let peripheralIdentifier: UUID
        let localName: String?
        let rssi: Int
    }

    struct ActivationResult: Equatable {
        let peripheralIdentifier: UUID
        let localName: String?
        let sessionStartDate: Date
    }

    enum ActivationPhase: Equatable {
        case connecting
        case checkingSensor
        case startingSession
        case synchronizingTime
    }

    typealias ReadingHandler = (Reading) -> Void
    typealias BackfillCompletion = (Result<[SmartCGMMeasurement], Error>) -> Void
    typealias CandidateCompletion = (Result<ActivationCandidate, Error>) -> Void
    typealias ActivationCompletion = (Result<ActivationResult, Error>) -> Void

    enum BackfillError: LocalizedError {
        case alreadyRunning
        case bluetoothUnavailable
        case sensorUnavailable
        case connectionFailed
        case serviceUnavailable
        case characteristicsUnavailable
        case invalidFeature
        case invalidMeasurement
        case recordAccessFailed(UInt8)
        case timedOut
        case cancelled

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "Já existe uma recuperação de histórico em andamento."
            case .bluetoothUnavailable:
                return "O Bluetooth não está disponível."
            case .sensorUnavailable:
                return "O sensor Smart não está disponível para conexão."
            case .connectionFailed:
                return "Não foi possível conectar ao sensor Smart."
            case .serviceUnavailable:
                return "O serviço de glicemia do Smart não foi encontrado."
            case .characteristicsUnavailable:
                return "O Smart não expôs os canais necessários para recuperar o histórico."
            case .invalidFeature:
                return "As informações Bluetooth do Smart não puderam ser interpretadas."
            case .invalidMeasurement:
                return "Uma leitura histórica do Smart não pôde ser validada."
            case let .recordAccessFailed(code):
                return "O Smart recusou a recuperação do histórico (código \(code))."
            case .timedOut:
                return "O Smart não concluiu a recuperação do histórico a tempo."
            case .cancelled:
                return "A recuperação do histórico foi cancelada."
            }
        }
    }

    enum ActivationError: LocalizedError {
        case alreadyRunning
        case bluetoothUnavailable
        case sensorUnavailable
        case connectionFailed
        case serviceUnavailable
        case characteristicsUnavailable
        case invalidFeature
        case invalidStatus
        case currentSessionIsActive
        case startSessionFailed(UInt8?)
        case timeSynchronizationFailed
        case timedOut
        case cancelled

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "Já existe uma operação com o Smart em andamento."
            case .bluetoothUnavailable:
                return "O Bluetooth não está disponível."
            case .sensorUnavailable:
                return "Nenhum novo sensor Smart foi encontrado."
            case .connectionFailed:
                return "Não foi possível conectar ao novo sensor Smart."
            case .serviceUnavailable:
                return "O serviço de glicemia do novo Smart não foi encontrado."
            case .characteristicsUnavailable:
                return "O novo Smart não expôs os canais necessários para a ativação."
            case .invalidFeature:
                return "As informações Bluetooth do novo Smart não puderam ser validadas."
            case .invalidStatus:
                return "O estado do novo Smart não pôde ser validado com segurança."
            case .currentSessionIsActive:
                return "Esse Smart já possui uma sessão ativa. O sensor atual não foi alterado."
            case let .startSessionFailed(code):
                if let code {
                    return "O Smart recusou o início da nova sessão (código \(code))."
                }
                return "O Smart não confirmou o início da nova sessão."
            case .timeSynchronizationFailed:
                return "A sessão iniciou, mas o horário do Smart não pôde ser sincronizado."
            case .timedOut:
                return "O Smart não concluiu a ativação dentro do tempo seguro."
            case .cancelled:
                return "A ativação do novo Smart foi cancelada."
            }
        }
    }

    private final class CandidateDiscoveryRequest {
        let excludedPeripheralIdentifier: UUID
        let completion: CandidateCompletion

        init(
            excludedPeripheralIdentifier: UUID,
            completion: @escaping CandidateCompletion
        ) {
            self.excludedPeripheralIdentifier = excludedPeripheralIdentifier
            self.completion = completion
        }
    }

    private final class ActivationRequest {
        let candidate: ActivationCandidate
        let requestedStartDate: Date
        let progress: (ActivationPhase) -> Void
        let completion: ActivationCompletion
        var supportsE2ECRC: Bool?
        var status: SmartCGMStatus?
        var controlPointIndicationsEnabled = false
        var commandStarted = false
        var isWritingSessionStartTime = false
        var confirmedSessionStartDate: Date?

        init(
            candidate: ActivationCandidate,
            requestedStartDate: Date,
            progress: @escaping (ActivationPhase) -> Void,
            completion: @escaping ActivationCompletion
        ) {
            self.candidate = candidate
            self.requestedStartDate = requestedStartDate
            self.progress = progress
            self.completion = completion
        }
    }

    private final class BackfillRequest {
        let peripheralIdentifier: UUID
        let minimumTimeOffset: UInt16?
        let completion: BackfillCompletion
        var supportsE2ECRC: Bool?
        var measurementNotificationsEnabled = false
        var recordAccessIndicationsEnabled = false
        var commandStarted = false
        var records: [UInt16: SmartCGMMeasurement] = [:]

        init(
            peripheralIdentifier: UUID,
            minimumTimeOffset: UInt16?,
            completion: @escaping BackfillCompletion
        ) {
            self.peripheralIdentifier = peripheralIdentifier
            self.minimumTimeOffset = minimumTimeOffset
            self.completion = completion
        }
    }

    private static let cgmService = CBUUID(string: "181F")
    private static let cgmMeasurement = CBUUID(string: "2AA7")
    private static let cgmFeature = CBUUID(string: "2AA8")
    private static let cgmStatus = CBUUID(string: "2AA9")
    private static let cgmSessionStartTime = CBUUID(string: "2AAA")
    private static let cgmSpecificOpsControlPoint = CBUUID(string: "2AAC")
    private static let recordAccessControlPoint = CBUUID(string: "2A52")
    static let managerRestorationIdentifier = "com.nightscout.Trio.smartCGMScanner.manager"
    /// Smart normally advertises once per minute. Waiting slightly longer than
    /// that before rebuilding a stale scan avoids unnecessary radio restarts
    /// while still recovering well inside Trio's four-minute delivery cadence.
    private static let scanRefreshInterval: TimeInterval = 75
    private static let backfillTimeout: TimeInterval = 60
    private static let activationDiscoveryTimeout: TimeInterval = 90
    private static let activationTimeout: TimeInterval = 60
    private static let maximumBackfillRecords = 512

    private let managerQueue = DispatchQueue(label: "com.nightscout.Trio.smartCGMScanner")
    private let readingHandler: ReadingHandler
    private let restorationIdentifier: String?
    private var centralManager: CBCentralManager!
    private var shouldScan = true
    private var refreshWorkItem: DispatchWorkItem?
    private var lastDiscoveryDate: Date?
    private var knownPeripherals: [UUID: CBPeripheral] = [:]
    private var advertisementDeduplicator = SmartAdvertisementDeduplicator()
    private var candidateDiscoveryRequest: CandidateDiscoveryRequest?
    private var candidateDiscoveryTimeoutWorkItem: DispatchWorkItem?
    private var activationRequest: ActivationRequest?
    private var activationPeripheral: CBPeripheral?
    private var activationFeatureCharacteristic: CBCharacteristic?
    private var activationStatusCharacteristic: CBCharacteristic?
    private var activationSessionStartTimeCharacteristic: CBCharacteristic?
    private var activationControlPointCharacteristic: CBCharacteristic?
    private var activationTimeoutWorkItem: DispatchWorkItem?
    private var backfillRequest: BackfillRequest?
    private var backfillPeripheral: CBPeripheral?
    private var backfillMeasurementCharacteristic: CBCharacteristic?
    private var backfillFeatureCharacteristic: CBCharacteristic?
    private var backfillRecordAccessCharacteristic: CBCharacteristic?
    private var backfillTimeoutWorkItem: DispatchWorkItem?

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
            if self.candidateDiscoveryRequest != nil {
                self.finishCandidateDiscovery(.failure(ActivationError.cancelled))
            }
            if self.activationRequest != nil {
                self.finishActivation(.failure(ActivationError.cancelled))
            }
            if self.backfillRequest != nil {
                self.finishBackfill(.failure(BackfillError.cancelled))
            }
        }
    }

    func discoverActivationCandidate(
        excluding peripheralIdentifier: UUID,
        completion: @escaping CandidateCompletion
    ) {
        managerQueue.async {
            guard
                self.candidateDiscoveryRequest == nil,
                self.activationRequest == nil,
                self.backfillRequest == nil
            else {
                completion(.failure(ActivationError.alreadyRunning))
                return
            }
            guard self.centralManager?.state == .poweredOn else {
                completion(.failure(ActivationError.bluetoothUnavailable))
                return
            }

            self.candidateDiscoveryRequest = CandidateDiscoveryRequest(
                excludedPeripheralIdentifier: peripheralIdentifier,
                completion: completion
            )
            self.lastDiscoveryDate = nil
            self.centralManager.stopScan()
            self.startScanningIfPossible()

            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.candidateDiscoveryRequest != nil else { return }
                self.finishCandidateDiscovery(.failure(ActivationError.sensorUnavailable))
            }
            self.candidateDiscoveryTimeoutWorkItem = timeout
            self.managerQueue.asyncAfter(
                deadline: .now() + Self.activationDiscoveryTimeout,
                execute: timeout
            )
        }
    }

    func cancelActivationDiscovery() {
        managerQueue.async {
            guard self.candidateDiscoveryRequest != nil else { return }
            self.finishCandidateDiscovery(.failure(ActivationError.cancelled))
        }
    }

    func activate(
        candidate: ActivationCandidate,
        startDate: Date = Date(),
        progress: @escaping (ActivationPhase) -> Void,
        completion: @escaping ActivationCompletion
    ) {
        managerQueue.async {
            guard
                self.activationRequest == nil,
                self.backfillRequest == nil,
                self.candidateDiscoveryRequest == nil
            else {
                completion(.failure(ActivationError.alreadyRunning))
                return
            }
            guard self.centralManager?.state == .poweredOn else {
                completion(.failure(ActivationError.bluetoothUnavailable))
                return
            }

            let peripheral = self.knownPeripherals[candidate.peripheralIdentifier] ??
                self.centralManager.retrievePeripherals(
                    withIdentifiers: [candidate.peripheralIdentifier]
                ).first
            guard let peripheral else {
                completion(.failure(ActivationError.sensorUnavailable))
                return
            }

            self.refreshWorkItem?.cancel()
            self.refreshWorkItem = nil
            self.centralManager.stopScan()
            self.activationRequest = ActivationRequest(
                candidate: candidate,
                requestedStartDate: startDate,
                progress: progress,
                completion: completion
            )
            self.activationPeripheral = peripheral
            self.activationFeatureCharacteristic = nil
            self.activationStatusCharacteristic = nil
            self.activationSessionStartTimeCharacteristic = nil
            self.activationControlPointCharacteristic = nil
            peripheral.delegate = self

            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.activationRequest != nil else { return }
                self.finishActivationPreservingConfirmedStart(
                    fallbackError: ActivationError.timedOut
                )
            }
            self.activationTimeoutWorkItem = timeout
            self.managerQueue.asyncAfter(
                deadline: .now() + Self.activationTimeout,
                execute: timeout
            )
            progress(.connecting)
            self.centralManager.connect(peripheral)
        }
    }

    func cancelActivation() {
        managerQueue.async {
            guard self.activationRequest != nil else { return }
            self.finishActivation(.failure(ActivationError.cancelled))
        }
    }

    func requestBackfill(
        peripheralIdentifier: UUID,
        minimumTimeOffset: UInt16?,
        completion: @escaping BackfillCompletion
    ) {
        managerQueue.async {
            guard
                self.backfillRequest == nil,
                self.activationRequest == nil,
                self.candidateDiscoveryRequest == nil
            else {
                completion(.failure(BackfillError.alreadyRunning))
                return
            }
            guard self.centralManager?.state == .poweredOn else {
                completion(.failure(BackfillError.bluetoothUnavailable))
                return
            }

            let peripheral = self.knownPeripherals[peripheralIdentifier] ??
                self.centralManager.retrievePeripherals(
                    withIdentifiers: [peripheralIdentifier]
                ).first
            guard let peripheral else {
                completion(.failure(BackfillError.sensorUnavailable))
                return
            }

            self.refreshWorkItem?.cancel()
            self.refreshWorkItem = nil
            self.centralManager.stopScan()

            self.backfillRequest = BackfillRequest(
                peripheralIdentifier: peripheralIdentifier,
                minimumTimeOffset: minimumTimeOffset,
                completion: completion
            )
            self.backfillPeripheral = peripheral
            self.backfillMeasurementCharacteristic = nil
            self.backfillFeatureCharacteristic = nil
            self.backfillRecordAccessCharacteristic = nil
            peripheral.delegate = self

            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.backfillRequest != nil else { return }
                self.finishBackfill(.failure(BackfillError.timedOut))
            }
            self.backfillTimeoutWorkItem = timeout
            self.managerQueue.asyncAfter(
                deadline: .now() + Self.backfillTimeout,
                execute: timeout
            )
            self.centralManager.connect(peripheral)
        }
    }

    private func startScanningIfPossible() {
        guard
            shouldScan,
            backfillRequest == nil,
            activationRequest == nil,
            centralManager?.state == .poweredOn,
            centralManager?.isScanning == false
        else {
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
    private func scheduleScanRefreshIfNeeded(after delay: TimeInterval? = nil) {
        guard
            shouldScan,
            backfillRequest == nil,
            activationRequest == nil,
            centralManager?.state == .poweredOn,
            refreshWorkItem == nil
        else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard
                let self,
                self.shouldScan,
                self.backfillRequest == nil,
                self.activationRequest == nil,
                self.centralManager?.state == .poweredOn
            else {
                return
            }
            self.refreshWorkItem = nil

            // When iOS is already delivering duplicate advertisements, keep the
            // existing scan alive instead of restarting the radio discovery.
            if let lastDiscoveryDate = self.lastDiscoveryDate {
                let elapsed = Date().timeIntervalSince(lastDiscoveryDate)
                if elapsed < Self.scanRefreshInterval {
                    self.scheduleScanRefreshIfNeeded(
                        after: Self.scanRefreshInterval - elapsed
                    )
                    return
                }
            }

            self.centralManager?.stopScan()
            self.startScanningIfPossible()
            self.scheduleScanRefreshIfNeeded()
        }
        refreshWorkItem = workItem
        managerQueue.asyncAfter(
            deadline: .now() + (delay ?? Self.scanRefreshInterval),
            execute: workItem
        )
    }

    private func finishCandidateDiscovery(
        _ result: Result<ActivationCandidate, Error>
    ) {
        guard let request = candidateDiscoveryRequest else { return }
        candidateDiscoveryTimeoutWorkItem?.cancel()
        candidateDiscoveryTimeoutWorkItem = nil
        candidateDiscoveryRequest = nil
        request.completion(result)
        scheduleScanRefreshIfNeeded()
    }

    private func startActivationIfReady() {
        guard
            let request = activationRequest,
            let supportsE2ECRC = request.supportsE2ECRC,
            let status = request.status,
            request.controlPointIndicationsEnabled,
            !request.commandStarted,
            let peripheral = activationPeripheral,
            let controlPoint = activationControlPointCharacteristic
        else {
            return
        }

        // Starting a CGM session can erase records belonging to the previous
        // session. Only a sensor that explicitly reports a stopped session is
        // eligible, and the configured sensor is excluded before discovery.
        guard status.isSessionStopped else {
            finishActivation(.failure(ActivationError.currentSessionIsActive))
            return
        }

        request.commandStarted = true
        request.progress(.startingSession)
        peripheral.writeValue(
            SmartCGMSpecificOpsControlPoint.startSessionCommand(
                supportsE2ECRC: supportsE2ECRC
            ),
            for: controlPoint,
            type: .withResponse
        )
    }

    private func finishActivation(_ result: Result<ActivationResult, Error>) {
        guard let request = activationRequest else { return }
        let peripheral = activationPeripheral

        activationTimeoutWorkItem?.cancel()
        activationTimeoutWorkItem = nil
        activationRequest = nil
        activationPeripheral = nil
        activationFeatureCharacteristic = nil
        activationStatusCharacteristic = nil
        activationSessionStartTimeCharacteristic = nil
        activationControlPointCharacteristic = nil

        if let peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        request.completion(result)
        startScanningIfPossible()
        scheduleScanRefreshIfNeeded()
    }

    /// Once the sensor has acknowledged the start-session command, it has
    /// already begun its warmup even if the optional clock write or the final
    /// disconnect callback fails. Preserve that confirmed activation so Trio
    /// can monitor the pending sensor and derive its timestamps from the
    /// advertisement minute counter instead of leaving an activated sensor
    /// unreachable to the handover flow.
    private func finishActivationPreservingConfirmedStart(
        fallbackError: ActivationError
    ) {
        guard
            let request = activationRequest,
            let confirmedSessionStartDate = request.confirmedSessionStartDate
        else {
            finishActivation(.failure(fallbackError))
            return
        }

        finishActivation(
            .success(
                ActivationResult(
                    peripheralIdentifier: request.candidate.peripheralIdentifier,
                    localName: request.candidate.localName,
                    sessionStartDate: confirmedSessionStartDate
                )
            )
        )
    }

    private func startBackfillIfReady() {
        guard
            let request = backfillRequest,
            request.supportsE2ECRC != nil,
            request.measurementNotificationsEnabled,
            request.recordAccessIndicationsEnabled,
            !request.commandStarted,
            let peripheral = backfillPeripheral,
            let recordAccessCharacteristic = backfillRecordAccessCharacteristic
        else {
            return
        }

        request.commandStarted = true
        peripheral.writeValue(
            SmartRecordAccessControlPoint.reportStoredRecords(
                from: request.minimumTimeOffset
            ),
            for: recordAccessCharacteristic,
            type: .withResponse
        )
    }

    private func finishBackfill(_ result: Result<[SmartCGMMeasurement], Error>) {
        guard let request = backfillRequest else { return }
        let peripheral = backfillPeripheral

        backfillTimeoutWorkItem?.cancel()
        backfillTimeoutWorkItem = nil
        backfillRequest = nil
        backfillPeripheral = nil
        backfillMeasurementCharacteristic = nil
        backfillFeatureCharacteristic = nil
        backfillRecordAccessCharacteristic = nil

        if let peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        request.completion(result)
        startScanningIfPossible()
        scheduleScanRefreshIfNeeded()
    }
}

extension SmartAdvertisementScanner: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn, candidateDiscoveryRequest != nil {
            finishCandidateDiscovery(.failure(ActivationError.bluetoothUnavailable))
        }
        if central.state != .poweredOn, activationRequest != nil {
            finishActivation(.failure(ActivationError.bluetoothUnavailable))
        }
        if central.state != .poweredOn, backfillRequest != nil {
            finishBackfill(.failure(BackfillError.bluetoothUnavailable))
        }
        if central.state == .poweredOn {
            startScanningIfPossible()
            scheduleScanRefreshIfNeeded()
        } else {
            refreshWorkItem?.cancel()
            refreshWorkItem = nil
        }
    }

    func centralManager(
        _: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let receivedAt = Date()
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        lastDiscoveryDate = receivedAt
        knownPeripherals[peripheral.identifier] = peripheral

        if let discovery = candidateDiscoveryRequest,
           peripheral.identifier != discovery.excludedPeripheralIdentifier
        {
            finishCandidateDiscovery(
                .success(
                    ActivationCandidate(
                        peripheralIdentifier: peripheral.identifier,
                        localName: localName,
                        rssi: RSSI.intValue
                    )
                )
            )
        }

        guard
            let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
            let advertisement = SmartAdvertisement(manufacturerData: manufacturerData)
        else {
            return
        }

        guard advertisementDeduplicator.shouldForward(
            peripheralIdentifier: peripheral.identifier,
            advertisement: advertisement
        ) else {
            return
        }

        readingHandler(
            Reading(
                peripheralIdentifier: peripheral.identifier,
                localName: localName,
                rssi: RSSI.intValue,
                receivedAt: receivedAt,
                advertisement: advertisement
            )
        )
    }

    func centralManager(_ central: CBCentralManager, willRestoreState state: [String: Any]) {
        // A manual backfill request is intentionally not persisted. If iOS
        // restores the app while an old connection still exists, close it
        // immediately so it cannot become an orphaned battery drain.
        let restoredPeripherals = state[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for peripheral in restoredPeripherals {
            knownPeripherals[peripheral.identifier] = peripheral
            central.cancelPeripheralConnection(peripheral)
        }
        startScanningIfPossible()
    }

    func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if peripheral.identifier == activationRequest?.candidate.peripheralIdentifier {
            activationRequest?.progress(.checkingSensor)
            peripheral.discoverServices([Self.cgmService])
        } else if peripheral.identifier == backfillRequest?.peripheralIdentifier {
            peripheral.discoverServices([Self.cgmService])
        }
    }

    func centralManager(
        _: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error _: Error?
    ) {
        if peripheral.identifier == activationRequest?.candidate.peripheralIdentifier {
            finishActivationPreservingConfirmedStart(
                fallbackError: ActivationError.connectionFailed
            )
        } else if peripheral.identifier == backfillRequest?.peripheralIdentifier {
            finishBackfill(.failure(BackfillError.connectionFailed))
        }
    }

    func centralManager(
        _: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error _: Error?
    ) {
        if peripheral.identifier == activationRequest?.candidate.peripheralIdentifier {
            finishActivationPreservingConfirmedStart(
                fallbackError: ActivationError.connectionFailed
            )
        } else if peripheral.identifier == backfillRequest?.peripheralIdentifier {
            finishBackfill(.failure(BackfillError.connectionFailed))
        }
    }
}

extension SmartAdvertisementScanner: CBPeripheralDelegate {
    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        if peripheral.identifier == activationRequest?.candidate.peripheralIdentifier {
            guard error == nil else {
                finishActivation(.failure(ActivationError.serviceUnavailable))
                return
            }
            guard let service = peripheral.services?.first(where: {
                $0.uuid == Self.cgmService
            }) else {
                finishActivation(.failure(ActivationError.serviceUnavailable))
                return
            }
            peripheral.discoverCharacteristics(
                [
                    Self.cgmFeature,
                    Self.cgmStatus,
                    Self.cgmSessionStartTime,
                    Self.cgmSpecificOpsControlPoint
                ],
                for: service
            )
            return
        }

        guard peripheral.identifier == backfillRequest?.peripheralIdentifier else { return }
        guard error == nil else {
            finishBackfill(.failure(BackfillError.serviceUnavailable))
            return
        }
        guard let service = peripheral.services?.first(where: {
            $0.uuid == Self.cgmService
        }) else {
            finishBackfill(.failure(BackfillError.serviceUnavailable))
            return
        }

        peripheral.discoverCharacteristics(
            [
                Self.cgmMeasurement,
                Self.cgmFeature,
                Self.recordAccessControlPoint
            ],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if peripheral.identifier == activationRequest?.candidate.peripheralIdentifier {
            guard error == nil, service.uuid == Self.cgmService else {
                finishActivation(.failure(ActivationError.characteristicsUnavailable))
                return
            }

            activationFeatureCharacteristic = service.characteristics?.first {
                $0.uuid == Self.cgmFeature
            }
            activationStatusCharacteristic = service.characteristics?.first {
                $0.uuid == Self.cgmStatus
            }
            activationSessionStartTimeCharacteristic = service.characteristics?.first {
                $0.uuid == Self.cgmSessionStartTime
            }
            activationControlPointCharacteristic = service.characteristics?.first {
                $0.uuid == Self.cgmSpecificOpsControlPoint
            }

            guard
                let feature = activationFeatureCharacteristic,
                let status = activationStatusCharacteristic,
                let controlPoint = activationControlPointCharacteristic,
                activationSessionStartTimeCharacteristic != nil
            else {
                finishActivation(.failure(ActivationError.characteristicsUnavailable))
                return
            }

            peripheral.readValue(for: feature)
            peripheral.readValue(for: status)
            peripheral.setNotifyValue(true, for: controlPoint)
            return
        }

        guard peripheral.identifier == backfillRequest?.peripheralIdentifier else { return }
        guard error == nil, service.uuid == Self.cgmService else {
            finishBackfill(.failure(BackfillError.characteristicsUnavailable))
            return
        }

        backfillMeasurementCharacteristic = service.characteristics?.first {
            $0.uuid == Self.cgmMeasurement
        }
        backfillFeatureCharacteristic = service.characteristics?.first {
            $0.uuid == Self.cgmFeature
        }
        backfillRecordAccessCharacteristic = service.characteristics?.first {
            $0.uuid == Self.recordAccessControlPoint
        }

        guard
            let measurement = backfillMeasurementCharacteristic,
            let feature = backfillFeatureCharacteristic,
            let recordAccess = backfillRecordAccessCharacteristic
        else {
            finishBackfill(.failure(BackfillError.characteristicsUnavailable))
            return
        }

        peripheral.readValue(for: feature)
        peripheral.setNotifyValue(true, for: measurement)
        peripheral.setNotifyValue(true, for: recordAccess)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if peripheral.identifier == activationRequest?.candidate.peripheralIdentifier {
            guard
                characteristic.uuid == Self.cgmSpecificOpsControlPoint,
                error == nil,
                characteristic.isNotifying
            else {
                finishActivation(.failure(ActivationError.characteristicsUnavailable))
                return
            }
            activationRequest?.controlPointIndicationsEnabled = true
            startActivationIfReady()
            return
        }

        guard peripheral.identifier == backfillRequest?.peripheralIdentifier else { return }
        guard error == nil, characteristic.isNotifying else {
            finishBackfill(.failure(BackfillError.characteristicsUnavailable))
            return
        }

        if characteristic.uuid == Self.cgmMeasurement {
            backfillRequest?.measurementNotificationsEnabled = true
        } else if characteristic.uuid == Self.recordAccessControlPoint {
            backfillRequest?.recordAccessIndicationsEnabled = true
        }
        startBackfillIfReady()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if peripheral.identifier == activationRequest?.candidate.peripheralIdentifier {
            guard error == nil, let data = characteristic.value else {
                finishActivation(.failure(ActivationError.connectionFailed))
                return
            }

            switch characteristic.uuid {
            case Self.cgmFeature:
                guard let feature = SmartCGMFeature(data: data) else {
                    finishActivation(.failure(ActivationError.invalidFeature))
                    return
                }
                activationRequest?.supportsE2ECRC = feature.supportsE2ECRC
                if activationRequest?.status == nil,
                   let status = activationStatusCharacteristic
                {
                    peripheral.readValue(for: status)
                }
                startActivationIfReady()

            case Self.cgmStatus:
                guard let supportsE2ECRC = activationRequest?.supportsE2ECRC else {
                    // Feature and Status reads may arrive in either order. Read
                    // Status again after Feature so CRC requirements are known.
                    if let status = activationStatusCharacteristic {
                        peripheral.readValue(for: status)
                    }
                    return
                }
                do {
                    activationRequest?.status = try SmartCGMStatus(
                        data: data,
                        supportsE2ECRC: supportsE2ECRC
                    )
                    startActivationIfReady()
                } catch {
                    finishActivation(.failure(ActivationError.invalidStatus))
                }

            case Self.cgmSpecificOpsControlPoint:
                guard
                    let request = activationRequest,
                    request.commandStarted,
                    let supportsE2ECRC = request.supportsE2ECRC,
                    let sessionStartTime = activationSessionStartTimeCharacteristic
                else {
                    return
                }
                do {
                    try SmartCGMSpecificOpsControlPoint.validateStartSessionResponse(
                        data,
                        supportsE2ECRC: supportsE2ECRC
                    )
                    let confirmedStartDate = Date()
                    request.confirmedSessionStartDate = confirmedStartDate
                    request.isWritingSessionStartTime = true
                    request.progress(.synchronizingTime)
                    peripheral.writeValue(
                        SmartCGMSessionStartTime.data(
                            date: confirmedStartDate,
                            timeZone: .current,
                            supportsE2ECRC: supportsE2ECRC
                        ),
                        for: sessionStartTime,
                        type: .withResponse
                    )
                } catch let responseError as SmartCGMSpecificOpsControlPoint.ResponseError {
                    if case let .failed(code) = responseError {
                        finishActivation(.failure(ActivationError.startSessionFailed(code)))
                    } else {
                        finishActivation(.failure(ActivationError.startSessionFailed(nil)))
                    }
                } catch {
                    finishActivation(.failure(ActivationError.startSessionFailed(nil)))
                }

            default:
                break
            }
            return
        }

        guard
            peripheral.identifier == backfillRequest?.peripheralIdentifier,
            error == nil,
            let data = characteristic.value
        else {
            if backfillRequest != nil {
                finishBackfill(.failure(BackfillError.invalidMeasurement))
            }
            return
        }

        switch characteristic.uuid {
        case Self.cgmFeature:
            guard let feature = SmartCGMFeature(data: data) else {
                finishBackfill(.failure(BackfillError.invalidFeature))
                return
            }
            backfillRequest?.supportsE2ECRC = feature.supportsE2ECRC
            startBackfillIfReady()

        case Self.cgmMeasurement:
            guard
                let request = backfillRequest,
                request.commandStarted,
                let supportsE2ECRC = request.supportsE2ECRC
            else {
                return
            }
            do {
                for record in try SmartCGMMeasurement.records(
                    from: data,
                    supportsE2ECRC: supportsE2ECRC
                ) where request.minimumTimeOffset.map({
                    record.timeOffset >= $0
                }) ?? true {
                    if request.records[record.timeOffset] != nil ||
                        request.records.count < Self.maximumBackfillRecords
                    {
                        request.records[record.timeOffset] = record
                    }
                }
            } catch {
                finishBackfill(.failure(BackfillError.invalidMeasurement))
            }

        case Self.recordAccessControlPoint:
            guard
                let request = backfillRequest,
                let response = SmartRecordAccessControlPoint.response(from: data)
            else {
                return
            }
            guard case let .completion(requestOpcode, responseCode) = response,
                  requestOpcode == 0x01
            else {
                return
            }

            if responseCode == 0x01 || responseCode == 0x06 {
                let records = request.records.values.sorted {
                    $0.timeOffset < $1.timeOffset
                }
                finishBackfill(.success(records))
            } else {
                finishBackfill(
                    .failure(BackfillError.recordAccessFailed(responseCode))
                )
            }

        default:
            break
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if peripheral.identifier == activationRequest?.candidate.peripheralIdentifier {
            if characteristic.uuid == Self.cgmSpecificOpsControlPoint {
                if error != nil {
                    finishActivation(.failure(ActivationError.startSessionFailed(nil)))
                }
                return
            }
            if characteristic.uuid == Self.cgmSessionStartTime,
               let request = activationRequest,
               request.isWritingSessionStartTime
            {
                guard error == nil else {
                    finishActivationPreservingConfirmedStart(
                        fallbackError: ActivationError.timeSynchronizationFailed
                    )
                    return
                }
                let startDate = request.confirmedSessionStartDate ?? request.requestedStartDate
                finishActivation(
                    .success(
                        ActivationResult(
                            peripheralIdentifier: request.candidate.peripheralIdentifier,
                            localName: request.candidate.localName,
                            sessionStartDate: startDate
                        )
                    )
                )
                return
            }
        }

        guard
            peripheral.identifier == backfillRequest?.peripheralIdentifier,
            characteristic.uuid == Self.recordAccessControlPoint
        else {
            return
        }
        if error != nil {
            finishBackfill(.failure(BackfillError.connectionFailed))
        }
    }
}

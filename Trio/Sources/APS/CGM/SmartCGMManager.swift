import Foundation
import HealthKit
import LoopKit
import LoopKitUI
import MicroTechCGMKit
import UIKit

private struct SmartManagerState: Equatable {
    let serial: String
    var lastReceivedMinute: UInt16?
    var lastPublishedMinute: UInt16?
    var latestGlucoseMgDL: Double?
    var latestTrendMgDLPerMinute: Double?
    var latestReadingDate: Date?
    var lastCommunicationDate: Date?
    var uploadReadings: Bool

    init(serial: String) {
        self.serial = serial
        uploadReadings = true
    }

    init?(rawValue: DeviceManager.RawStateValue) {
        guard let serialValue = rawValue["serial"] as? String,
              let serial = try? MicroTechSensorSerial(serialValue)
        else {
            return nil
        }

        self.init(serial: serial.normalizedValue)
        if let value = rawValue["lastReceivedMinute"] as? Int {
            lastReceivedMinute = UInt16(exactly: value)
        }
        if let value = rawValue["lastPublishedMinute"] as? Int {
            lastPublishedMinute = UInt16(exactly: value)
        }
        latestGlucoseMgDL = rawValue["latestGlucoseMgDL"] as? Double
        latestTrendMgDLPerMinute = rawValue["latestTrendMgDLPerMinute"] as? Double
        if let value = rawValue["latestReadingDate"] as? TimeInterval {
            latestReadingDate = Date(timeIntervalSince1970: value)
        }
        if let value = rawValue["lastCommunicationDate"] as? TimeInterval {
            lastCommunicationDate = Date(timeIntervalSince1970: value)
        }
        uploadReadings = rawValue["uploadReadings"] as? Bool ?? true
    }

    var rawValue: DeviceManager.RawStateValue {
        var rawValue: DeviceManager.RawStateValue = [
            "serial": serial,
            "uploadReadings": uploadReadings
        ]
        rawValue["lastReceivedMinute"] = lastReceivedMinute.map(Int.init)
        rawValue["lastPublishedMinute"] = lastPublishedMinute.map(Int.init)
        rawValue["latestGlucoseMgDL"] = latestGlucoseMgDL
        rawValue["latestTrendMgDLPerMinute"] = latestTrendMgDLPerMinute
        rawValue["latestReadingDate"] = latestReadingDate?.timeIntervalSince1970
        rawValue["lastCommunicationDate"] = lastCommunicationDate?.timeIntervalSince1970
        return rawValue
    }
}

private struct SmartGlucoseDisplay: GlucoseDisplayable {
    let glucoseMgDL: Double
    let trendMgDLPerMinute: Double

    var isStateValid: Bool {
        (20 ... 600).contains(glucoseMgDL)
    }

    var trendType: GlucoseTrend? {
        SmartCGMManager.trendType(for: trendMgDLPerMinute)
    }

    var trendRate: HKQuantity? {
        HKQuantity(
            unit: .milligramsPerDeciliterPerMinute,
            doubleValue: trendMgDLPerMinute
        )
    }

    var isLocal: Bool {
        true
    }

    var glucoseRangeCategory: GlucoseRangeCategory? {
        nil
    }
}

private struct SmartStatusHighlight: DeviceStatusHighlight {
    let localizedMessage: String
    let imageName: String
    let state: DeviceStatusHighlightState
}

final class SmartCGMManager: CGMManagerUI {
    static let pluginIdentifier = "SmartCGMManager"
    static var onboardingImage: UIImage? {
        UIImage(systemName: "wave.3.right.circle")
    }

    let localizedTitle = String(localized: "SMART MedLevensohn 2.0")
    let isOnboarded = true
    let providesBLEHeartbeat = true
    let managedDataInterval: TimeInterval? = .hours(3)
    let appURL: URL? = nil

    private static let bluetoothRestorationIdentifier =
        "org.nightscout.trio.smart-cgm.central"

    private let serial: MicroTechSensorSerial
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let stateQueue = DispatchQueue(
        label: "org.nightscout.trio.smart-cgm.state"
    )
    private let delegate = WeakSynchronizedDelegate<CGMManagerDelegate>()
    private let keychain = KeychainManager()
    private let transport: MicroTechBluetoothTransport

    private var state: SmartManagerState
    private var coordinator: MicroTechConnectionCoordinator
    private var retryWorkItem: DispatchWorkItem?
    private var timeoutWorkItem: DispatchWorkItem?

    var cgmManagerDelegate: CGMManagerDelegate? {
        get {
            delegate.delegate
        }
        set {
            delegate.delegate = newValue
        }
    }

    var delegateQueue: DispatchQueue! {
        get {
            delegate.queue
        }
        set {
            delegate.queue = newValue
        }
    }

    var shouldSyncToRemoteService: Bool {
        stateValue { $0.uploadReadings }
    }

    var uploadReadings: Bool {
        get {
            shouldSyncToRemoteService
        }
        set {
            stateQueue.async { [weak self] in
                guard let self, state.uploadReadings != newValue else {
                    return
                }
                state.uploadReadings = newValue
                notifyStateChanged(persistedStateChanged: true, statusChanged: false)
            }
        }
    }

    var glucoseDisplay: GlucoseDisplayable? {
        stateValue { state in
            guard let glucose = state.latestGlucoseMgDL,
                  let trend = state.latestTrendMgDLPerMinute
            else {
                return nil
            }
            return SmartGlucoseDisplay(
                glucoseMgDL: glucose,
                trendMgDLPerMinute: trend
            )
        }
    }

    var cgmManagerStatus: CGMManagerStatus {
        stateValue { state in
            CGMManagerStatus(
                hasValidSensorSession: true,
                lastCommunicationDate: state.lastCommunicationDate,
                device: device
            )
        }
    }

    var smallImage: UIImage? {
        UIImage(systemName: "wave.3.right.circle.fill")
    }

    var cgmStatusHighlight: DeviceStatusHighlight? {
        let snapshot = stateAndConnectionValue { state, connection in
            (state.lastCommunicationDate, connection)
        }

        if let lastCommunication = snapshot.0,
           lastCommunication.timeIntervalSinceNow < -.minutes(15)
        {
            return SmartStatusHighlight(
                localizedMessage: String(localized: "SMART\nSignal Loss"),
                imageName: "exclamationmark.circle.fill",
                state: .warning
            )
        }

        switch snapshot.1 {
        case .failed:
            return SmartStatusHighlight(
                localizedMessage: String(localized: "SMART\nUnavailable"),
                imageName: "exclamationmark.circle.fill",
                state: .warning
            )
        case .streaming:
            return nil
        default:
            return SmartStatusHighlight(
                localizedMessage: String(localized: "Connecting\nSMART"),
                imageName: "dot.radiowaves.left.and.right",
                state: .normalCGM
            )
        }
    }

    var cgmLifecycleProgress: DeviceLifecycleProgress? {
        nil
    }

    var cgmStatusBadge: DeviceStatusBadge? {
        nil
    }

    var rawState: DeviceManager.RawStateValue {
        stateValue(\.rawValue)
    }

    var debugDescription: String {
        stateAndConnectionValue { state, connection in
            [
                "## SmartCGMManager",
                "serial: \(state.serial)",
                "connection: \(connection)",
                "lastReceivedMinute: \(String(describing: state.lastReceivedMinute))",
                "lastPublishedMinute: \(String(describing: state.lastPublishedMinute))",
                "latestReadingDate: \(String(describing: state.latestReadingDate))",
                "lastCommunicationDate: \(String(describing: state.lastCommunicationDate))",
                "masterKey: <stored in Keychain>"
            ].joined(separator: "\n")
        }
    }

    var maskedSerial: String {
        "••••••\(serial.normalizedValue.suffix(4))"
    }

    var sensorName: String {
        serial.normalizedValue
    }

    var lastCommunicationDate: Date? {
        stateValue(\.lastCommunicationDate)
    }

    var connectionDescription: String {
        stateAndConnectionValue { _, connection in
            switch connection {
            case .idle:
                return String(localized: "Stopped")
            case .scanning:
                return String(localized: "Searching for SMART sensor")
            case .connecting:
                return String(localized: "Connecting")
            case .discovering:
                return String(localized: "Discovering services")
            case .subscribingKeyExchange,
                 .subscribingLiveBeforeCommand,
                 .subscribingCommand,
                 .requestingMasterKey,
                 .requestingSessionKey,
                 .subscribingLiveAfterAuthentication:
                return String(localized: "Authenticating")
            case .synchronizing, .backfilling:
                return String(localized: "Synchronizing")
            case .streaming:
                return String(localized: "Receiving live glucose")
            case let .waitingToRetry(attempt, _):
                return String(localized: "Reconnecting (attempt \(attempt))")
            case .failed:
                return String(localized: "Connection failed")
            }
        }
    }

    convenience init?(serialValue: String) {
        guard let serial = try? MicroTechSensorSerial(serialValue) else {
            return nil
        }
        self.init(serial: serial, state: SmartManagerState(serial: serial.normalizedValue))
    }

    required convenience init?(rawState: DeviceManager.RawStateValue) {
        guard let state = SmartManagerState(rawValue: rawState),
              let serial = try? MicroTechSensorSerial(state.serial)
        else {
            return nil
        }
        self.init(serial: serial, state: state)
    }

    private init(serial: MicroTechSensorSerial, state: SmartManagerState) {
        self.serial = serial
        self.state = state

        let masterKey = Self.loadMasterKey(serial: serial)
        coordinator = MicroTechConnectionCoordinator(
            serial: serial,
            masterKey: masterKey,
            lastReceivedMinute: state.lastReceivedMinute,
            lastPublishedMinute: state.lastPublishedMinute,
            synchronizationMode: .liveOnly
        )

        let driver = MicroTechCoreBluetoothDriver(
            restorationIdentifier: Self.bluetoothRestorationIdentifier,
            restoredPeripheralLocalName: "Smart-\(serial.normalizedValue)"
        )
        transport = MicroTechBluetoothTransport(driver: driver)

        stateQueue.setSpecific(key: queueKey, value: 1)
        transport.eventHandler = { [weak self] event in
            self?.stateQueue.async {
                self?.process(event)
            }
        }
        stateQueue.async { [weak self] in
            self?.process(.start)
        }
    }

    deinit {
        retryWorkItem?.cancel()
        timeoutWorkItem?.cancel()
        transport.perform(.disconnect)
    }

    func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        stateQueue.async { [weak self] in
            guard let self else {
                completion(.noData)
                return
            }

            switch coordinator.state {
            case .idle, .failed:
                coordinator = makeCoordinator()
                process(.start)
            default:
                break
            }
            completion(.noData)
        }
    }

    func delete(completion: @escaping () -> Void) {
        stateQueue.async { [weak self] in
            guard let self else {
                completion()
                return
            }
            retryWorkItem?.cancel()
            timeoutWorkItem?.cancel()
            _ = coordinator.handle(.stop, using: transport)
            do {
                try keychain.deleteGenericPassword(
                    forService: Self.keychainService(for: serial)
                )
            } catch {
                log("Unable to delete SMART credential: \(error)", type: .error)
            }
            delegate.notify { delegate in
                delegate?.cgmManagerWantsDeletion(self)
                completion()
            }
        }
    }

    func acknowledgeAlert(
        alertIdentifier _: Alert.AlertIdentifier,
        completion: @escaping (Error?) -> Void
    ) {
        completion(nil)
    }

    func getSoundBaseURL() -> URL? {
        nil
    }

    func getSounds() -> [Alert.Sound] {
        []
    }

    private func makeCoordinator() -> MicroTechConnectionCoordinator {
        MicroTechConnectionCoordinator(
            serial: serial,
            masterKey: Self.loadMasterKey(serial: serial),
            lastReceivedMinute: state.lastReceivedMinute,
            lastPublishedMinute: state.lastPublishedMinute,
            synchronizationMode: .liveOnly
        )
    }

    private func process(_ event: MicroTechCoordinatorEvent) {
        dispatchPrecondition(condition: .onQueue(stateQueue))

        let previousConnectionState = coordinator.state
        let previousPersistentState = state
        let effects = coordinator.handle(event, using: transport)

        if case .valueReceived = event {
            state.lastCommunicationDate = Date()
        }

        for effect in effects {
            handle(effect)
        }

        state.lastReceivedMinute = coordinator.lastReceivedMinute
        state.lastPublishedMinute = coordinator.lastPublishedMinute

        let persistedStateChanged = previousPersistentState != state
        let statusChanged = previousConnectionState != coordinator.state ||
            previousPersistentState.lastCommunicationDate != state.lastCommunicationDate
        if persistedStateChanged || statusChanged {
            notifyStateChanged(
                persistedStateChanged: persistedStateChanged,
                statusChanged: statusChanged
            )
        }
        updateTimeout()
    }

    private func handle(_ effect: MicroTechCoordinatorEffect) {
        switch effect {
        case .transport:
            break
        case let .persistMasterKey(masterKey):
            do {
                try keychain.replaceGenericPassword(
                    Data(masterKey.keyBytes),
                    forService: Self.keychainService(for: serial)
                )
                log("SMART pairing credential stored securely.", type: .connection)
            } catch {
                log("Unable to store SMART pairing credential: \(error)", type: .error)
            }
        case .publishHistoryMinuteIndexes:
            // The Trio integration intentionally uses live-only mode until the
            // Brazilian SMART history response format is physically verified.
            break
        case let .publishLiveGlucose(packet):
            publish(packet)
        case let .discardedLivePacket(error):
            log("Discarded invalid SMART glucose packet: \(error)", type: .error)
        case let .scheduleRetry(_, delay):
            retryWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.process(.retryTimerFired)
            }
            retryWorkItem = workItem
            stateQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func publish(_ packet: MicroTechLiveGlucosePacket) {
        let glucose = Double(packet.processedGlucose.glucoseMgDL)
        guard (20 ... 600).contains(glucose) else {
            log("Discarded implausible SMART glucose value.", type: .error)
            delegate.notify { delegate in
                delegate?.cgmManager(self, hasNew: .unreliableData)
            }
            return
        }

        let readingDate = Date()
        let trendRate = packet.trendMgDLPerMinute
        state.latestGlucoseMgDL = glucose
        state.latestTrendMgDLPerMinute = trendRate
        state.latestReadingDate = readingDate
        state.lastCommunicationDate = readingDate

        let sample = NewGlucoseSample(
            date: readingDate,
            quantity: HKQuantity(
                unit: .milligramsPerDeciliter,
                doubleValue: glucose
            ),
            condition: nil,
            trend: Self.trendType(for: trendRate),
            trendRate: HKQuantity(
                unit: .milligramsPerDeciliterPerMinute,
                doubleValue: trendRate
            ),
            isDisplayOnly: false,
            wasUserEntered: false,
            syncIdentifier: "smart-\(serial.normalizedValue)-\(packet.minuteIndex)",
            device: device
        )

        log(
            "Received SMART glucose minute \(packet.minuteIndex): \(Int(glucose)) mg/dL.",
            type: .receive
        )
        delegate.notify { delegate in
            delegate?.cgmManager(self, hasNew: .newData([sample]))
        }
    }

    private func updateTimeout() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil

        switch coordinator.state {
        case .scanning,
             .connecting,
             .discovering,
             .subscribingKeyExchange,
             .subscribingLiveBeforeCommand,
             .subscribingCommand,
             .requestingMasterKey,
             .requestingSessionKey,
             .subscribingLiveAfterAuthentication,
             .synchronizing,
             .backfilling:
            let workItem = DispatchWorkItem { [weak self] in
                self?.process(.timeout)
            }
            timeoutWorkItem = workItem
            stateQueue.asyncAfter(deadline: .now() + 60, execute: workItem)
        case .idle, .streaming, .waitingToRetry, .failed:
            break
        }
    }

    private func notifyStateChanged(
        persistedStateChanged: Bool,
        statusChanged: Bool
    ) {
        delegate.notify { delegate in
            if persistedStateChanged {
                delegate?.cgmManagerDidUpdateState(self)
            }
            if statusChanged {
                delegate?.cgmManager(self, didUpdate: self.cgmManagerStatus)
            }
        }
    }

    private func log(_ message: String, type: DeviceLogEntryType) {
        delegate.notify { delegate in
            delegate?.deviceManager(
                self,
                logEventForDeviceIdentifier: self.maskedSerial,
                type: type,
                message: message,
                completion: nil
            )
        }
    }

    private var device: HKDevice {
        HKDevice(
            name: "SMART \(maskedSerial)",
            manufacturer: "MicroTech / MedLevensohn",
            model: "GX-01S",
            hardwareVersion: nil,
            firmwareVersion: nil,
            softwareVersion: nil,
            localIdentifier: serial.normalizedValue,
            udiDeviceIdentifier: nil
        )
    }

    private func stateValue<Value>(
        _ body: (SmartManagerState) -> Value
    ) -> Value {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return body(state)
        }
        return stateQueue.sync {
            body(state)
        }
    }

    private func stateAndConnectionValue<Value>(
        _ body: (SmartManagerState, MicroTechConnectionState) -> Value
    ) -> Value {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return body(state, coordinator.state)
        }
        return stateQueue.sync {
            body(state, coordinator.state)
        }
    }

    private static func keychainService(
        for serial: MicroTechSensorSerial
    ) -> String {
        "org.nightscout.trio.smart-cgm.master-key.\(serial.normalizedValue)"
    }

    private static func loadMasterKey(
        serial: MicroTechSensorSerial
    ) -> MicroTechSecret? {
        guard let data = try? KeychainManager().getGenericPasswordForServiceAsData(
            keychainService(for: serial)
        ) else {
            return nil
        }
        return try? MicroTechSecret(keyBytes: [UInt8](data))
    }

    fileprivate static func trendType(for rate: Double) -> GlucoseTrend {
        switch rate {
        case 3 ...:
            return .upUpUp
        case 2 ..< 3:
            return .upUp
        case 1 ..< 2:
            return .up
        case -1 ..< 1:
            return .flat
        case -2 ..< -1:
            return .down
        case -3 ..< -2:
            return .downDown
        default:
            return .downDownDown
        }
    }

    static func setupViewController(
        bluetoothProvider _: BluetoothProvider,
        displayGlucosePreference _: DisplayGlucosePreference,
        colorPalette _: LoopUIColorPalette,
        allowDebugFeatures _: Bool,
        prefersToSkipUserInteraction _: Bool
    ) -> SetupUIResult<CGMManagerViewController, CGMManagerUI> {
        .userInteractionRequired(SmartCGMUICoordinator())
    }

    func settingsViewController(
        bluetoothProvider _: BluetoothProvider,
        displayGlucosePreference _: DisplayGlucosePreference,
        colorPalette _: LoopUIColorPalette,
        allowDebugFeatures _: Bool
    ) -> CGMManagerViewController {
        SmartCGMUICoordinator(cgmManager: self)
    }
}

private final class SmartCGMUICoordinator: UINavigationController,
    CGMManagerOnboarding,
    CompletionNotifying
{
    weak var cgmManagerOnboardingDelegate: CGMManagerOnboardingDelegate?
    weak var completionDelegate: CompletionDelegate?

    private var cgmManager: SmartCGMManager?

    init(cgmManager: SmartCGMManager? = nil) {
        self.cgmManager = cgmManager
        super.init(navigationBarClass: UINavigationBar.self, toolbarClass: nil)
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationBar.prefersLargeTitles = true

        if let cgmManager {
            setViewControllers(
                [
                    SmartSettingsViewController(
                        cgmManager: cgmManager,
                        didFinish: { [weak self] in
                            guard let self else { return }
                            completionDelegate?.completionNotifyingDidComplete(self)
                        },
                        didDelete: { [weak self] in
                            self?.deleteManager()
                        }
                    )
                ],
                animated: false
            )
        } else {
            setViewControllers(
                [
                    SmartSetupViewController(
                        didContinue: { [weak self] serial in
                            self?.completeSetup(serial: serial)
                        },
                        didCancel: { [weak self] in
                            guard let self else { return }
                            completionDelegate?.completionNotifyingDidComplete(self)
                        }
                    )
                ],
                animated: false
            )
        }
    }

    private func completeSetup(serial: String) {
        guard let manager = SmartCGMManager(serialValue: serial) else {
            return
        }
        cgmManager = manager
        cgmManagerOnboardingDelegate?.cgmManagerOnboarding(
            didCreateCGMManager: manager
        )
        cgmManagerOnboardingDelegate?.cgmManagerOnboarding(
            didOnboardCGMManager: manager
        )
        completionDelegate?.completionNotifyingDidComplete(self)
    }

    private func deleteManager() {
        cgmManager?.delete { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                completionDelegate?.completionNotifyingDidComplete(self)
                dismiss(animated: true)
            }
        }
    }
}

private final class SmartSetupViewController: UIViewController, UITextFieldDelegate {
    private let didContinue: (String) -> Void
    private let didCancel: () -> Void
    private let serialTextField = UITextField()
    private let continueButton = UIButton(type: .system)

    init(
        didContinue: @escaping (String) -> Void,
        didCancel: @escaping () -> Void
    ) {
        self.didContinue = didContinue
        self.didCancel = didCancel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "SMART CGM")
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancel)
        )

        let introduction = UILabel()
        introduction.numberOfLines = 0
        introduction.font = .preferredFont(forTextStyle: .body)
        introduction.text = String(
            localized: "Enter the 10-character serial printed on the SMART MedLevensohn 2.0 sensor or package."
        )

        serialTextField.borderStyle = .roundedRect
        serialTextField.placeholder = String(localized: "10-character serial")
        serialTextField.autocapitalizationType = .allCharacters
        serialTextField.autocorrectionType = .no
        serialTextField.spellCheckingType = .no
        serialTextField.keyboardType = .asciiCapable
        serialTextField.textContentType = .none
        serialTextField.delegate = self
        serialTextField.addTarget(
            self,
            action: #selector(serialChanged),
            for: .editingChanged
        )

        let safety = UILabel()
        safety.numberOfLines = 0
        safety.font = .preferredFont(forTextStyle: .footnote)
        safety.textColor = .secondaryLabel
        safety.text = String(
            localized: "Compare SMART readings with the official app or a glucose meter before making treatment decisions."
        )

        continueButton.setTitle(String(localized: "Connect Sensor"), for: .normal)
        continueButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        continueButton.isEnabled = false
        continueButton.addTarget(
            self,
            action: #selector(connect),
            for: .touchUpInside
        )

        let stack = UIStackView(
            arrangedSubviews: [introduction, serialTextField, safety, continueButton]
        )
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: 20
            ),
            stack.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -20
            ),
            stack.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 24
            ),
            continueButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        serialTextField.becomeFirstResponder()
    }

    @objc private func serialChanged() {
        let normalized = String(
            (serialTextField.text ?? "")
                .uppercased()
                .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
                .prefix(MicroTechSensorSerial.requiredLength)
        )
        if serialTextField.text != normalized {
            serialTextField.text = normalized
        }
        continueButton.isEnabled =
            (try? MicroTechSensorSerial(normalized)) != nil
    }

    @objc private func connect() {
        guard let serial = serialTextField.text,
              (try? MicroTechSensorSerial(serial)) != nil
        else {
            return
        }
        didContinue(serial)
    }

    @objc private func cancel() {
        didCancel()
    }

    func textFieldShouldReturn(_: UITextField) -> Bool {
        if continueButton.isEnabled {
            connect()
        }
        return false
    }
}

private final class SmartSettingsViewController: UIViewController {
    private let cgmManager: SmartCGMManager
    private let didFinish: () -> Void
    private let didDelete: () -> Void
    private let connectionValue = UILabel()
    private let lastCommunicationValue = UILabel()
    private var refreshTimer: Timer?

    init(
        cgmManager: SmartCGMManager,
        didFinish: @escaping () -> Void,
        didDelete: @escaping () -> Void
    ) {
        self.cgmManager = cgmManager
        self.didFinish = didFinish
        self.didDelete = didDelete
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "SMART CGM")
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(finish)
        )

        let serialRow = valueRow(
            title: String(localized: "Sensor"),
            value: cgmManager.maskedSerial
        )
        let connectionRow = valueRow(
            title: String(localized: "Connection"),
            valueLabel: connectionValue
        )
        let communicationRow = valueRow(
            title: String(localized: "Last communication"),
            valueLabel: lastCommunicationValue
        )

        let uploadSwitch = UISwitch()
        uploadSwitch.isOn = cgmManager.uploadReadings
        uploadSwitch.addTarget(
            self,
            action: #selector(uploadChanged(_:)),
            for: .valueChanged
        )
        let uploadRow = controlRow(
            title: String(localized: "Upload readings"),
            control: uploadSwitch
        )

        let removeButton = UIButton(type: .system)
        removeButton.setTitle(String(localized: "Remove SMART Sensor"), for: .normal)
        removeButton.setTitleColor(.systemRed, for: .normal)
        removeButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        removeButton.addTarget(
            self,
            action: #selector(confirmDeletion),
            for: .touchUpInside
        )
        removeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true

        let stack = UIStackView(
            arrangedSubviews: [
                serialRow,
                connectionRow,
                communicationRow,
                uploadRow,
                removeButton
            ]
        )
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: 20
            ),
            stack.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -20
            ),
            stack.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 24
            )
        ])
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: 2,
            repeats: true
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func valueRow(title: String, value: String) -> UIView {
        let label = UILabel()
        label.text = value
        return valueRow(title: title, valueLabel: label)
    }

    private func valueRow(title: String, valueLabel: UILabel) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        valueLabel.textColor = .secondaryLabel
        valueLabel.textAlignment = .right
        valueLabel.numberOfLines = 0

        let row = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.distribution = .fill
        row.spacing = 12
        return row
    }

    private func controlRow(title: String, control: UIView) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        let row = UIStackView(arrangedSubviews: [titleLabel, control])
        row.axis = .horizontal
        row.alignment = .center
        row.distribution = .equalSpacing
        return row
    }

    private func refresh() {
        connectionValue.text = cgmManager.connectionDescription
        if let date = cgmManager.lastCommunicationDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            lastCommunicationValue.text = formatter.localizedString(
                for: date,
                relativeTo: Date()
            )
        } else {
            lastCommunicationValue.text = String(localized: "No data yet")
        }
    }

    @objc private func uploadChanged(_ sender: UISwitch) {
        cgmManager.uploadReadings = sender.isOn
    }

    @objc private func finish() {
        didFinish()
    }

    @objc private func confirmDeletion() {
        let alert = UIAlertController(
            title: String(localized: "Remove SMART Sensor?"),
            message: String(
                localized: "This stops the connection and removes the stored pairing credential."
            ),
            preferredStyle: .alert
        )
        alert.addAction(
            UIAlertAction(title: String(localized: "Cancel"), style: .cancel)
        )
        alert.addAction(
            UIAlertAction(
                title: String(localized: "Remove"),
                style: .destructive
            ) { [weak self] _ in
                self?.didDelete()
            }
        )
        present(alert, animated: true)
    }
}

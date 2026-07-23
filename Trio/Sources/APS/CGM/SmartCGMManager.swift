import Combine
import Foundation
import HealthKit
import LoopKit
import LoopKitUI
import SwiftUI
import UIKit

private struct SmartLifecycleProgress: DeviceLifecycleProgress {
    let percentComplete: Double
    let progressState: DeviceLifecycleProgressState
}

private struct SmartStatusHighlight: DeviceStatusHighlight {
    let localizedMessage: String
    let imageName: String
    let state: DeviceStatusHighlightState
}

/// Direct CGM integration for Smart/LinX sensors.
///
/// The sensor is observed passively through its CGM service advertisements. The
/// manager never connects to the peripheral and never sends commands to it.
final class SmartCGMManager: CGMManagerUI {
    static let pluginIdentifier = "SmartCGMManager"
    static let localizedTitle = "Smart / LinX (Beta)"
    fileprivate static let stateDidChangeNotification = Notification.Name(
        "SmartCGMManager.stateDidChange"
    )

    private struct State {
        let peripheralIdentifier: UUID
        var sensorName: String?
        var sensorSessionAnchor: Date?
        var lastMinutes: UInt16?
        var lastChecksum: UInt32?
        var lastStatus: UInt8?
        var lastCalibrationTemperatureStatus: UInt8?
        var lastTrend: Int8?
        var lastQuality: UInt8?
        var lastRSSI: Int?
        var lastCommunicationDate: Date?
        var currentGlucose: Double?
        var currentGlucoseDate: Date?
    }

    private struct DisplayState: GlucoseDisplayable {
        let isStateValid: Bool
        let trendType: GlucoseTrend? = nil
        let trendRate: HKQuantity? = nil
        let isLocal = true
        let glucoseRangeCategory: GlucoseRangeCategory? = nil
    }

    private static let device = HKDevice(
        name: "Smart CGM",
        manufacturer: "MicroTech Medical",
        model: "LinX / Smart",
        hardwareVersion: nil,
        firmwareVersion: nil,
        softwareVersion: nil,
        localIdentifier: nil,
        udiDeviceIdentifier: nil
    )

    private let lockedState: Locked<State>
    private let delegate = WeakSynchronizedDelegate<CGMManagerDelegate>()

    private lazy var scanner = SmartAdvertisementScanner(
        restorationIdentifier: SmartAdvertisementScanner.managerRestorationIdentifier
    ) { [weak self] reading in
        self?.handle(reading)
    }

    init(peripheralIdentifier: UUID) {
        lockedState = Locked(State(peripheralIdentifier: peripheralIdentifier))
        scanner.start()
    }

    required init?(rawState: RawStateValue) {
        guard
            let identifierString = rawState["peripheralIdentifier"] as? String,
            let peripheralIdentifier = UUID(uuidString: identifierString)
        else {
            return nil
        }

        var state = State(peripheralIdentifier: peripheralIdentifier)
        state.sensorName = rawState["sensorName"] as? String
        if let interval = rawState["sensorSessionAnchor"] as? TimeInterval {
            state.sensorSessionAnchor = Date(timeIntervalSince1970: interval)
        }
        if let value = rawState["lastMinutes"] as? Int {
            state.lastMinutes = UInt16(exactly: value)
        }
        if let value = rawState["lastChecksum"] as? Int {
            state.lastChecksum = UInt32(exactly: value)
        }
        if let value = rawState["lastStatus"] as? Int {
            state.lastStatus = UInt8(exactly: value)
        }
        if let value = rawState["lastCalibrationTemperatureStatus"] as? Int {
            state.lastCalibrationTemperatureStatus = UInt8(exactly: value)
        }
        if let value = rawState["lastTrend"] as? Int {
            state.lastTrend = Int8(exactly: value)
        }
        state.lastQuality = (rawState["lastQuality"] as? Int).flatMap(UInt8.init(exactly:))
        state.lastRSSI = rawState["lastRSSI"] as? Int
        if let interval = rawState["lastCommunicationDate"] as? TimeInterval {
            state.lastCommunicationDate = Date(timeIntervalSince1970: interval)
        }
        if let value = rawState["currentGlucose"] as? Double {
            state.currentGlucose = value
        }
        if let interval = rawState["currentGlucoseDate"] as? TimeInterval {
            state.currentGlucoseDate = Date(timeIntervalSince1970: interval)
        }

        lockedState = Locked(state)
        scanner.start()
    }

    deinit {
        scanner.stop()
    }

    var localizedTitle: String { Self.localizedTitle }
    var isOnboarded: Bool { true }
    var appURL: URL? { nil }
    var providesBLEHeartbeat: Bool { true }
    var managedDataInterval: TimeInterval? { .hours(3) }
    static var healthKitStorageDelay: TimeInterval { 0 }
    var shouldSyncToRemoteService: Bool { true }

    var cgmManagerDelegate: CGMManagerDelegate? {
        get { delegate.delegate }
        set { delegate.delegate = newValue }
    }

    var delegateQueue: DispatchQueue! {
        get { delegate.queue }
        set { delegate.queue = newValue }
    }

    var rawState: RawStateValue {
        let state = lockedState.value
        var raw: RawStateValue = [
            "peripheralIdentifier": state.peripheralIdentifier.uuidString
        ]
        raw["sensorName"] = state.sensorName
        raw["sensorSessionAnchor"] = state.sensorSessionAnchor?.timeIntervalSince1970
        raw["lastMinutes"] = state.lastMinutes.map { Int($0) }
        raw["lastChecksum"] = state.lastChecksum.map { Int($0) }
        raw["lastStatus"] = state.lastStatus.map { Int($0) }
        raw["lastCalibrationTemperatureStatus"] = state.lastCalibrationTemperatureStatus.map { Int($0) }
        raw["lastTrend"] = state.lastTrend.map { Int($0) }
        raw["lastQuality"] = state.lastQuality.map { Int($0) }
        raw["lastRSSI"] = state.lastRSSI
        raw["lastCommunicationDate"] = state.lastCommunicationDate?.timeIntervalSince1970
        raw["currentGlucose"] = state.currentGlucose
        raw["currentGlucoseDate"] = state.currentGlucoseDate?.timeIntervalSince1970
        return raw
    }

    var cgmManagerStatus: CGMManagerStatus {
        let state = lockedState.value
        return CGMManagerStatus(
            hasValidSensorSession: true,
            lastCommunicationDate: state.lastCommunicationDate,
            device: Self.device
        )
    }

    var glucoseDisplay: GlucoseDisplayable? {
        let state = lockedState.value
        let isRecent = state.currentGlucoseDate.map { Date().timeIntervalSince($0) < .minutes(10) } ?? false
        return DisplayState(isStateValid: isRecent)
    }

    var debugDescription: String {
        let state = lockedState.value
        return "SmartCGMManager(configured: true, hasReading: \(state.currentGlucose != nil))"
    }

    func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        scanner.start()
        completion(.noData)
    }

    func delete(completion: @escaping () -> Void) {
        scanner.stop()
        notifyDelegateOfDeletion(completion: completion)
    }

    func acknowledgeAlert(
        alertIdentifier _: LoopKit.Alert.AlertIdentifier,
        completion: @escaping (Error?) -> Void
    ) {
        completion(nil)
    }

    func getSoundBaseURL() -> URL? { nil }
    func getSounds() -> [LoopKit.Alert.Sound] { [] }

    var cgmStatusHighlight: DeviceStatusHighlight? {
        guard let lastCommunication = lockedState.value.lastCommunicationDate else {
            return SmartStatusHighlight(
                localizedMessage: "Aguardando\nsensor",
                imageName: "dot.radiowaves.left.and.right",
                state: .normalCGM
            )
        }
        guard Date().timeIntervalSince(lastCommunication) >= .minutes(8) else { return nil }
        return SmartStatusHighlight(
            localizedMessage: "Sem sinal\nFeche o Smart",
            imageName: "exclamationmark.circle.fill",
            state: .warning
        )
    }

    var cgmLifecycleProgress: DeviceLifecycleProgress? {
        guard let anchor = lockedState.value.sensorSessionAnchor else { return nil }
        let lifetime = TimeInterval.hours(15 * 24)
        let elapsed = max(0, Date().timeIntervalSince(anchor))
        let remaining = max(0, lifetime - elapsed)
        guard remaining < .hours(72) else { return nil }
        return SmartLifecycleProgress(
            percentComplete: min(1, elapsed / lifetime),
            progressState: remaining < .hours(24) ? .warning : .normalCGM
        )
    }

    var cgmStatusBadge: DeviceStatusBadge? { nil }

    private func handle(_ reading: SmartAdvertisementScanner.Reading) {
        let advertisement = reading.advertisement
        let matchesConfiguredSensor = lockedState.value.peripheralIdentifier == reading.peripheralIdentifier
        guard matchesConfiguredSensor else { return }

        let packetStateIsReliable = advertisement.status == 0 &&
            advertisement.calibrationTemperatureStatus == 0

        var isDuplicate = false
        var sessionAnchor: Date!
        var previousAdvertisementMinute: UInt16?

        lockedState.mutate { state in
            state.sensorName = reading.localName ?? state.sensorName
            state.lastCommunicationDate = reading.receivedAt
            state.lastStatus = advertisement.status
            state.lastCalibrationTemperatureStatus = advertisement.calibrationTemperatureStatus
            state.lastTrend = advertisement.trend
            state.lastQuality = advertisement.current.quality
            state.lastRSSI = reading.rssi

            isDuplicate = state.lastMinutes == advertisement.minutesSinceStart &&
                state.lastChecksum == advertisement.checksum
            guard !isDuplicate else { return }

            previousAdvertisementMinute = state.lastMinutes
            if state.sensorSessionAnchor == nil ||
                state.lastMinutes.map({ advertisement.minutesSinceStart + 5 < $0 }) == true
            {
                let inferredAnchor = reading.receivedAt.addingTimeInterval(
                    -.minutes(Double(advertisement.minutesSinceStart))
                )
                state.sensorSessionAnchor = Date(
                    timeIntervalSince1970: floor(inferredAnchor.timeIntervalSince1970 / 60) * 60
                )
                previousAdvertisementMinute = nil
            }

            state.lastMinutes = advertisement.minutesSinceStart
            state.lastChecksum = advertisement.checksum
            if packetStateIsReliable, Self.isReliable(advertisement.current) {
                state.currentGlucose = Double(advertisement.current.glucose)
                state.currentGlucoseDate = state.sensorSessionAnchor?.addingTimeInterval(
                    .minutes(Double(advertisement.minutesSinceStart))
                )
            }
            sessionAnchor = state.sensorSessionAnchor
        }

        guard !isDuplicate else { return }

        notifyStateChanged()

        let samples = advertisement.chronologicalRecords.compactMap { item -> NewGlucoseSample? in
            guard
                packetStateIsReliable,
                Self.isReliable(item.record),
                previousAdvertisementMinute.map({ item.minutesSinceStart > $0 }) ?? true
            else {
                return nil
            }

            return NewGlucoseSample(
                date: sessionAnchor.addingTimeInterval(.minutes(Double(item.minutesSinceStart))),
                quantity: HKQuantity(
                    unit: .milligramsPerDeciliter,
                    doubleValue: Double(item.record.glucose)
                ),
                condition: nil,
                trend: nil,
                trendRate: nil,
                isDisplayOnly: false,
                wasUserEntered: false,
                syncIdentifier: "smart-\(Int(sessionAnchor.timeIntervalSince1970.rounded()))-\(item.minutesSinceStart)",
                device: Self.device
            )
        }

        guard !samples.isEmpty else {
            delegate.notify { $0?.cgmManager(self, hasNew: .unreliableData) }
            return
        }

        delegate.notify { $0?.cgmManager(self, hasNew: .newData(samples)) }
    }

    private static func isReliable(_ record: SmartAdvertisement.GlucoseRecord) -> Bool {
        record.isValid &&
            record.quality > 0 &&
            (20 ... 600).contains(Int(record.glucose))
    }

    private func notifyStateChanged() {
        Foundation.NotificationCenter.default.post(
            name: Self.stateDidChangeNotification,
            object: self
        )
        delegate.notify { delegate in
            delegate?.cgmManagerDidUpdateState(self)
            delegate?.cgmManager(self, didUpdate: self.cgmManagerStatus)
        }
    }

    fileprivate struct SettingsSnapshot {
        let sensorName: String?
        let sessionAnchor: Date?
        let expiresAt: Date?
        let sessionProgress: Double?
        let sessionMinutes: UInt16?
        let status: UInt8?
        let calibrationTemperatureStatus: UInt8?
        let trend: Int8?
        let quality: UInt8?
        let checksum: UInt32?
        let rssi: Int?
        let lastCommunicationDate: Date?
        let currentGlucose: Double?
        let currentGlucoseDate: Date?
    }

    fileprivate func settingsSnapshot() -> SettingsSnapshot {
        let state = lockedState.value
        let expiration = state.sensorSessionAnchor?.addingTimeInterval(.hours(15 * 24))
        let progress = state.sensorSessionAnchor.map {
            min(1, max(0, Date().timeIntervalSince($0) / .hours(15 * 24)))
        }
        return SettingsSnapshot(
            sensorName: state.sensorName,
            sessionAnchor: state.sensorSessionAnchor,
            expiresAt: expiration,
            sessionProgress: progress,
            sessionMinutes: state.lastMinutes,
            status: state.lastStatus,
            calibrationTemperatureStatus: state.lastCalibrationTemperatureStatus,
            trend: state.lastTrend,
            quality: state.lastQuality,
            checksum: state.lastChecksum,
            rssi: state.lastRSSI,
            lastCommunicationDate: state.lastCommunicationDate,
            currentGlucose: state.currentGlucose,
            currentGlucoseDate: state.currentGlucoseDate
        )
    }
}

extension SmartCGMManager {
    static var onboardingImage: UIImage? { nil }
    var smallImage: UIImage? { nil }

    static func setupViewController(
        bluetoothProvider _: BluetoothProvider,
        displayGlucosePreference _: DisplayGlucosePreference,
        colorPalette _: LoopUIColorPalette,
        allowDebugFeatures _: Bool,
        prefersToSkipUserInteraction _: Bool
    ) -> SetupUIResult<CGMManagerViewController, CGMManagerUI> {
        let setup = SmartCGMSetupViewController()
        let navigation = CGMManagerSettingsNavigationViewController(rootViewController: setup)
        setup.onSelection = { [weak navigation] peripheralIdentifier in
            guard let navigation else { return }
            let manager = SmartCGMManager(peripheralIdentifier: peripheralIdentifier)
            navigation.cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didCreateCGMManager: manager)
            navigation.cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didOnboardCGMManager: manager)
            navigation.notifyComplete()
        }
        return .userInteractionRequired(navigation)
    }

    func settingsViewController(
        bluetoothProvider _: BluetoothProvider,
        displayGlucosePreference: DisplayGlucosePreference,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures _: Bool
    ) -> CGMManagerViewController {
        let actions = SmartCGMSettingsActions()
        let viewModel = SmartCGMSettingsViewModel(manager: self)
        let settingsView = SmartCGMSettingsView(
            viewModel: viewModel,
            actions: actions
        )

        let hostedView = DismissibleHostingController(
            content: settingsView
                .environmentObject(displayGlucosePreference),
            isModalInPresentation: false,
            colorPalette: colorPalette
        )
        hostedView.navigationItem.backButtonDisplayMode = .generic

        let navigation = CGMManagerSettingsNavigationViewController(
            rootViewController: hostedView
        )
        navigation.navigationBar.prefersLargeTitles = false

        actions.onDone = { [weak navigation] in
            navigation?.notifyComplete()
        }
        actions.onDelete = { [weak self, weak navigation] in
            self?.delete {
                DispatchQueue.main.async {
                    navigation?.notifyComplete()
                }
            }
        }
        actions.onChangeSensor = { [weak self, weak navigation] in
            self?.delete {
                DispatchQueue.main.async {
                    navigation?.notifyComplete()
                }
            }
        }

        return navigation
    }
}

private final class SmartCGMSetupViewController: UIViewController {
    var onSelection: ((UUID) -> Void)?

    private let statusLabel = UILabel()
    private let selectButton = UIButton(type: .system)
    private var discoveredIdentifier: UUID?
    private lazy var scanner = SmartAdvertisementScanner { [weak self] reading in
        DispatchQueue.main.async {
            self?.sensorDiscovered(reading)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Smart / LinX"
        view.backgroundColor = .systemBackground

        statusLabel.text = "Procurando um sensor Smart próximo…"
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center

        selectButton.setTitle("Usar este sensor", for: .normal)
        selectButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        selectButton.isEnabled = false
        selectButton.addTarget(self, action: #selector(selectSensor), for: .touchUpInside)

        let note = UILabel()
        note
            .text =
            "Mantenha o aplicativo oficial Smart completamente encerrado. O Trio recebe o sensor diretamente por Bluetooth."
        note.numberOfLines = 0
        note.textAlignment = .center
        note.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [statusLabel, selectButton, note])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        scanner.start()
    }

    deinit {
        scanner.stop()
    }

    private func sensorDiscovered(_ reading: SmartAdvertisementScanner.Reading) {
        guard discoveredIdentifier == nil else { return }
        discoveredIdentifier = reading.peripheralIdentifier
        statusLabel.text = "Sensor Smart encontrado. Confirme para vinculá-lo a este Trio."
        selectButton.isEnabled = true
        scanner.stop()
    }

    @objc private func selectSensor() {
        guard let discoveredIdentifier else { return }
        selectButton.isEnabled = false
        onSelection?(discoveredIdentifier)
    }
}

private final class SmartCGMSettingsActions {
    var onDone: () -> Void = {}
    var onDelete: () -> Void = {}
    var onChangeSensor: () -> Void = {}
}

private final class SmartCGMSettingsViewModel: ObservableObject {
    @Published private(set) var snapshot: SmartCGMManager.SettingsSnapshot

    private weak var manager: SmartCGMManager?
    private var stateObserver: NSObjectProtocol?

    init(manager: SmartCGMManager) {
        self.manager = manager
        snapshot = manager.settingsSnapshot()
        stateObserver = Foundation.NotificationCenter.default.addObserver(
            forName: SmartCGMManager.stateDidChangeNotification,
            object: manager,
            queue: .main
        ) { [weak self] _ in
            guard let self, let manager = self.manager else { return }
            self.snapshot = manager.settingsSnapshot()
        }
    }

    deinit {
        if let stateObserver {
            Foundation.NotificationCenter.default.removeObserver(stateObserver)
        }
    }
}

private struct SmartCGMSettingsView: View {
    private enum PendingAction: String, Identifiable {
        case changeSensor
        case deleteCGM

        var id: String { rawValue }
    }

    @Environment(\.glucoseTintColor) private var glucoseTintColor
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    @ObservedObject var viewModel: SmartCGMSettingsViewModel

    let actions: SmartCGMSettingsActions

    @State private var pendingAction: PendingAction?

    private var snapshot: SmartCGMManager.SettingsSnapshot {
        viewModel.snapshot
    }

    var body: some View {
        List {
            sensorSummarySection
            measurementSection

            Section {
                NavigationLink(destination: SmartCGMDeviceDetailsView(viewModel: viewModel)) {
                    Text("Detalhes do dispositivo")
                }
                NavigationLink(destination: SmartCGMTechnicalDetailsView(viewModel: viewModel)) {
                    Text("Detalhes técnicos")
                }
            }

            actionsSection
        }
        .insetGroupedListStyle()
        .navigationBarTitle(Text("Smart / LinX"), displayMode: .inline)
        .navigationBarItems(trailing: doneButton)
        .alert(item: $pendingAction, content: confirmationAlert)
    }

    private var sensorSummarySection: some View {
        Section {
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 16) {
                    sensorImage
                    expirationArea
                }

                Divider()

                HStack(alignment: .top, spacing: 16) {
                    summaryValue(title: "Estado do sensor", value: sensorState)
                    Spacer(minLength: 12)
                    summaryValue(
                        title: "Serial do sensor",
                        value: snapshot.sensorName ?? "–"
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var sensorImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(width: 77, height: 76)
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 36, weight: .medium))
                .foregroundColor(glucoseTintColor)
        }
    }

    private var expirationArea: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("O sensor expira em")
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(String(remainingComponents.days))
                    .font(.system(size: 24, weight: .heavy))
                Text("dias")
                    .font(.subheadline)
                Text(String(remainingComponents.hours))
                    .font(.system(size: 24, weight: .heavy))
                Text("horas")
                    .font(.subheadline)
            }

            ProgressView(value: snapshot.sessionProgress ?? 0)
                .accentColor(glucoseTintColor)
        }
    }

    private func summaryValue(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            Text(value)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
    }

    private var measurementSection: some View {
        Section(header: Text("Última medição")) {
            LabeledValueView(label: "Glicose", value: formattedGlucose)
            LabeledValueView(
                label: "Data",
                value: smartFormatLongDate(snapshot.currentGlucoseDate)
            )
        }
    }

    @ViewBuilder private var actionsSection: some View {
        Section {
            Button {
                pendingAction = .changeSensor
            } label: {
                HStack {
                    Text("Trocar sensor")
                        .foregroundColor(.accentColor)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Color(.tertiaryLabel))
                }
            }
        }

        Section {
            Button("Excluir CGM") {
                pendingAction = .deleteCGM
            }
            .foregroundColor(.red)
        }
    }

    private var doneButton: some View {
        Button("OK") {
            actions.onDone()
        }
    }

    private func confirmationAlert(for action: PendingAction) -> SwiftUI.Alert {
        switch action {
        case .changeSensor:
            return Alert(
                title: Text("Trocar sensor Smart?"),
                message: Text(
                    "O vínculo atual será removido. Depois, selecione Smart / LinX novamente para procurar o novo sensor."
                ),
                primaryButton: .destructive(Text("Trocar")) {
                    actions.onChangeSensor()
                },
                secondaryButton: .cancel(Text("Cancelar"))
            )
        case .deleteCGM:
            return Alert(
                title: Text("Excluir Smart do Trio?"),
                message: Text(
                    "As novas leituras deste sensor deixarão de ser recebidas pelo Trio."
                ),
                primaryButton: .destructive(Text("Excluir")) {
                    actions.onDelete()
                },
                secondaryButton: .cancel(Text("Cancelar"))
            )
        }
    }

    private var formattedGlucose: String {
        guard let glucose = snapshot.currentGlucose else { return "–" }
        return displayGlucosePreference.format(
            HKQuantity(unit: .milligramsPerDeciliter, doubleValue: glucose)
        )
    }

    private var sensorState: String {
        guard
            let lastCommunication = snapshot.lastCommunicationDate,
            Date().timeIntervalSince(lastCommunication) < .minutes(10)
        else {
            return "Sem comunicação"
        }
        if snapshot.status == 0, snapshot.calibrationTemperatureStatus == 0 {
            return "Sensor pronto"
        }
        return "Verificar sensor"
    }

    private var remainingComponents: (days: Int, hours: Int) {
        guard let expiresAt = snapshot.expiresAt else { return (0, 0) }
        let remaining = max(0, expiresAt.timeIntervalSinceNow)
        let days = Int(remaining / .hours(24))
        let hours = Int(
            remaining.truncatingRemainder(dividingBy: .hours(24)) / .hours(1)
        )
        return (days, hours)
    }
}

private struct SmartCGMDeviceDetailsView: View {
    @ObservedObject var viewModel: SmartCGMSettingsViewModel

    private var snapshot: SmartCGMManager.SettingsSnapshot {
        viewModel.snapshot
    }

    var body: some View {
        List {
            Section(header: Text("Informações do dispositivo")) {
                LabeledValueView(label: "Fabricante", value: "MicroTech Medical")
                LabeledValueView(label: "Modelo", value: "LinX / Smart GX-01S")
                LabeledValueView(label: "Comunicação", value: "Anúncio BLE passivo")
                LabeledValueView(
                    label: "Última comunicação",
                    value: smartFormatLongDate(snapshot.lastCommunicationDate)
                )
                LabeledValueView(
                    label: "Sinal",
                    value: snapshot.rssi.map { "\($0) dBm" }
                )
                LabeledValueView(
                    label: "Minuto da sessão",
                    value: snapshot.sessionMinutes.map(String.init)
                )
            }

            Section(header: Text("Sessão do sensor")) {
                LabeledValueView(
                    label: "Início estimado",
                    value: smartFormatLongDate(snapshot.sessionAnchor)
                )
                LabeledValueView(
                    label: "Validade estimada",
                    value: smartFormatLongDate(snapshot.expiresAt)
                )
            }

            Section(
                footer: Text(
                    "A validade é estimada a partir do contador de sessão transmitido pelo sensor e da duração nominal de 15 dias."
                )
            ) {
                LabeledValueView(label: "Glicose processada", value: "Disponível")
                LabeledValueView(label: "Coeficientes de fábrica", value: "Não expostos")
                LabeledValueView(label: "Bateria do sensor", value: "Não disponível")
                LabeledValueView(label: "Backfill do histórico", value: "Em validação")
            }
        }
        .insetGroupedListStyle()
        .navigationBarTitle(Text("Detalhes do dispositivo"), displayMode: .inline)
        .textSelection(.enabled)
    }
}

private struct SmartCGMTechnicalDetailsView: View {
    @ObservedObject var viewModel: SmartCGMSettingsViewModel

    private var snapshot: SmartCGMManager.SettingsSnapshot {
        viewModel.snapshot
    }

    var body: some View {
        List {
            Section(
                header: Text("Dados brutos do anúncio"),
                footer: Text(
                    "CRC, qualidade, tendência e estado são campos brutos do anúncio Bluetooth e ainda estão em validação."
                )
            ) {
                LabeledValueView(
                    label: "Qualidade",
                    value: snapshot.quality.map(String.init)
                )
                LabeledValueView(
                    label: "Tendência",
                    value: snapshot.trend.map(String.init)
                )
                LabeledValueView(
                    label: "CRC",
                    value: snapshot.checksum.map { String(format: "%08X", $0) }
                )
                LabeledValueView(
                    label: "Estado",
                    value: snapshot.status.map(String.init)
                )
                LabeledValueView(
                    label: "Calibração/temperatura",
                    value: snapshot.calibrationTemperatureStatus.map(String.init)
                )
            }
        }
        .insetGroupedListStyle()
        .navigationBarTitle(Text("Detalhes técnicos"), displayMode: .inline)
        .textSelection(.enabled)
    }
}

private func smartFormatLongDate(_ date: Date?) -> String {
    guard let date else { return "–" }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    formatter.doesRelativeDateFormatting = true
    return formatter.string(from: date)
}

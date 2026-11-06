import Combine
import Foundation
import HealthKit
import LocalAuthentication
import LoopKit
import LoopKitUI
import SmartCGMKit
import SwiftUI
import UIKit

extension SmartCGMManager: CGMManagerUI {
    public var cgmStatusBadge: DeviceStatusBadge? { nil }
    public static var onboardingImage: UIImage? { nil }
    public var smallImage: UIImage? { nil }

    public static func setupViewController(
        bluetoothProvider _: BluetoothProvider,
        displayGlucosePreference _: DisplayGlucosePreference,
        colorPalette _: LoopUIColorPalette,
        allowDebugFeatures _: Bool,
        prefersToSkipUserInteraction _: Bool
    ) -> SetupUIResult<CGMManagerViewController, CGMManagerUI> {
        let setup = SmartCGMSetupViewController()
        let navigation = CGMManagerSettingsNavigationViewController(rootViewController: setup)
        setup.onSelection = { [weak navigation] result in
            Task { @MainActor [weak navigation] in
                guard let navigation else { return }
                let manager = SmartCGMManager(
                    peripheralIdentifier: result.peripheralIdentifier,
                    sessionStartDate: result.sessionStartDate
                )
                navigation.cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didCreateCGMManager: manager)
                navigation.cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didOnboardCGMManager: manager)
                navigation.notifyComplete()
            }
        }
        return .userInteractionRequired(navigation)
    }

    public func settingsViewController(
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
            Task { [weak self, weak navigation] in
                await self?.delete()
                await MainActor.run {
                    navigation?.notifyComplete()
                }
            }
        }
        return navigation
    }
}

private final class SmartCGMSetupViewController: UIViewController {
    var onSelection: ((SmartAdvertisementScanner.ActivationResult) -> Void)?

    private let statusLabel = UILabel()
    private let sensorInfoLabel = UILabel()
    private let selectButton = UIButton(type: .system)
    private var discoveredCandidate: SmartAdvertisementScanner.ActivationCandidate?
    private lazy var scanner = SmartAdvertisementScanner { [weak self] reading in
        DispatchQueue.main.async {
            self?.sensorDiscovered(reading)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Smart / LinX")
        view.backgroundColor = .systemBackground

        statusLabel.text = String(localized: "Looking for a nearby Smart sensor…")
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center

        sensorInfoLabel.numberOfLines = 0
        sensorInfoLabel.font = .preferredFont(forTextStyle: .body)
        sensorInfoLabel.textColor = .secondaryLabel
        sensorInfoLabel.backgroundColor = .secondarySystemGroupedBackground
        sensorInfoLabel.layer.cornerRadius = 12
        sensorInfoLabel.layer.masksToBounds = true
        sensorInfoLabel.textAlignment = .left
        sensorInfoLabel.isHidden = true

        selectButton.setTitle(String(localized: "Use This Sensor"), for: .normal)
        selectButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        selectButton.isEnabled = false
        selectButton.addTarget(self, action: #selector(selectSensor), for: .touchUpInside)

        let note = UILabel()
        note.text = String(
            localized: "Keep the official Smart app completely closed. Trio receives the sensor directly over Bluetooth."
        )
        note.numberOfLines = 0
        note.textAlignment = .center
        note.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [statusLabel, sensorInfoLabel, selectButton, note])
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
        guard discoveredCandidate == nil else { return }
        discoveredCandidate = SmartAdvertisementScanner.ActivationCandidate(
            peripheralIdentifier: reading.peripheralIdentifier,
            localName: reading.localName,
            rssi: reading.rssi,
            receivedAt: reading.receivedAt,
            minutesSinceStart: reading.advertisement.minutesSinceStart,
            status: reading.advertisement.status,
            calibrationTemperatureStatus: reading.advertisement.calibrationTemperatureStatus,
            quality: reading.advertisement.current.quality
        )
        let candidate = discoveredCandidate!
        let isStopped = SmartSessionStatusPolicy.isStopped(status: candidate.status)
        statusLabel.text = isStopped
            ? String(localized: "Smart found with a stopped session. Review the details before activating it.")
            : String(localized: "Smart found with an active session. Review the details before adopting it.")
        sensorInfoLabel.text = onboardingDescription(for: candidate)
        sensorInfoLabel.isHidden = false
        selectButton.setTitle(
            isStopped
                ? String(localized: "Activate This Sensor")
                : String(localized: "Use Active Sensor"),
            for: .normal
        )
        selectButton.isEnabled = true
        scanner.stop()
    }

    private func onboardingDescription(
        for candidate: SmartAdvertisementScanner.ActivationCandidate
    ) -> String {
        let stopped = SmartSessionStatusPolicy.isStopped(status: candidate.status)
        let state: String
        if stopped {
            state = String(localized: "Stopped session — not yet activated")
        } else if candidate.minutesSinceStart < SmartSensorHandoverPolicy.warmupMinutes {
            state = String(localized: "Active session — warming up")
        } else if candidate.status == 0,
                  candidate.calibrationTemperatureStatus == 0,
                  candidate.quality > 0,
                  candidate.quality < 255
        {
            state = String(localized: "Active session — readings available")
        } else {
            state = String(localized: "Active session — data not yet available")
        }

        let name = candidate.localName ?? String(candidate.peripheralIdentifier.uuidString.prefix(8))
        let start: String
        let expiration: String
        let remaining: String
        if stopped {
            start = String(localized: "Not started yet")
            expiration = "–"
            remaining = "–"
        } else {
            let estimatedStart = candidate.estimatedSessionStartDate
            let estimatedExpiration = estimatedStart.addingTimeInterval(.hours(24 * 15))
            start = smartFormatLongDate(estimatedStart)
            expiration = smartFormatLongDate(estimatedExpiration)
            remaining = SmartRemainingTimeFormatter.format(until: estimatedExpiration)
        }

        return String(
            localized: "Identification: \(name)\nManufacturer: MicroTech Medical\nModel: LinX / Smart GX-01S\nState: \(state)\nTechnical state: \(candidate.status) / \(candidate.calibrationTemperatureStatus) / \(candidate.quality)\nSession minute: \(candidate.minutesSinceStart)\nNominal duration: 15 days\nEstimated start: \(start)\nEstimated expiration: \(expiration)\nTime remaining: \(remaining)\nSignal: \(candidate.rssi) dBm"
        )
    }

    @objc private func selectSensor() {
        guard let candidate = discoveredCandidate else { return }
        selectButton.isEnabled = false
        scanner.activate(
            candidate: candidate,
            existingSessionPolicy: .adopt,
            progress: { [weak self] phase in
                DispatchQueue.main.async {
                    switch phase {
                    case .connecting:
                        self?.statusLabel.text = String(localized: "Connecting to Smart…")
                    case .checkingSensor:
                        self?.statusLabel.text = String(localized: "Checking the Smart session…")
                    case .startingSession:
                        self?.statusLabel.text = String(localized: "Starting the Smart session…")
                    case .synchronizingTime:
                        self?.statusLabel.text = String(localized: "Synchronizing the Smart clock…")
                    case .confirmingSession:
                        self?.statusLabel.text = String(localized: "Confirming warmup start…")
                    }
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case let .success(result):
                        self.statusLabel.text = String(localized: "Session confirmed. Starting warmup…")
                        self.onSelection?(result)
                    case let .failure(error):
                        self.statusLabel.text = error.localizedDescription
                        self.selectButton.isEnabled = true
                    }
                }
            }
        )
    }
}

private final class SmartCGMSettingsActions {
    var onDone: () -> Void = {}
    var onDelete: () -> Void = {}
}

private final class SmartCGMSettingsViewModel: ObservableObject {
    @Published private(set) var reminderStatus: String
    @Published private(set) var snapshot: SmartCGMManager.SettingsSnapshot

    private weak var manager: SmartCGMManager?
    private var stateObserver: NSObjectProtocol?

    init(manager: SmartCGMManager) {
        self.manager = manager
        reminderStatus = manager.replacementReminderStatus
        snapshot = manager.settingsSnapshot()
        stateObserver = Foundation.NotificationCenter.default.addObserver(
            forName: SmartCGMManager.stateDidChangeNotification,
            object: manager,
            queue: .main
        ) { [weak self] _ in
            guard let self, let manager = self.manager else { return }
            self.snapshot = manager.settingsSnapshot()
            self.reminderStatus = manager.replacementReminderStatus
        }
    }

    deinit {
        if let stateObserver {
            Foundation.NotificationCenter.default.removeObserver(stateObserver)
        }
    }

    func setRegularizationEnabled(_ enabled: Bool) {
        manager?.setRegularizationEnabled(enabled)
    }

    func requestBackfill() {
        manager?.requestBackfill()
    }

    func beginSensorReplacement() {
        manager?.beginSensorReplacement()
    }

    func activateCurrentSensor() {
        manager?.activateCurrentSensor()
    }

    func activateReplacementSensor() {
        manager?.activateReplacementSensor()
    }

    func cancelSensorReplacement() {
        manager?.cancelSensorReplacement()
    }
}

private struct SmartCGMSettingsView: View {
    private enum PendingAction: String, Identifiable {
        case activateSensor
        case changeSensor
        case deleteCGM

        var id: String { rawValue }
    }

    private enum PresentedAlert: Identifiable {
        case pendingAction(PendingAction)
        case authenticationError(String)
        case backfillConfirmation

        var id: String {
            switch self {
            case let .pendingAction(action):
                return "action-\(action.id)"
            case .authenticationError:
                return "authentication"
            case .backfillConfirmation:
                return "backfill"
            }
        }
    }

    @Environment(\.glucoseTintColor) private var glucoseTintColor
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    @ObservedObject var viewModel: SmartCGMSettingsViewModel

    let actions: SmartCGMSettingsActions

    @State private var presentedAlert: PresentedAlert?
    @State private var isSensorReplacementPresented = false

    private var snapshot: SmartCGMManager.SettingsSnapshot {
        viewModel.snapshot
    }

    var body: some View {
        List {
            sensorSummarySection
            activationSection
            measurementSection
            readingTreatmentSection
            backfillSection

            Section {
                NavigationLink(destination: SmartCGMDeviceDetailsView(viewModel: viewModel)) {
                    Text("Device Details")
                }
                NavigationLink(destination: SmartCGMTechnicalDetailsView(viewModel: viewModel)) {
                    Text("Technical Details")
                }
            }

            actionsSection
        }
        .insetGroupedListStyle()
        .navigationBarTitle(Text("Smart / LinX"), displayMode: .inline)
        .navigationBarItems(trailing: doneButton)
        .alert(item: $presentedAlert, content: alert)
        .background(
            NavigationLink(
                destination: SmartCGMSensorReplacementView(viewModel: viewModel),
                isActive: $isSensorReplacementPresented
            ) {
                EmptyView()
            }
            .hidden()
        )
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
                    summaryValue(title: "Sensor State", value: sensorState)
                    Spacer(minLength: 12)
                    summaryValue(
                        title: "Sensor Serial",
                        value: snapshot.sensorName ?? "–"
                    )
                }

                if let warmupEndsAt = displayedWarmupEndsAt {
                    Divider()
                    TimelineView(.periodic(from: Date(), by: 30)) { context in
                        HStack {
                            Label("First reading in", systemImage: "hourglass")
                                .font(.headline)
                            Spacer()
                            Text(
                                SmartRemainingTimeFormatter.format(
                                    until: warmupEndsAt,
                                    now: context.date
                                )
                            )
                            .font(.headline.monospacedDigit())
                            .foregroundColor(.orange)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var sensorImage: some View {
        Image(systemName: "sensor.tag.radiowaves.forward")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: 92, height: 92)
            .accessibilityLabel(Text("Smart 2.0 Sensor"))
    }

    private var expirationArea: some View {
        VStack(alignment: .leading, spacing: 5) {
            if isReplacementWarming {
                Text("New Smart Warming Up")
                    .font(.headline)
                    .foregroundColor(.orange)
                Text("Trio will switch after the new sensor provides reliable readings.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isSessionStopped {
                Text("Session Not Started")
                    .font(.headline)
                    .foregroundColor(.orange)
                Text("Confirm activation to start warmup.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Sensor expires in")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(String(remainingComponents.days))
                        .font(.system(size: 24, weight: .heavy))
                    Text("days")
                        .font(.subheadline)
                    Text(String(remainingComponents.hours))
                        .font(.system(size: 24, weight: .heavy))
                    Text("hours")
                        .font(.subheadline)
                }

                ProgressView(value: snapshot.sessionProgress ?? 0)
                    .accentColor(glucoseTintColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
    }

    private func summaryValue(title: LocalizedStringKey, value: String) -> some View {
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
        Section(header: Text("Latest Reading")) {
            LabeledValueView(
                label: String(localized: "Sensor Glucose"),
                value: formattedGlucose(snapshot.currentGlucose)
            )
            LabeledValueView(
                label: String(localized: "Date"),
                value: smartFormatLongDate(snapshot.currentGlucoseDate)
            )
            LabeledValueView(
                label: String(localized: "Delivered to Trio"),
                value: formattedGlucose(snapshot.lastDeliveredGlucose)
            )
            LabeledValueView(
                label: String(localized: "Delivery Date"),
                value: smartFormatLongDate(snapshot.lastDeliveredGlucoseDate)
            )
            LabeledValueView(label: String(localized: "Trend"), value: formattedTrend)
        }
    }

    private var readingTreatmentSection: some View {
        Section(
            header: Text("Reading Processing"),
            footer: Text(
                "Trio receives one Smart reading per minute to calculate trend. Trio's native filtering stores a reading approximately every four minutes. Regularization is bypassed during rapid changes and drops near low glucose."
            )
        ) {
            Toggle(
                isOn: Binding(
                    get: { snapshot.regularizationEnabled },
                    set: viewModel.setRegularizationEnabled
                )
            ) {
                Text("Regularize Small Fluctuations")
            }
            LabeledValueView(
                label: String(localized: "Last Reading Delivered"),
                value: snapshot.lastEstimateUsedRegularization
                    ? String(localized: "Regularized")
                    : String(localized: "Original")
            )
        }
    }

    private var backfillSection: some View {
        Section(
            header: Text("History"),
            footer: Text(
                "Recovery is manual and limited to the last six hours. Trio pauses passive scanning only during this connection, imports at most one reading every five minutes, and disconnects as soon as it finishes to preserve battery."
            )
        ) {
            Button {
                presentedAlert = .backfillConfirmation
            } label: {
                HStack {
                    Text(
                        snapshot.isBackfillRunning
                            ? String(localized: "Recovering History…")
                            : String(localized: "Recover Last Six Hours")
                    )
                    Spacer()
                    if snapshot.isBackfillRunning {
                        ProgressView()
                    }
                }
            }
            .disabled(snapshot.isBackfillRunning)

            if let lastBackfillDate = snapshot.lastBackfillDate {
                LabeledValueView(
                    label: String(localized: "Last Recovery"),
                    value: smartFormatLongDate(lastBackfillDate)
                )
                LabeledValueView(
                    label: String(localized: "Imported Readings"),
                    value: snapshot.lastBackfillRecordCount.map(String.init)
                )
            }

            if let error = snapshot.lastBackfillError {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
            }
        }
    }

    @ViewBuilder private var activationSection: some View {
        if isSessionStopped, !isReplacementWarming {
            Section(
                footer: Text(
                    "Trio will check the sensor state, start only a stopped session, and confirm the start before showing warmup."
                )
            ) {
                Button("Confirm This Smart Activation") {
                    presentedAlert = .pendingAction(.activateSensor)
                }
            }
        }
    }

    @ViewBuilder private var actionsSection: some View {
        Section {
            Button {
                if isReplacementWarming {
                    viewModel.beginSensorReplacement()
                    isSensorReplacementPresented = true
                } else {
                    presentedAlert = .pendingAction(.changeSensor)
                }
            } label: {
                HStack {
                    Text(
                        isReplacementWarming
                            ? String(localized: "Monitor New Sensor")
                            : String(localized: "Change Sensor")
                    )
                    .foregroundColor(.accentColor)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Color(.tertiaryLabel))
                }
            }
        }

        Section {
            Button("Delete CGM") {
                presentedAlert = .pendingAction(.deleteCGM)
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
        case .activateSensor:
            return Alert(
                title: Text("Activate This Smart?"),
                message: Text(
                    "Keep the official Smart app completely closed. Trio will send the command only if the sensor confirms that its session is stopped, and will verify the start before warmup."
                ),
                primaryButton: .default(Text("Activate")) {
                    authenticateAndPerform(.activateSensor)
                },
                secondaryButton: .cancel(Text("Cancel"))
            )
        case .changeSensor:
            return Alert(
                title: Text("Prepare a New Smart Sensor?"),
                message: Text(
                    "Trio will look for a nearby new Smart. The current sensor will continue sending glucose readings throughout warmup and its history will remain intact. Replacement will occur automatically only after the new sensor produces reliable readings."
                ),
                primaryButton: .default(Text("Continue")) {
                    authenticateAndPerform(.changeSensor)
                },
                secondaryButton: .cancel(Text("Cancel"))
            )
        case .deleteCGM:
            return Alert(
                title: Text("Delete Smart from Trio?"),
                message: Text(
                    "Trio will stop receiving new readings from this sensor."
                ),
                primaryButton: .destructive(Text("Delete")) {
                    authenticateAndPerform(.deleteCGM)
                },
                secondaryButton: .cancel(Text("Cancel"))
            )
        }
    }

    private func alert(for alert: PresentedAlert) -> SwiftUI.Alert {
        switch alert {
        case let .pendingAction(action):
            return confirmationAlert(for: action)
        case let .authenticationError(message):
            return Alert(
                title: Text("Authentication Required"),
                message: Text(message),
                dismissButton: .default(Text("OK"))
            )
        case .backfillConfirmation:
            return Alert(
                title: Text("Recover Smart History?"),
                message: Text(
                    "Close the official Smart app completely before continuing. Trio will make a temporary connection only to copy readings from the last six hours; no records will be deleted from the sensor."
                ),
                primaryButton: .default(Text("Recover")) {
                    viewModel.requestBackfill()
                },
                secondaryButton: .cancel(Text("Cancel"))
            )
        }
    }

    private func formattedGlucose(_ glucose: Double?) -> String {
        guard let glucose else { return "–" }
        return displayGlucosePreference.format(
            LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: glucose)
        )
    }

    private var formattedTrend: String {
        guard let trend = snapshot.trend else { return "–" }
        guard let rate = snapshot.trendRate else { return trend.symbol }
        return "\(trend.symbol) \(String(format: "%.1f", rate)) mg/dL/min"
    }

    private func authenticateAndPerform(_ action: PendingAction) {
        Task { @MainActor in
            do {
                guard try await SmartDeviceAuthentication.unlock() else {
                    presentedAlert = .authenticationError(
                        String(localized: "The sensor was not changed because your identity could not be confirmed.")
                    )
                    return
                }

                switch action {
                case .activateSensor:
                    viewModel.activateCurrentSensor()
                case .changeSensor:
                    viewModel.beginSensorReplacement()
                    isSensorReplacementPresented = true
                case .deleteCGM:
                    actions.onDelete()
                }
            } catch {
                presentedAlert = .authenticationError(
                    String(
                        localized: "The sensor remains connected. Confirm with Face ID or the iPhone passcode to continue."
                    )
                )
            }
        }
    }

    private var sensorState: String {
        if isReplacementWarming {
            return String(localized: "New Smart Warming Up")
        }
        if isSessionStopped {
            return String(localized: "Activation Not Confirmed")
        }
        guard
            let lastCommunication = snapshot.lastCommunicationDate,
            Date().timeIntervalSince(lastCommunication) < .minutes(10)
        else {
            return String(localized: "No Communication")
        }
        if snapshot.expiresAt.map({ $0 <= Date() }) == true {
            return String(localized: "Sensor Expired")
        }
        if SmartSessionStatusPolicy.isWarmupConfirmed(
            status: snapshot.status,
            minutesSinceStart: snapshot.sessionMinutes
        ) {
            return String(localized: "Warming Up")
        }
        if snapshot.status == 0, snapshot.calibrationTemperatureStatus == 0 {
            return String(localized: "Sensor Ready")
        }
        return String(localized: "Check Sensor")
    }

    private var isSessionStopped: Bool {
        SmartSessionStatusPolicy.isStopped(status: snapshot.status)
    }

    private var displayedWarmupEndsAt: Date? {
        if case let .warming(_, readyAt, _) = snapshot.sensorReplacementState,
           readyAt > Date()
        {
            return readyAt
        }
        guard SmartSessionStatusPolicy.isWarmupConfirmed(
            status: snapshot.status,
            minutesSinceStart: snapshot.sessionMinutes
        ) else { return nil }
        guard let start = snapshot.sessionAnchor else { return nil }
        let readyAt = start.addingTimeInterval(.hours(1))
        return readyAt > Date() ? readyAt : nil
    }

    private var isReplacementWarming: Bool {
        if case .warming = snapshot.sensorReplacementState {
            return true
        }
        return false
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

private struct SmartCGMSensorReplacementView: View {
    @ObservedObject var viewModel: SmartCGMSettingsViewModel
    @State private var isActivationConfirmationPresented = false

    private var state: SmartCGMManager.SensorReplacementState {
        viewModel.snapshot.sensorReplacementState
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    Image(systemName: "sensor.tag.radiowaves.forward")
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .accessibilityLabel(Text("Smart 2.0 Sensor"))
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            Section(
                header: Text("Before You Begin"),
                footer: Text(
                    "Trio keeps the current sensor sending glucose readings and preserves all history while the new Smart warms up in parallel. Replacement is automatic only after reliable readings. If activation fails, the current sensor is not replaced. Keep the official Smart app installed as a fallback during this initial validation."
                )
            ) {
                Label("Apply the new Smart sensor", systemImage: "1.circle")
                Label("Do not start it in the official app", systemImage: "2.circle")
                Label("Keep the official app completely closed", systemImage: "3.circle")
                Label("Keep the new sensor near this iPhone", systemImage: "4.circle")
            }

            statusSection
        }
        .insetGroupedListStyle()
        .navigationBarTitle(Text("New Smart Sensor"), displayMode: .inline)
        .onDisappear {
            switch state {
            case .activating,
                 .completed,
                 .reacquiring,
                 .verificationRequired,
                 .warming:
                return
            default:
                viewModel.cancelSensorReplacement()
            }
        }
        .alert(isPresented: $isActivationConfirmationPresented) {
            Alert(
                title: Text("Activate the New Smart?"),
                message: Text(
                    "Confirm only if this is the new sensor already applied. Trio will start warmup in parallel; the current Smart will continue providing glucose readings until automatic replacement."
                ),
                primaryButton: .default(Text("Activate and Warm Up")) {
                    viewModel.activateReplacementSensor()
                },
                secondaryButton: .cancel(Text("Cancel"))
            )
        }
    }

    @ViewBuilder private var statusSection: some View {
        switch state {
        case .idle:
            Section {
                Button("Find New Smart") {
                    viewModel.beginSensorReplacement()
                }
            }

        case .searching:
            Section(header: Text("Searching")) {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Looking for a nearby new Smart sensor…")
                }
                Button("Cancel") {
                    viewModel.cancelSensorReplacement()
                }
            }

        case let .candidate(name, identifier):
            Section(
                header: Text("New Sensor Found"),
                footer: Text(
                    "Before activating, confirm that the current sensor is still working and that this identifier belongs to the new Smart."
                )
            ) {
                LabeledValueView(label: String(localized: "Sensor"), value: name)
                LabeledValueView(label: String(localized: "Identifier"), value: identifier)
                Button("Activate and Start Warmup") {
                    isActivationConfirmationPresented = true
                }
                Button("Search Again") {
                    viewModel.beginSensorReplacement()
                }
            }

        case let .activating(message):
            Section(header: Text("Activating")) {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(message)
                }
                Text("Do not close Trio or move the iPhone away from the sensor during this step.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

        case let .warming(startDate, readyAt, lastCommunicationDate):
            Section(header: Text("Parallel Warmup")) {
                Label("New Smart activated successfully", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                LabeledValueView(
                    label: String(localized: "Warmup Start"),
                    value: smartFormatLongDate(startDate)
                )
                LabeledValueView(
                    label: String(localized: "Estimated Completion"),
                    value: smartFormatLongDate(readyAt)
                )
                TimelineView(.periodic(from: Date(), by: 30)) { context in
                    LabeledValueView(
                        label: String(localized: "Time Remaining"),
                        value: readyAt > context.date
                            ? SmartRemainingTimeFormatter.format(until: readyAt, now: context.date)
                            : String(localized: "Confirming Readings")
                    )
                }
                LabeledValueView(
                    label: String(localized: "Last New Smart Signal"),
                    value: smartFormatLongDate(lastCommunicationDate)
                )
                ProgressView(value: warmupProgress(startDate: startDate, readyAt: readyAt))
                Text(
                    Date() < readyAt
                        ?
                        "The current Smart continues providing glucose readings to Trio. No reading from the new sensor will be used before warmup ends."
                        :
                        "Warmup completed. Trio is confirming the first reliable readings before automatic replacement."
                )
                .font(.footnote)
                .foregroundColor(.secondary)
            }

        case let .verificationRequired(startDate, referenceGlucose, candidateGlucose):
            Section(header: Text("Safety Confirmation")) {
                Label("Automatic insulin temporarily protected", systemImage: "exclamationmark.shield.fill")
                    .foregroundColor(.orange)
                LabeledValueView(
                    label: String(localized: "Previous Sensor"),
                    value: "\(Int(referenceGlucose.rounded())) mg/dL"
                )
                LabeledValueView(
                    label: String(localized: "New Smart"),
                    value: "\(Int(candidateGlucose.rounded())) mg/dL"
                )
                LabeledValueView(label: String(localized: "Session Start"), value: smartFormatLongDate(startDate))
                Text(
                    "Trio will release the new sensor automatically after 30 stable minutes, or after at most 60 minutes of valid readings. A stable fingerstick can complete this step sooner."
                )
                .font(.footnote)
                .foregroundColor(.secondary)
            }

        case let .reacquiring(startDate, receivedReadingCount):
            Section(header: Text("Validating the New Smart")) {
                Label("New sensor adopted as reference", systemImage: "checkmark.shield.fill")
                    .foregroundColor(.green)
                LabeledValueView(
                    label: String(localized: "Confirmed Glucose Readings"),
                    value: "\(receivedReadingCount) of \(SmartHandoverReacquisitionPolicy.requiredDeliveredReadings)"
                )
                LabeledValueView(label: String(localized: "Session Start"), value: smartFormatLongDate(startDate))
                ProgressView(
                    value: Double(receivedReadingCount),
                    total: Double(SmartHandoverReacquisitionPolicy.requiredDeliveredReadings)
                )
                Text(
                    "The new sensor's glucose readings are now entering Trio. Automatic insulin will resume after three of its readings are received."
                )
                .font(.footnote)
                .foregroundColor(.secondary)
            }

        case let .completed(startDate):
            Section(header: Text("Automatic Replacement Completed")) {
                Label("New Smart providing glucose readings", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                LabeledValueView(
                    label: String(localized: "Session Start"),
                    value: smartFormatLongDate(startDate)
                )
                Text(
                    "The new sensor was adopted only after warmup completed and reliable readings were confirmed. Previous history remains in Trio."
                )
                .font(.footnote)
                .foregroundColor(.secondary)
            }

        case let .failed(message):
            Section(header: Text("Unable to Complete")) {
                Text(message)
                    .foregroundColor(.red)
                Text("The previous sensor and Trio history were not changed.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Button("Try Again") {
                    viewModel.beginSensorReplacement()
                }
            }
        }
    }

    private func warmupProgress(startDate: Date, readyAt: Date) -> Double {
        let duration = readyAt.timeIntervalSince(startDate)
        guard duration > 0 else { return 1 }
        return min(1, max(0, Date().timeIntervalSince(startDate) / duration))
    }
}

private struct SmartCGMDeviceDetailsView: View {
    @ObservedObject var viewModel: SmartCGMSettingsViewModel

    private var snapshot: SmartCGMManager.SettingsSnapshot {
        viewModel.snapshot
    }

    var body: some View {
        List {
            Section(header: Text("Device Information")) {
                LabeledValueView(label: String(localized: "Manufacturer"), value: "MicroTech Medical")
                LabeledValueView(label: String(localized: "Model"), value: "LinX / Smart GX-01S")
                LabeledValueView(
                    label: String(localized: "Communication"),
                    value: String(localized: "Passive BLE; limited connection for history or activation")
                )
                LabeledValueView(
                    label: String(localized: "Last Communication"),
                    value: smartFormatLongDate(snapshot.lastCommunicationDate)
                )
                LabeledValueView(
                    label: String(localized: "Signal"),
                    value: snapshot.rssi.map { "\($0) dBm" }
                )
                LabeledValueView(
                    label: String(localized: "Session Minute"),
                    value: snapshot.sessionMinutes.map(String.init)
                )
            }

            Section(header: Text("Sensor Session")) {
                LabeledValueView(
                    label: String(localized: "Estimated Start"),
                    value: smartFormatLongDate(snapshot.sessionAnchor)
                )
                LabeledValueView(
                    label: String(localized: "Estimated Expiration"),
                    value: smartFormatLongDate(snapshot.expiresAt)
                )
                LabeledValueView(
                    label: String(localized: "Replacement Reminders"),
                    value: viewModel.reminderStatus
                )
            }

            Section(
                footer: Text(
                    "Expiration is estimated from the session counter transmitted by the sensor and its nominal 15-day duration."
                )
            ) {
                LabeledValueView(
                    label: String(localized: "Processed Glucose"),
                    value: String(localized: "Available")
                )
                LabeledValueView(
                    label: String(localized: "Factory Coefficients"),
                    value: String(localized: "Not Exposed")
                )
                LabeledValueView(
                    label: String(localized: "Sensor Battery"),
                    value: String(localized: "Unavailable")
                )
                LabeledValueView(
                    label: String(localized: "Advertisement History"),
                    value: String(localized: "Up to 3 Minutes")
                )
                LabeledValueView(
                    label: String(localized: "Extended Backfill"),
                    value: String(localized: "Manual, up to 6 Hours")
                )
                LabeledValueView(
                    label: String(localized: "Battery Preservation"),
                    value: String(localized: "Connection Ends Automatically")
                )
            }
        }
        .insetGroupedListStyle()
        .navigationBarTitle(Text("Device Details"), displayMode: .inline)
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
                header: Text("Raw Advertisement Data"),
                footer: Text(
                    "CRC, quality, trend, and state are raw Bluetooth advertisement fields and remain under validation."
                )
            ) {
                LabeledValueView(
                    label: String(localized: "Quality"),
                    value: snapshot.quality.map(String.init)
                )
                LabeledValueView(
                    label: String(localized: "Trend"),
                    value: snapshot.rawTrend.map(String.init)
                )
                LabeledValueView(
                    label: String(localized: "Calculated Trend"),
                    value: snapshot.trendRate.map { String(format: "%.2f mg/dL/min", $0) }
                )
                LabeledValueView(
                    label: String(localized: "Samples per Minute"),
                    value: String(snapshot.minuteSampleCount)
                )
                LabeledValueView(
                    label: String(localized: "CRC"),
                    value: snapshot.checksum.map { String(format: "%08X", $0) }
                )
                LabeledValueView(
                    label: String(localized: "State"),
                    value: snapshot.status.map(String.init)
                )
                LabeledValueView(
                    label: String(localized: "Calibration/Temperature"),
                    value: snapshot.calibrationTemperatureStatus.map(String.init)
                )
            }
        }
        .insetGroupedListStyle()
        .navigationBarTitle(Text("Technical Details"), displayMode: .inline)
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

private enum SmartDeviceAuthentication {
    @MainActor static func unlock() async throws -> Bool {
        try await LAContext().evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: String(localized: "We need to make sure you are the owner of the device.")
        )
    }
}

/// Sensor-specific section embedded in the host's existing calibration form.
/// The host keeps its storage, units and confirmation workflow.
public struct SmartCalibrationStatusView: View {
    private let glucose: String
    private let timestamp: String
    private let trend: String
    private let readinessMessage: String
    private let refresh: () -> Void

    public init(
        glucose: String,
        timestamp: String,
        trend: String,
        readinessMessage: String,
        refresh: @escaping () -> Void
    ) {
        self.glucose = glucose
        self.timestamp = timestamp
        self.trend = trend
        self.readinessMessage = readinessMessage
        self.refresh = refresh
    }

    public var body: some View {
        HStack {
            Text("Raw Smart Reading")
            Spacer()
            Text(glucose).foregroundColor(.secondary)
        }
        HStack {
            Text("Sensor Time")
            Spacer()
            Text(timestamp).foregroundColor(.secondary)
        }
        HStack {
            Text("Trend")
            Spacer()
            Text(trend).foregroundColor(.secondary)
        }
        Button("Refresh Smart Reading", action: refresh)
        if !readinessMessage.isEmpty {
            Text(readinessMessage).font(.footnote).foregroundColor(.orange)
        }
    }
}

import Combine
import Foundation
import HealthKit
import LoopKit
import LoopKitUI
import SwiftUI
import UIKit
import UserNotifications

private struct SmartLifecycleProgress: DeviceLifecycleProgress {
    let percentComplete: Double
    let progressState: DeviceLifecycleProgressState
}

private struct SmartStatusHighlight: DeviceStatusHighlight {
    let localizedMessage: String
    let imageName: String
    let state: DeviceStatusHighlightState
}

enum SmartDeliveryCadence {
    static let intervalMinutes: UInt16 = 4

    static func shouldDeliver(
        currentMinute: UInt16,
        lastDeliveredMinute: UInt16?
    ) -> Bool {
        guard let lastDeliveredMinute else { return true }
        guard currentMinute >= lastDeliveredMinute else {
            // A lower minute indicates a new sensor session or a counter reset.
            return true
        }
        return currentMinute - lastDeliveredMinute >= intervalMinutes
    }
}

/// Decides when a newly activated Smart can safely replace the sensor that is
/// still supplying Trio. The pending sensor is observed but never forwarded to
/// the glucose pipeline until it has completed the nominal warmup and produced
/// two consecutive reliable advertisements.
enum SmartSensorHandoverPolicy {
    static let warmupMinutes: UInt16 = 60
    static let requiredConsecutiveReliableReadings = 2

    static func updatedReliableReadingCount(
        previousCount: Int,
        minutesSinceStart: UInt16,
        packetStateIsReliable: Bool,
        currentRecordIsReliable: Bool
    ) -> Int {
        guard
            minutesSinceStart >= warmupMinutes,
            packetStateIsReliable,
            currentRecordIsReliable
        else {
            return 0
        }
        return min(requiredConsecutiveReliableReadings, previousCount + 1)
    }

    static func shouldHandover(reliableReadingCount: Int) -> Bool {
        reliableReadingCount >= requiredConsecutiveReliableReadings
    }
}

/// Screens the first readings from a warmed Smart against the sensor that is
/// still active. A difference must exceed both the ordinary CGM tolerance and
/// a meaningful absolute amount before Trio asks for a fingerstick.
enum SmartHandoverDivergencePolicy {
    static let stableReleaseInterval: TimeInterval = .minutes(30)
    static let maximumHoldInterval: TimeInterval = .minutes(60)
    static let requiredRecentReadings = 5
    static let maximumStableSpread = 15.0

    struct Assessment: Equatable {
        let referenceGlucose: Double
        let candidateGlucose: Double
        let absoluteDifference: Double
        let relativeDifference: Double

        var requiresFingerstickConfirmation: Bool {
            absoluteDifference > 20 && relativeDifference > 0.20
        }
    }

    static func assess(
        referenceGlucose: Double,
        candidateGlucoseValues: [Double]
    ) -> Assessment? {
        let candidates = candidateGlucoseValues
            .filter { $0.isFinite && (20 ... 600).contains($0) }
            .sorted()
        guard referenceGlucose.isFinite, referenceGlucose > 0, candidates.count >= 2 else {
            return nil
        }

        let middle = candidates.count / 2
        let representative = candidates.count.isMultiple(of: 2)
            ? (candidates[middle - 1] + candidates[middle]) / 2
            : candidates[middle]
        let absoluteDifference = abs(representative - referenceGlucose)
        return Assessment(
            referenceGlucose: referenceGlucose,
            candidateGlucose: representative,
            absoluteDifference: absoluteDifference,
            relativeDifference: absoluteDifference / referenceGlucose
        )
    }

    static func shouldAutomaticallyRelease(
        detectedAt: Date,
        now: Date,
        recentReliableGlucoseValues: [Double]
    ) -> Bool {
        let elapsed = now.timeIntervalSince(detectedAt)
        guard elapsed >= stableReleaseInterval else { return false }

        let recent = Array(recentReliableGlucoseValues.suffix(requiredRecentReadings))
        guard
            recent.count == requiredRecentReadings,
            recent.allSatisfy({ $0.isFinite && (20 ... 600).contains($0) })
        else {
            return false
        }

        if elapsed >= maximumHoldInterval {
            return true
        }

        guard let minimum = recent.min(), let maximum = recent.max() else { return false }
        return maximum - minimum <= maximumStableSpread
    }
}

/// Requires a short, sensor-specific glucose series after Trio accepts the new
/// Smart as its reference. The readings are allowed into Trio immediately, but
/// automatic insulin remains blocked until the series is complete.
enum SmartHandoverReacquisitionPolicy {
    static let requiredDeliveredReadings = 3

    static func updatedDeliveredReadingCount(previousCount: Int) -> Int {
        min(requiredDeliveredReadings, max(0, previousCount) + 1)
    }

    static func canResumeAutomaticInsulin(deliveredReadingCount: Int) -> Bool {
        deliveredReadingCount >= requiredDeliveredReadings
    }
}

/// Defines the advance notifications for a planned Smart replacement.
///
/// The final reminder is intentionally sent 65 minutes before expiry. This
/// gives the nominal 60-minute warmup a small validation margin while the
/// current sensor continues supplying Trio.
enum SmartSensorReminderPolicy {
    enum Kind: String, CaseIterable, Equatable {
        case expiresIn24Hours = "expires-in-24-hours"
        case prepareIn120Minutes = "prepare-in-120-minutes"
        case replaceIn65Minutes = "replace-in-65-minutes"

        var leadTime: TimeInterval {
            switch self {
            case .expiresIn24Hours:
                return .hours(24)
            case .prepareIn120Minutes:
                return .minutes(120)
            case .replaceIn65Minutes:
                return .minutes(65)
            }
        }

        var title: String {
            switch self {
            case .expiresIn24Hours:
                return String(localized: "O Smart termina em 24 horas")
            case .prepareIn120Minutes:
                return String(localized: "Prepare-se para a troca do Smart")
            case .replaceIn65Minutes:
                return String(localized: "Hora de iniciar o novo Smart")
            }
        }

        var body: String {
            switch self {
            case .expiresIn24Hours:
                return String(localized: "Tenha um novo sensor disponível para fazer a troca sem interromper as glicemias.")
            case .prepareIn120Minutes:
                return String(
                    localized: "O sensor atual termina em 2 horas. Deixe o novo Smart e o iPhone preparados para a troca."
                )
            case .replaceIn65Minutes:
                return String(
                    localized: "Aplique o novo sensor e use Trio > Smart / LinX > Trocar sensor. O Smart atual continuará enviando glicemias durante o aquecimento."
                )
            }
        }
    }

    struct ScheduledNotification: Equatable {
        let kind: Kind
        let deliveryDate: Date
    }

    static func notifications(expiresAt: Date, now: Date) -> [ScheduledNotification] {
        guard expiresAt > now else { return [] }

        return Kind.allCases.compactMap { kind in
            let requestedDate = expiresAt.addingTimeInterval(-kind.leadTime)
            if requestedDate > now {
                return ScheduledNotification(kind: kind, deliveryDate: requestedDate)
            }

            // If Trio is restored or updated after the critical 65-minute
            // boundary, send only the actionable reminder. Do not deliver the
            // older 24-hour and 2-hour messages together.
            guard kind == .replaceIn65Minutes else { return nil }
            return ScheduledNotification(
                kind: kind,
                deliveryDate: now.addingTimeInterval(2)
            )
        }
    }
}

/// Direct CGM integration for Smart/LinX sensors.
///
/// Routine glucose delivery is observed passively through CGM service
/// advertisements. Active Bluetooth connections are explicit, bounded and
/// self-terminating: either a read-only history request or a new-sensor activation.
final class SmartCGMManager: CGMManagerUI {
    static let pluginIdentifier = "SmartCGMManager"
    static let localizedTitle = String(localized: "Smart / LinX (Beta)")
    private static let sensorLifetime: TimeInterval = .hours(15 * 24)
    private static let warmupPeriod: TimeInterval = .hours(1)
    private static let legacyReplacementReminderPrefix = "Trio.Smart.replacement."
    private static let replacementReminderPrefix = "Trio.Smart.replacement.reminder."
    private static let replacementCompletedPrefix = "Trio.Smart.replacement.completed."
    private static let handoverVerificationPrefix = "Trio.Smart.handover.verification."
    fileprivate static let stateDidChangeNotification = Notification.Name(
        "SmartCGMManager.stateDidChange"
    )

    fileprivate enum SensorReplacementState: Equatable {
        case idle
        case searching
        case candidate(name: String, identifier: String)
        case activating(message: String)
        case warming(startDate: Date, readyAt: Date, lastCommunicationDate: Date?)
        case verificationRequired(startDate: Date, referenceGlucose: Double, candidateGlucose: Double)
        case reacquiring(startDate: Date, receivedReadingCount: Int)
        case completed(startDate: Date)
        case failed(message: String)
    }

    private struct State {
        var peripheralIdentifier: UUID
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
        var lastDeliveredMinute: UInt16?
        var lastDeliveredGlucose: Double?
        var lastDeliveredGlucoseDate: Date?
        var derivedTrendRate: Double?
        var lastEstimateUsedRegularization = false
        var regularizationEnabled = false
        var regularizer = SmartGlucoseRegularizer()
        var isBackfillRunning = false
        var lastBackfillDate: Date?
        var lastBackfillRecordCount: Int?
        var lastBackfillError: String?
        var sensorReplacementState: SensorReplacementState = .idle
        var sensorReplacementCandidate: SmartAdvertisementScanner.ActivationCandidate?
        var pendingPeripheralIdentifier: UUID?
        var pendingSensorName: String?
        var pendingSessionAnchor: Date?
        var pendingLastMinutes: UInt16?
        var pendingLastChecksum: UInt32?
        var pendingLastCommunicationDate: Date?
        var pendingReliableReadingCount = 0
        var handoverVerificationReferenceGlucose: Double?
        var handoverVerificationCandidateGlucose: Double?
        var handoverVerificationDetectedAt: Date?
        var handoverReacquisitionStartedAt: Date?
        var handoverReacquisitionDeliveredCount = 0
    }

    private struct DisplayState: GlucoseDisplayable {
        let isStateValid: Bool
        let trendType: GlucoseTrend?
        let trendRate: HKQuantity?
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
        scheduleReplacementNotificationsIfNeeded()
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
        if let value = rawState["lastDeliveredMinute"] as? Int {
            state.lastDeliveredMinute = UInt16(exactly: value)
        }
        if let value = rawState["lastDeliveredGlucose"] as? Double {
            state.lastDeliveredGlucose = value
        }
        if let interval = rawState["lastDeliveredGlucoseDate"] as? TimeInterval {
            state.lastDeliveredGlucoseDate = Date(timeIntervalSince1970: interval)
        }
        state.derivedTrendRate = rawState["derivedTrendRate"] as? Double
        state.lastEstimateUsedRegularization = rawState["lastEstimateUsedRegularization"] as? Bool ?? false
        state.regularizationEnabled = rawState["regularizationEnabled"] as? Bool ?? false
        if let interval = rawState["lastBackfillDate"] as? TimeInterval {
            state.lastBackfillDate = Date(timeIntervalSince1970: interval)
        }
        state.lastBackfillRecordCount = rawState["lastBackfillRecordCount"] as? Int

        if
            let identifierString = rawState["pendingPeripheralIdentifier"] as? String,
            let pendingIdentifier = UUID(uuidString: identifierString),
            pendingIdentifier != peripheralIdentifier,
            let interval = rawState["pendingSessionAnchor"] as? TimeInterval
        {
            let pendingSessionAnchor = Date(timeIntervalSince1970: interval)
            state.pendingPeripheralIdentifier = pendingIdentifier
            state.pendingSensorName = rawState["pendingSensorName"] as? String
            state.pendingSessionAnchor = pendingSessionAnchor
            if let value = rawState["pendingLastMinutes"] as? Int {
                state.pendingLastMinutes = UInt16(exactly: value)
            }
            if let value = rawState["pendingLastChecksum"] as? Int {
                state.pendingLastChecksum = UInt32(exactly: value)
            }
            if let interval = rawState["pendingLastCommunicationDate"] as? TimeInterval {
                state.pendingLastCommunicationDate = Date(timeIntervalSince1970: interval)
            }
            state.pendingReliableReadingCount = min(
                SmartSensorHandoverPolicy.requiredConsecutiveReliableReadings,
                max(0, rawState["pendingReliableReadingCount"] as? Int ?? 0)
            )
            state.sensorReplacementState = .warming(
                startDate: pendingSessionAnchor,
                readyAt: pendingSessionAnchor.addingTimeInterval(Self.warmupPeriod),
                lastCommunicationDate: state.pendingLastCommunicationDate
            )
        }

        if
            let reacquisitionStartedAtInterval = rawState["handoverReacquisitionStartedAt"] as? TimeInterval,
            let sessionStartDate = state.sensorSessionAnchor
        {
            state.handoverReacquisitionStartedAt = Date(timeIntervalSince1970: reacquisitionStartedAtInterval)
            state.handoverReacquisitionDeliveredCount = min(
                SmartHandoverReacquisitionPolicy.requiredDeliveredReadings,
                max(0, rawState["handoverReacquisitionDeliveredCount"] as? Int ?? 0)
            )
            state.sensorReplacementState = .reacquiring(
                startDate: sessionStartDate,
                receivedReadingCount: state.handoverReacquisitionDeliveredCount
            )
        }

        if
            let referenceGlucose = rawState["handoverVerificationReferenceGlucose"] as? Double,
            let candidateGlucose = rawState["handoverVerificationCandidateGlucose"] as? Double,
            let detectedAtInterval = rawState["handoverVerificationDetectedAt"] as? TimeInterval,
            let sessionStartDate = state.sensorSessionAnchor
        {
            let detectedAt = Date(timeIntervalSince1970: detectedAtInterval)
            state.handoverVerificationReferenceGlucose = referenceGlucose
            state.handoverVerificationCandidateGlucose = candidateGlucose
            state.handoverVerificationDetectedAt = detectedAt
            state.sensorReplacementState = .verificationRequired(
                startDate: sessionStartDate,
                referenceGlucose: referenceGlucose,
                candidateGlucose: candidateGlucose
            )
        }

        if
            let minutes = rawState["minuteHistoryMinutes"] as? [Int],
            let glucose = rawState["minuteHistoryGlucose"] as? [Double],
            let quality = rawState["minuteHistoryQuality"] as? [Int],
            minutes.count == glucose.count,
            glucose.count == quality.count
        {
            state.regularizer = SmartGlucoseRegularizer(
                samples: zip(zip(minutes, glucose), quality).compactMap { item in
                    guard
                        let minute = UInt16(exactly: item.0.0),
                        let sampleQuality = UInt8(exactly: item.1)
                    else {
                        return nil
                    }
                    return SmartGlucoseRegularizer.Sample(
                        minutesSinceStart: minute,
                        glucose: item.0.1,
                        quality: sampleQuality
                    )
                }
            )
        }

        lockedState = Locked(state)
        if
            let referenceGlucose = state.handoverVerificationReferenceGlucose,
            let candidateGlucose = state.handoverVerificationCandidateGlucose,
            let detectedAt = state.handoverVerificationDetectedAt ?? state.handoverReacquisitionStartedAt
        {
            CGMAutomaticInsulinSafetyInterlock.activate(
                .init(
                    sensorIdentifier: state.peripheralIdentifier.uuidString,
                    referenceGlucose: referenceGlucose,
                    candidateGlucose: candidateGlucose,
                    detectedAt: detectedAt,
                    phase: state.handoverReacquisitionStartedAt == nil
                        ? .divergenceVerification
                        : .reacquiring
                )
            )
        }
        scanner.start()
        scheduleReplacementNotificationsIfNeeded()
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
        raw["lastDeliveredMinute"] = state.lastDeliveredMinute.map { Int($0) }
        raw["lastDeliveredGlucose"] = state.lastDeliveredGlucose
        raw["lastDeliveredGlucoseDate"] = state.lastDeliveredGlucoseDate?.timeIntervalSince1970
        raw["derivedTrendRate"] = state.derivedTrendRate
        raw["lastEstimateUsedRegularization"] = state.lastEstimateUsedRegularization
        raw["regularizationEnabled"] = state.regularizationEnabled
        raw["lastBackfillDate"] = state.lastBackfillDate?.timeIntervalSince1970
        raw["lastBackfillRecordCount"] = state.lastBackfillRecordCount
        raw["pendingPeripheralIdentifier"] = state.pendingPeripheralIdentifier?.uuidString
        raw["pendingSensorName"] = state.pendingSensorName
        raw["pendingSessionAnchor"] = state.pendingSessionAnchor?.timeIntervalSince1970
        raw["pendingLastMinutes"] = state.pendingLastMinutes.map { Int($0) }
        raw["pendingLastChecksum"] = state.pendingLastChecksum.map { Int($0) }
        raw["pendingLastCommunicationDate"] = state.pendingLastCommunicationDate?.timeIntervalSince1970
        raw["pendingReliableReadingCount"] = state.pendingReliableReadingCount
        raw["handoverVerificationReferenceGlucose"] = state.handoverVerificationReferenceGlucose
        raw["handoverVerificationCandidateGlucose"] = state.handoverVerificationCandidateGlucose
        raw["handoverVerificationDetectedAt"] = state.handoverVerificationDetectedAt?.timeIntervalSince1970
        raw["handoverReacquisitionStartedAt"] = state.handoverReacquisitionStartedAt?.timeIntervalSince1970
        raw["handoverReacquisitionDeliveredCount"] = state.handoverReacquisitionDeliveredCount
        raw["minuteHistoryMinutes"] = state.regularizer.samples.map { Int($0.minutesSinceStart) }
        raw["minuteHistoryGlucose"] = state.regularizer.samples.map(\.glucose)
        raw["minuteHistoryQuality"] = state.regularizer.samples.map { Int($0.quality) }
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
        return DisplayState(
            isStateValid: isRecent,
            trendType: Self.glucoseTrend(for: state.derivedTrendRate),
            trendRate: Self.trendQuantity(for: state.derivedTrendRate)
        )
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
        let state = lockedState.value
        CGMAutomaticInsulinSafetyInterlock.clear(
            sensorIdentifier: state.peripheralIdentifier.uuidString
        )
        cancelReplacementNotifications(for: state.peripheralIdentifier)
        if let pendingIdentifier = state.pendingPeripheralIdentifier {
            cancelReplacementNotifications(for: pendingIdentifier)
        }
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
                localizedMessage: String(localized: "Aguardando\nsensor"),
                imageName: "dot.radiowaves.left.and.right",
                state: .normalCGM
            )
        }
        guard Date().timeIntervalSince(lastCommunication) >= .minutes(8) else { return nil }
        return SmartStatusHighlight(
            localizedMessage: String(localized: "Sem sinal\nFeche o Smart"),
            imageName: "exclamationmark.circle.fill",
            state: .warning
        )
    }

    var cgmLifecycleProgress: DeviceLifecycleProgress? {
        guard let anchor = lockedState.value.sensorSessionAnchor else { return nil }
        let lifetime = Self.sensorLifetime
        let elapsed = max(0, Date().timeIntervalSince(anchor))
        let remaining = max(0, lifetime - elapsed)
        guard remaining < .hours(72) else { return nil }
        return SmartLifecycleProgress(
            percentComplete: min(1, elapsed / lifetime),
            progressState: remaining < .hours(24) ? .warning : .normalCGM
        )
    }

    var cgmStatusBadge: DeviceStatusBadge? { nil }

    private func replacementReminderIdentifier(
        for peripheralIdentifier: UUID,
        kind: SmartSensorReminderPolicy.Kind
    ) -> String {
        Self.replacementReminderPrefix + kind.rawValue + "." + peripheralIdentifier.uuidString
    }

    private func replacementCompletedIdentifier(for peripheralIdentifier: UUID) -> String {
        Self.replacementCompletedPrefix + peripheralIdentifier.uuidString
    }

    private func handoverVerificationIdentifier(for peripheralIdentifier: UUID) -> String {
        Self.handoverVerificationPrefix + peripheralIdentifier.uuidString
    }

    private func allReplacementNotificationIdentifiers(
        for peripheralIdentifier: UUID
    ) -> [String] {
        let reminders = SmartSensorReminderPolicy.Kind.allCases.map {
            replacementReminderIdentifier(for: peripheralIdentifier, kind: $0)
        }
        return reminders + [
            Self.legacyReplacementReminderPrefix + peripheralIdentifier.uuidString,
            replacementCompletedIdentifier(for: peripheralIdentifier),
            handoverVerificationIdentifier(for: peripheralIdentifier)
        ]
    }

    private func scheduleReplacementNotificationsIfNeeded(now: Date = Date()) {
        let state = lockedState.value
        let identifiers = allReplacementNotificationIdentifiers(for: state.peripheralIdentifier)

        guard state.pendingPeripheralIdentifier == nil else {
            cancelReplacementNotifications(for: state.peripheralIdentifier)
            return
        }
        guard let sessionAnchor = state.sensorSessionAnchor else { return }

        let expiresAt = sessionAnchor.addingTimeInterval(Self.sensorLifetime)
        guard expiresAt > now else {
            cancelReplacementNotifications(for: state.peripheralIdentifier)
            return
        }

        let requests = SmartSensorReminderPolicy.notifications(
            expiresAt: expiresAt,
            now: now
        ).map { notification in
            let content = UNMutableNotificationContent()
            content.title = notification.kind.title
            content.body = notification.kind.body
            content.sound = .default
            return UNNotificationRequest(
                identifier: replacementReminderIdentifier(
                    for: state.peripheralIdentifier,
                    kind: notification.kind
                ),
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(
                    timeInterval: max(2, notification.deliveryDate.timeIntervalSince(now)),
                    repeats: false
                )
            )
        }

        DispatchQueue.main.async {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            requests.forEach { center.add($0) }
        }
    }

    private func cancelReplacementNotifications(for peripheralIdentifier: UUID) {
        let identifiers = allReplacementNotificationIdentifiers(for: peripheralIdentifier)
        DispatchQueue.main.async {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    private func notifySuccessfulHandover(for peripheralIdentifier: UUID) {
        let identifier = replacementCompletedIdentifier(for: peripheralIdentifier)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Novo Smart ativo")
        content.body = String(
            localized: "O aquecimento terminou, a troca automática foi concluída e a primeira glicemia foi recebida com sucesso."
        )
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        DispatchQueue.main.async {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            center.add(request)
        }
    }

    private func notifyHandoverVerificationRequired(
        for peripheralIdentifier: UUID,
        referenceGlucose: Double,
        candidateGlucose: Double
    ) {
        let identifier = handoverVerificationIdentifier(for: peripheralIdentifier)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Confirme a glicemia antes da insulina")
        content.body = String(
            localized: "A troca do Smart mostrou \(Int(referenceGlucose.rounded())) e \(Int(candidateGlucose.rounded())) mg/dL. A insulina automática está protegida. Faça uma ponta de dedo e registre a calibração no Trio."
        )
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        DispatchQueue.main.async {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            center.add(request)
        }
    }

    private func notifyAutomaticHandoverRelease(for peripheralIdentifier: UUID) {
        let identifier = replacementCompletedIdentifier(for: peripheralIdentifier)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Novo Smart assumido pelo Trio")
        content.body = String(
            localized: "O período de segurança terminou e o novo sensor passou a ser a referência. O algoritmo aguardará três glicemias recentes antes de retomar a insulina automática."
        )
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func notifyAutomaticInsulinResumed(for peripheralIdentifier: UUID) {
        let identifier = replacementCompletedIdentifier(for: peripheralIdentifier)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Novo Smart validado")
        content.body = String(
            localized: "Três glicemias do novo sensor foram recebidas. A proteção temporária terminou e o tratamento automático pode ser retomado usando o novo Smart como referência."
        )
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func clearHandoverVerificationNotification(for peripheralIdentifier: UUID) {
        let identifier = handoverVerificationIdentifier(for: peripheralIdentifier)
        DispatchQueue.main.async {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
        }
    }

    private func handle(_ reading: SmartAdvertisementScanner.Reading) {
        let state = lockedState.value
        if state.peripheralIdentifier == reading.peripheralIdentifier {
            handleActiveReading(reading)
        } else if state.pendingPeripheralIdentifier == reading.peripheralIdentifier {
            handlePendingReading(reading)
        }
    }

    private func handleActiveReading(_ reading: SmartAdvertisementScanner.Reading) {
        let advertisement = reading.advertisement

        let packetStateIsReliable = advertisement.status == 0 &&
            advertisement.calibrationTemperatureStatus == 0

        var isDuplicate = false
        var sessionAnchor: Date!
        var emittedEstimate: SmartGlucoseRegularizer.Estimate?
        var emittedMinute: UInt16?
        var sensorSessionDidChange = false
        var handoverVerificationIsRequired = false
        var handoverWasAutomaticallyReleased = false
        var handoverReacquisitionWasCompleted = false
        var releasedSensorIdentifier: UUID?

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

            if state.sensorSessionAnchor == nil ||
                state.lastMinutes.map({ advertisement.minutesSinceStart + 5 < $0 }) == true
            {
                let inferredAnchor = reading.receivedAt.addingTimeInterval(
                    -.minutes(Double(advertisement.minutesSinceStart))
                )
                state.sensorSessionAnchor = Date(
                    timeIntervalSince1970: floor(inferredAnchor.timeIntervalSince1970 / 60) * 60
                )
                state.lastDeliveredMinute = nil
                state.lastDeliveredGlucose = nil
                state.lastDeliveredGlucoseDate = nil
                state.regularizer.reset()
                sensorSessionDidChange = true
            }

            state.lastMinutes = advertisement.minutesSinceStart
            state.lastChecksum = advertisement.checksum
            state.regularizer.ingest(
                advertisement.chronologicalRecords,
                packetStateIsReliable: packetStateIsReliable
            )

            if packetStateIsReliable, Self.isReliable(advertisement.current) {
                state.currentGlucose = Double(advertisement.current.glucose)
                state.currentGlucoseDate = state.sensorSessionAnchor?.addingTimeInterval(
                    .minutes(Double(advertisement.minutesSinceStart))
                )
            }

            if
                let detectedAt = state.handoverVerificationDetectedAt,
                SmartHandoverDivergencePolicy.shouldAutomaticallyRelease(
                    detectedAt: detectedAt,
                    now: reading.receivedAt,
                    recentReliableGlucoseValues: state.regularizer.samples.map(\.glucose)
                )
            {
                state.handoverVerificationDetectedAt = nil
                state.handoverReacquisitionStartedAt = reading.receivedAt
                state.handoverReacquisitionDeliveredCount = 0
                state.lastDeliveredMinute = nil
                if let sessionStartDate = state.sensorSessionAnchor {
                    state.sensorReplacementState = .reacquiring(
                        startDate: sessionStartDate,
                        receivedReadingCount: 0
                    )
                }
                handoverWasAutomaticallyReleased = true
                releasedSensorIdentifier = state.peripheralIdentifier
            }

            if let estimate = state.regularizer.estimate(
                at: advertisement.minutesSinceStart,
                regularizationEnabled: state.regularizationEnabled
            ) {
                state.derivedTrendRate = estimate.trendRate
                handoverVerificationIsRequired = state.handoverVerificationDetectedAt != nil
                if !handoverVerificationIsRequired, SmartDeliveryCadence.shouldDeliver(
                    currentMinute: advertisement.minutesSinceStart,
                    lastDeliveredMinute: state.lastDeliveredMinute
                ) {
                    emittedEstimate = estimate
                    emittedMinute = advertisement.minutesSinceStart
                    state.lastDeliveredMinute = advertisement.minutesSinceStart
                    state.lastDeliveredGlucose = estimate.glucose
                    state.lastDeliveredGlucoseDate = state.sensorSessionAnchor?.addingTimeInterval(
                        .minutes(Double(advertisement.minutesSinceStart))
                    )
                    state.lastEstimateUsedRegularization = estimate.usedRegularization

                    if state.handoverReacquisitionStartedAt != nil {
                        state.handoverReacquisitionDeliveredCount = SmartHandoverReacquisitionPolicy
                            .updatedDeliveredReadingCount(
                                previousCount: state.handoverReacquisitionDeliveredCount
                            )
                        if let sessionStartDate = state.sensorSessionAnchor {
                            state.sensorReplacementState = .reacquiring(
                                startDate: sessionStartDate,
                                receivedReadingCount: state.handoverReacquisitionDeliveredCount
                            )
                        }

                        if SmartHandoverReacquisitionPolicy.canResumeAutomaticInsulin(
                            deliveredReadingCount: state.handoverReacquisitionDeliveredCount
                        ) {
                            state.handoverVerificationReferenceGlucose = nil
                            state.handoverVerificationCandidateGlucose = nil
                            state.handoverReacquisitionStartedAt = nil
                            state.handoverReacquisitionDeliveredCount = 0
                            if let sessionStartDate = state.sensorSessionAnchor {
                                state.sensorReplacementState = .completed(startDate: sessionStartDate)
                            }
                            handoverReacquisitionWasCompleted = true
                            releasedSensorIdentifier = state.peripheralIdentifier
                        }
                    }
                }
            }
            sessionAnchor = state.sensorSessionAnchor
        }

        guard !isDuplicate else { return }

        if handoverWasAutomaticallyReleased, let releasedSensorIdentifier {
            CGMAutomaticInsulinSafetyInterlock.beginReacquisition(
                sensorIdentifier: releasedSensorIdentifier.uuidString
            )
            clearHandoverVerificationNotification(for: releasedSensorIdentifier)
            notifyAutomaticHandoverRelease(for: releasedSensorIdentifier)
        }

        if handoverReacquisitionWasCompleted, let releasedSensorIdentifier {
            CGMAutomaticInsulinSafetyInterlock.clear(
                sensorIdentifier: releasedSensorIdentifier.uuidString
            )
            notifyAutomaticInsulinResumed(for: releasedSensorIdentifier)
        }

        // Keep the Smart detail screen current without causing Trio to persist
        // the full manager state and run its glucose pipeline every minute.
        notifyLocalStateChanged()

        if sensorSessionDidChange || handoverWasAutomaticallyReleased || handoverReacquisitionWasCompleted ||
            !packetStateIsReliable || emittedEstimate != nil
        {
            notifyDelegateStateChanged()
        }

        if sensorSessionDidChange {
            Foundation.NotificationCenter.default.post(name: .smartSensorDidChange, object: self)
            scheduleReplacementNotificationsIfNeeded()
            let event = PersistedCgmEvent(
                date: sessionAnchor,
                type: .sensorStart,
                deviceIdentifier: reading.peripheralIdentifier.uuidString,
                expectedLifetime: Self.sensorLifetime,
                warmupPeriod: Self.warmupPeriod
            )
            delegate.notify { $0?.cgmManager(self, hasNew: [event]) }
        }

        guard packetStateIsReliable else {
            delegate.notify { $0?.cgmManager(self, hasNew: .unreliableData) }
            return
        }

        // Keep the new Smart visible for fingerstick comparison, but do not
        // enter the glucose/algorithm pipeline while the safety interlock is active.
        guard !handoverVerificationIsRequired else { return }

        guard let emittedEstimate, let emittedMinute else { return }

        let sample = NewGlucoseSample(
            date: sessionAnchor.addingTimeInterval(.minutes(Double(emittedMinute))),
            quantity: HKQuantity(
                unit: .milligramsPerDeciliter,
                doubleValue: emittedEstimate.glucose
            ),
            condition: nil,
            trend: Self.glucoseTrend(for: emittedEstimate.trendRate),
            trendRate: Self.trendQuantity(for: emittedEstimate.trendRate),
            isDisplayOnly: false,
            wasUserEntered: false,
            syncIdentifier: "smart-\(Int(sessionAnchor.timeIntervalSince1970.rounded()))-\(emittedMinute)",
            device: Self.device
        )

        delegate.notify { $0?.cgmManager(self, hasNew: .newData([sample])) }
    }

    private func handlePendingReading(_ reading: SmartAdvertisementScanner.Reading) {
        let advertisement = reading.advertisement
        let packetStateIsReliable = advertisement.status == 0 &&
            advertisement.calibrationTemperatureStatus == 0
        let currentRecordIsReliable = Self.isReliable(advertisement.current)

        var wasHandled = false
        var isDuplicate = false
        var shouldPersist = false
        var shouldHandover = false

        lockedState.mutate { state in
            guard
                state.pendingPeripheralIdentifier == reading.peripheralIdentifier,
                let pendingSessionAnchor = state.pendingSessionAnchor
            else {
                return
            }
            wasHandled = true

            isDuplicate = state.pendingLastMinutes == advertisement.minutesSinceStart &&
                state.pendingLastChecksum == advertisement.checksum
            guard !isDuplicate else { return }

            let previousMinute = state.pendingLastMinutes
            let previousReliableReadingCount = state.pendingReliableReadingCount
            state.pendingSensorName = reading.localName ?? state.pendingSensorName
            state.pendingLastMinutes = advertisement.minutesSinceStart
            state.pendingLastChecksum = advertisement.checksum
            state.pendingLastCommunicationDate = reading.receivedAt
            state.pendingReliableReadingCount = SmartSensorHandoverPolicy.updatedReliableReadingCount(
                previousCount: previousReliableReadingCount,
                minutesSinceStart: advertisement.minutesSinceStart,
                packetStateIsReliable: packetStateIsReliable,
                currentRecordIsReliable: currentRecordIsReliable
            )
            state.sensorReplacementState = .warming(
                startDate: pendingSessionAnchor,
                readyAt: pendingSessionAnchor.addingTimeInterval(Self.warmupPeriod),
                lastCommunicationDate: reading.receivedAt
            )

            shouldHandover = SmartSensorHandoverPolicy.shouldHandover(
                reliableReadingCount: state.pendingReliableReadingCount
            )
            shouldPersist = previousMinute == nil ||
                advertisement.minutesSinceStart.isMultiple(of: 5) ||
                previousReliableReadingCount != state.pendingReliableReadingCount
        }

        guard wasHandled, !isDuplicate else { return }
        notifyLocalStateChanged()

        if shouldHandover {
            handoverToPendingSensor(using: reading)
        } else if shouldPersist {
            // Persist only meaningful warmup milestones. Minute-by-minute UI
            // updates remain local, preserving the passive scanner's battery benefit.
            notifyDelegateStateChanged()
        }
    }

    private func handoverToPendingSensor(
        using reading: SmartAdvertisementScanner.Reading
    ) {
        var oldPeripheralIdentifier: UUID?
        var sessionStartDate: Date?
        var divergenceAssessment: SmartHandoverDivergencePolicy.Assessment?
        var requiresFingerstickConfirmation = false

        lockedState.mutate { state in
            guard
                state.pendingPeripheralIdentifier == reading.peripheralIdentifier,
                let pendingSessionAnchor = state.pendingSessionAnchor,
                SmartSensorHandoverPolicy.shouldHandover(
                    reliableReadingCount: state.pendingReliableReadingCount
                )
            else {
                return
            }

            oldPeripheralIdentifier = state.peripheralIdentifier
            sessionStartDate = pendingSessionAnchor
            if
                let referenceGlucose = state.currentGlucose,
                let referenceDate = state.currentGlucoseDate,
                abs(reading.receivedAt.timeIntervalSince(referenceDate)) <= .minutes(10)
            {
                divergenceAssessment = SmartHandoverDivergencePolicy.assess(
                    referenceGlucose: referenceGlucose,
                    candidateGlucoseValues: reading.advertisement.chronologicalRecords
                        .filter { Self.isReliable($0.record) }
                        .map { Double($0.record.glucose) }
                )
                requiresFingerstickConfirmation = divergenceAssessment?
                    .requiresFingerstickConfirmation == true
            }
            state.peripheralIdentifier = reading.peripheralIdentifier
            state.sensorName = reading.localName ?? state.pendingSensorName ?? "Smart 2.0"
            state.sensorSessionAnchor = pendingSessionAnchor
            state.lastMinutes = nil
            state.lastChecksum = nil
            state.lastStatus = nil
            state.lastCalibrationTemperatureStatus = nil
            state.lastTrend = nil
            state.lastQuality = nil
            state.lastRSSI = nil
            state.lastCommunicationDate = nil
            state.currentGlucose = nil
            state.currentGlucoseDate = nil
            state.lastDeliveredMinute = nil
            state.lastDeliveredGlucose = nil
            state.lastDeliveredGlucoseDate = nil
            state.derivedTrendRate = nil
            state.lastEstimateUsedRegularization = false
            state.regularizer.reset()
            state.isBackfillRunning = false
            state.lastBackfillDate = nil
            state.lastBackfillRecordCount = nil
            state.lastBackfillError = nil
            state.sensorReplacementCandidate = nil
            state.pendingPeripheralIdentifier = nil
            state.pendingSensorName = nil
            state.pendingSessionAnchor = nil
            state.pendingLastMinutes = nil
            state.pendingLastChecksum = nil
            state.pendingLastCommunicationDate = nil
            state.pendingReliableReadingCount = 0
            state.handoverReacquisitionStartedAt = nil
            state.handoverReacquisitionDeliveredCount = 0
            if requiresFingerstickConfirmation, let divergenceAssessment {
                state.handoverVerificationReferenceGlucose = divergenceAssessment.referenceGlucose
                state.handoverVerificationCandidateGlucose = divergenceAssessment.candidateGlucose
                state.handoverVerificationDetectedAt = reading.receivedAt
                state.sensorReplacementState = .verificationRequired(
                    startDate: pendingSessionAnchor,
                    referenceGlucose: divergenceAssessment.referenceGlucose,
                    candidateGlucose: divergenceAssessment.candidateGlucose
                )
            } else {
                state.handoverVerificationReferenceGlucose = nil
                state.handoverVerificationCandidateGlucose = nil
                state.handoverVerificationDetectedAt = nil
                state.sensorReplacementState = .completed(startDate: pendingSessionAnchor)
            }
        }

        guard let oldPeripheralIdentifier, let sessionStartDate else { return }
        if requiresFingerstickConfirmation, let divergenceAssessment {
            CGMAutomaticInsulinSafetyInterlock.activate(
                .init(
                    sensorIdentifier: reading.peripheralIdentifier.uuidString,
                    referenceGlucose: divergenceAssessment.referenceGlucose,
                    candidateGlucose: divergenceAssessment.candidateGlucose,
                    detectedAt: reading.receivedAt,
                    phase: .divergenceVerification
                )
            )
        } else {
            CGMAutomaticInsulinSafetyInterlock.clear(
                sensorIdentifier: reading.peripheralIdentifier.uuidString
            )
        }
        cancelReplacementNotifications(for: oldPeripheralIdentifier)
        scheduleReplacementNotificationsIfNeeded()
        Foundation.NotificationCenter.default.post(name: .smartSensorDidChange, object: self)
        notifyStateChanged()

        let event = PersistedCgmEvent(
            date: sessionStartDate,
            type: .sensorStart,
            deviceIdentifier: reading.peripheralIdentifier.uuidString,
            expectedLifetime: Self.sensorLifetime,
            warmupPeriod: Self.warmupPeriod
        )
        delegate.notify { $0?.cgmManager(self, hasNew: [event]) }

        // Reuse the already validated packet as the first reading from the new
        // active sensor. The previous sensor is ignored from this point onward.
        handleActiveReading(reading)
        if requiresFingerstickConfirmation, let divergenceAssessment {
            delegate.notify { $0?.cgmManager(self, hasNew: .unreliableData) }
            notifyHandoverVerificationRequired(
                for: reading.peripheralIdentifier,
                referenceGlucose: divergenceAssessment.referenceGlucose,
                candidateGlucose: divergenceAssessment.candidateGlucose
            )
        } else {
            notifySuccessfulHandover(for: reading.peripheralIdentifier)
        }
    }

    private static func isReliable(_ record: SmartAdvertisement.GlucoseRecord) -> Bool {
        record.isValid &&
            record.quality > 0 &&
            (20 ... 600).contains(Int(record.glucose))
    }

    private static func glucoseTrend(for rate: Double?) -> GlucoseTrend? {
        guard let rate else { return nil }
        if rate >= 3 { return .upUpUp }
        if rate >= 2 { return .upUp }
        if rate >= 1 { return .up }
        if rate > -1 { return .flat }
        if rate > -2 { return .down }
        if rate > -3 { return .downDown }
        return .downDownDown
    }

    private static func trendQuantity(for rate: Double?) -> HKQuantity? {
        rate.map {
            HKQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0)
        }
    }

    fileprivate func setRegularizationEnabled(_ enabled: Bool) {
        lockedState.mutate { state in
            state.regularizationEnabled = enabled
        }
        notifyStateChanged()
    }

    fileprivate func beginSensorReplacement() {
        let currentState = lockedState.value
        if
            let pendingSessionAnchor = currentState.pendingSessionAnchor,
            currentState.pendingPeripheralIdentifier != nil
        {
            lockedState.mutate { state in
                state.sensorReplacementState = .warming(
                    startDate: pendingSessionAnchor,
                    readyAt: pendingSessionAnchor.addingTimeInterval(Self.warmupPeriod),
                    lastCommunicationDate: state.pendingLastCommunicationDate
                )
            }
            notifyLocalStateChanged()
            return
        }

        let currentIdentifier = currentState.peripheralIdentifier
        lockedState.mutate { state in
            state.sensorReplacementCandidate = nil
            state.sensorReplacementState = .searching
        }
        notifyLocalStateChanged()

        scanner.discoverActivationCandidate(excluding: currentIdentifier) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(candidate):
                self.lockedState.mutate { state in
                    state.sensorReplacementCandidate = candidate
                    state.sensorReplacementState = .candidate(
                        name: candidate.localName ?? "Smart 2.0",
                        identifier: String(candidate.peripheralIdentifier.uuidString.prefix(8))
                    )
                }
                self.notifyLocalStateChanged()

            case let .failure(error):
                if self.shouldIgnoreReplacementCancellation(error) { return }
                self.lockedState.mutate { state in
                    state.sensorReplacementCandidate = nil
                    state.sensorReplacementState = .failed(message: error.localizedDescription)
                }
                self.notifyLocalStateChanged()
            }
        }
    }

    fileprivate func activateReplacementSensor() {
        guard let candidate = lockedState.value.sensorReplacementCandidate else { return }
        lockedState.mutate { state in
            state.sensorReplacementState = .activating(message: String(localized: "Conectando ao novo Smart…"))
        }
        notifyLocalStateChanged()

        scanner.activate(
            candidate: candidate,
            progress: { [weak self] phase in
                guard let self else { return }
                let message: String
                switch phase {
                case .connecting:
                    message = String(localized: "Conectando ao novo Smart…")
                case .checkingSensor:
                    message = String(localized: "Validando o novo sensor…")
                case .startingSession:
                    message = String(localized: "Iniciando a nova sessão…")
                case .synchronizingTime:
                    message = String(localized: "Sincronizando horário e aquecimento…")
                }
                self.lockedState.mutate { state in
                    state.sensorReplacementState = .activating(message: message)
                }
                self.notifyLocalStateChanged()
            },
            completion: { [weak self] result in
                self?.completeSensorReplacement(result)
            }
        )
    }

    fileprivate func cancelSensorReplacement() {
        var shouldCancelBluetoothOperation = false
        lockedState.mutate { state in
            switch state.sensorReplacementState {
            case .completed,
                 .reacquiring,
                 .verificationRequired,
                 .warming:
                return
            default:
                shouldCancelBluetoothOperation = true
            }
            state.sensorReplacementCandidate = nil
            state.sensorReplacementState = .idle
        }
        guard shouldCancelBluetoothOperation else { return }
        notifyLocalStateChanged()
        scanner.cancelActivationDiscovery()
        scanner.cancelActivation()
    }

    private func completeSensorReplacement(
        _ result: Result<SmartAdvertisementScanner.ActivationResult, Error>
    ) {
        switch result {
        case let .success(result):
            let sessionStartDate = Date(
                timeIntervalSince1970: floor(result.sessionStartDate.timeIntervalSince1970 / 60) * 60
            )
            lockedState.mutate { state in
                state.sensorReplacementCandidate = nil
                state.pendingPeripheralIdentifier = result.peripheralIdentifier
                state.pendingSensorName = result.localName ?? "Smart 2.0"
                state.pendingSessionAnchor = sessionStartDate
                state.pendingLastMinutes = nil
                state.pendingLastChecksum = nil
                state.pendingLastCommunicationDate = result.sessionStartDate
                state.pendingReliableReadingCount = 0
                state.sensorReplacementState = .warming(
                    startDate: sessionStartDate,
                    readyAt: sessionStartDate.addingTimeInterval(Self.warmupPeriod),
                    lastCommunicationDate: result.sessionStartDate
                )
            }
            cancelReplacementNotifications(for: lockedState.value.peripheralIdentifier)
            notifyStateChanged()

        case let .failure(error):
            if shouldIgnoreReplacementCancellation(error) { return }
            lockedState.mutate { state in
                state.sensorReplacementState = .failed(message: error.localizedDescription)
            }
            notifyLocalStateChanged()
        }
    }

    private func shouldIgnoreReplacementCancellation(_ error: Error) -> Bool {
        guard let activationError = error as? SmartAdvertisementScanner.ActivationError else {
            return false
        }
        guard case .cancelled = activationError else { return false }
        guard case .idle = lockedState.value.sensorReplacementState else { return false }
        return true
    }

    fileprivate func requestBackfill() {
        var context: (peripheralIdentifier: UUID, sessionAnchor: Date, currentMinute: UInt16)?
        lockedState.mutate { state in
            guard !state.isBackfillRunning else { return }
            guard
                let sessionAnchor = state.sensorSessionAnchor,
                let currentMinute = state.lastMinutes
            else {
                state.lastBackfillError =
                    String(localized: "Aguarde uma leitura atual do Smart antes de recuperar o histórico.")
                return
            }

            state.isBackfillRunning = true
            state.lastBackfillError = nil
            context = (
                peripheralIdentifier: state.peripheralIdentifier,
                sessionAnchor: sessionAnchor,
                currentMinute: currentMinute
            )
        }
        notifyStateChanged()

        guard let context else { return }
        let minimumTimeOffset = context.currentMinute > SmartBackfillSelector.maximumAgeMinutes
            ? context.currentMinute - SmartBackfillSelector.maximumAgeMinutes
            : 0

        scanner.requestBackfill(
            peripheralIdentifier: context.peripheralIdentifier,
            minimumTimeOffset: minimumTimeOffset
        ) { [weak self] result in
            self?.completeBackfill(result, context: context)
        }
    }

    private func completeBackfill(
        _ result: Result<[SmartCGMMeasurement], Error>,
        context: (peripheralIdentifier: UUID, sessionAnchor: Date, currentMinute: UInt16)
    ) {
        switch result {
        case let .success(records):
            guard lockedState.value.sensorSessionAnchor == context.sessionAnchor else {
                lockedState.mutate { state in
                    state.isBackfillRunning = false
                    state.lastBackfillError =
                        String(localized: "A sessão do sensor mudou durante a recuperação. Nenhuma leitura foi importada.")
                }
                notifyStateChanged()
                return
            }

            let selected = SmartBackfillSelector.select(
                records,
                endingAt: context.currentMinute
            )
            let importDate = Date()
            let earliestAcceptedDate = importDate.addingTimeInterval(-.hours(6))
            let latestAcceptedDate = importDate.addingTimeInterval(.minutes(2))
            let samples: [NewGlucoseSample] = selected.enumerated().compactMap { index, record -> NewGlucoseSample? in
                let date = context.sessionAnchor.addingTimeInterval(
                    .minutes(Double(record.timeOffset))
                )
                guard
                    date <= latestAcceptedDate,
                    date >= earliestAcceptedDate
                else {
                    return nil
                }

                let trendRate = record.trendRate ??
                    Self.backfillTrendRate(for: selected, at: index)
                return NewGlucoseSample(
                    date: date,
                    quantity: HKQuantity(
                        unit: .milligramsPerDeciliter,
                        doubleValue: record.glucose
                    ),
                    condition: nil,
                    trend: Self.glucoseTrend(for: trendRate),
                    trendRate: Self.trendQuantity(for: trendRate),
                    isDisplayOnly: false,
                    wasUserEntered: false,
                    syncIdentifier: "smart-\(Int(context.sessionAnchor.timeIntervalSince1970.rounded()))-\(record.timeOffset)",
                    device: Self.device
                )
            }

            lockedState.mutate { state in
                state.isBackfillRunning = false
                state.lastBackfillDate = importDate
                state.lastBackfillRecordCount = samples.count
                state.lastBackfillError = nil
            }
            notifyStateChanged()
            if !samples.isEmpty {
                delegate.notify { $0?.cgmManager(self, hasNew: .newData(samples)) }
            }

        case let .failure(error):
            lockedState.mutate { state in
                state.isBackfillRunning = false
                state.lastBackfillRecordCount = nil
                state.lastBackfillError = error.localizedDescription
            }
            notifyStateChanged()
        }
    }

    private static func backfillTrendRate(
        for records: [SmartCGMMeasurement],
        at index: Int
    ) -> Double? {
        let record = records[index]
        let comparison: SmartCGMMeasurement?
        if index > records.startIndex {
            comparison = records[index - 1]
        } else if records.indices.contains(index + 1) {
            comparison = records[index + 1]
        } else {
            comparison = nil
        }
        guard let comparison else { return nil }

        let elapsedMinutes = Double(Int(record.timeOffset) - Int(comparison.timeOffset))
        guard elapsedMinutes != 0 else { return nil }
        return (record.glucose - comparison.glucose) / elapsedMinutes
    }

    private func notifyLocalStateChanged() {
        Foundation.NotificationCenter.default.post(
            name: Self.stateDidChangeNotification,
            object: self
        )
    }

    private func notifyDelegateStateChanged() {
        delegate.notify { delegate in
            delegate?.cgmManagerDidUpdateState(self)
            delegate?.cgmManager(self, didUpdate: self.cgmManagerStatus)
        }
    }

    private func notifyStateChanged() {
        notifyLocalStateChanged()
        notifyDelegateStateChanged()
    }

    fileprivate struct SettingsSnapshot {
        let sensorName: String?
        let sessionAnchor: Date?
        let expiresAt: Date?
        let sessionProgress: Double?
        let sessionMinutes: UInt16?
        let status: UInt8?
        let calibrationTemperatureStatus: UInt8?
        let rawTrend: Int8?
        let quality: UInt8?
        let checksum: UInt32?
        let rssi: Int?
        let lastCommunicationDate: Date?
        let currentGlucose: Double?
        let currentGlucoseDate: Date?
        let lastDeliveredGlucose: Double?
        let lastDeliveredGlucoseDate: Date?
        let trendRate: Double?
        let trend: GlucoseTrend?
        let regularizationEnabled: Bool
        let lastEstimateUsedRegularization: Bool
        let minuteSampleCount: Int
        let isBackfillRunning: Bool
        let lastBackfillDate: Date?
        let lastBackfillRecordCount: Int?
        let lastBackfillError: String?
        let sensorReplacementState: SensorReplacementState
    }

    struct CalibrationSnapshot {
        let glucose: Double
        let date: Date
        let trendRate: Double?
    }

    struct SensorMetadata {
        let sessionStartDate: Date?
        let sensorIdentifier: String
    }

    func sensorMetadata() -> SensorMetadata {
        let state = lockedState.value
        return SensorMetadata(
            sessionStartDate: state.sensorSessionAnchor,
            sensorIdentifier: state.sensorName ?? state.peripheralIdentifier.uuidString
        )
    }

    func calibrationSnapshot() -> CalibrationSnapshot? {
        let state = lockedState.value
        guard let glucose = state.currentGlucose, let date = state.currentGlucoseDate else {
            return nil
        }
        return CalibrationSnapshot(
            glucose: glucose,
            date: date,
            trendRate: state.derivedTrendRate
        )
    }

    var isAwaitingHandoverConfirmation: Bool {
        lockedState.value.handoverVerificationDetectedAt != nil
    }

    /// Accepts the new Smart early after an explicit, stable fingerstick. Trio
    /// then admits the new sensor's readings while keeping automatic insulin
    /// protected until three of those readings have been delivered.
    @discardableResult func confirmHandoverAfterFingerstick() -> Bool {
        var sensorIdentifier: UUID?
        var sessionStartDate: Date?

        lockedState.mutate { state in
            guard state.handoverVerificationDetectedAt != nil else { return }
            sensorIdentifier = state.peripheralIdentifier
            sessionStartDate = state.sensorSessionAnchor
            state.handoverVerificationDetectedAt = nil
            state.handoverReacquisitionStartedAt = Date()
            state.handoverReacquisitionDeliveredCount = 0
            state.lastDeliveredMinute = nil
            if let sessionStartDate {
                state.sensorReplacementState = .reacquiring(
                    startDate: sessionStartDate,
                    receivedReadingCount: 0
                )
            }
        }

        guard let sensorIdentifier else { return false }
        CGMAutomaticInsulinSafetyInterlock.beginReacquisition(
            sensorIdentifier: sensorIdentifier.uuidString
        )
        clearHandoverVerificationNotification(for: sensorIdentifier)
        notifyStateChanged()

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Novo Smart confirmado")
        content.body = String(
            localized: "A ponta de dedo foi registrada. O novo Smart passou a ser a referência; o Trio confirmará três glicemias dele antes de retomar a insulina automática."
        )
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: replacementCompletedIdentifier(for: sensorIdentifier),
            content: content,
            trigger: nil
        )
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().add(request)
        }
        return true
    }

    fileprivate func settingsSnapshot() -> SettingsSnapshot {
        let state = lockedState.value
        let expiration = state.sensorSessionAnchor?.addingTimeInterval(Self.sensorLifetime)
        let progress = state.sensorSessionAnchor.map {
            min(1, max(0, Date().timeIntervalSince($0) / Self.sensorLifetime))
        }
        return SettingsSnapshot(
            sensorName: state.sensorName,
            sessionAnchor: state.sensorSessionAnchor,
            expiresAt: expiration,
            sessionProgress: progress,
            sessionMinutes: state.lastMinutes,
            status: state.lastStatus,
            calibrationTemperatureStatus: state.lastCalibrationTemperatureStatus,
            rawTrend: state.lastTrend,
            quality: state.lastQuality,
            checksum: state.lastChecksum,
            rssi: state.lastRSSI,
            lastCommunicationDate: state.lastCommunicationDate,
            currentGlucose: state.currentGlucose,
            currentGlucoseDate: state.currentGlucoseDate,
            lastDeliveredGlucose: state.lastDeliveredGlucose,
            lastDeliveredGlucoseDate: state.lastDeliveredGlucoseDate,
            trendRate: state.derivedTrendRate,
            trend: Self.glucoseTrend(for: state.derivedTrendRate),
            regularizationEnabled: state.regularizationEnabled,
            lastEstimateUsedRegularization: state.lastEstimateUsedRegularization,
            minuteSampleCount: state.regularizer.samples.count,
            isBackfillRunning: state.isBackfillRunning,
            lastBackfillDate: state.lastBackfillDate,
            lastBackfillRecordCount: state.lastBackfillRecordCount,
            lastBackfillError: state.lastBackfillError,
            sensorReplacementState: state.sensorReplacementState
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
        title = String(localized: "Smart / LinX")
        view.backgroundColor = .systemBackground

        statusLabel.text = String(localized: "Procurando um sensor Smart próximo…")
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center

        selectButton.setTitle(String(localized: "Usar este sensor"), for: .normal)
        selectButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        selectButton.isEnabled = false
        selectButton.addTarget(self, action: #selector(selectSensor), for: .touchUpInside)

        let note = UILabel()
        note.text = String(
            localized: "Mantenha o aplicativo oficial Smart completamente encerrado. O Trio recebe o sensor diretamente por Bluetooth."
        )
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
        statusLabel.text = String(localized: "Sensor Smart encontrado. Confirme para vinculá-lo a este Trio.")
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

    func setRegularizationEnabled(_ enabled: Bool) {
        manager?.setRegularizationEnabled(enabled)
    }

    func requestBackfill() {
        manager?.requestBackfill()
    }

    func beginSensorReplacement() {
        manager?.beginSensorReplacement()
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
            measurementSection
            readingTreatmentSection
            backfillSection

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
        Image("Smart2Sensor")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: 92, height: 92)
            .accessibilityLabel(Text("Sensor Smart 2.0"))
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
            LabeledValueView(
                label: "Glicose do sensor",
                value: formattedGlucose(snapshot.currentGlucose)
            )
            LabeledValueView(
                label: "Data",
                value: smartFormatLongDate(snapshot.currentGlucoseDate)
            )
            LabeledValueView(
                label: "Enviada ao Trio",
                value: formattedGlucose(snapshot.lastDeliveredGlucose)
            )
            LabeledValueView(
                label: "Data enviada",
                value: smartFormatLongDate(snapshot.lastDeliveredGlucoseDate)
            )
            LabeledValueView(label: "Tendência", value: formattedTrend)
        }
    }

    private var readingTreatmentSection: some View {
        Section(
            header: Text("Tratamento das leituras"),
            footer: Text(
                "O Trio recebe uma leitura do Smart a cada minuto para calcular a tendência. A filtragem nativa do Trio grava uma leitura aproximadamente a cada quatro minutos. A regularização é ignorada durante mudanças rápidas e quedas próximas de glicemia baixa."
            )
        ) {
            Toggle(
                isOn: Binding(
                    get: { snapshot.regularizationEnabled },
                    set: viewModel.setRegularizationEnabled
                )
            ) {
                Text("Regularizar pequenas oscilações")
            }
            LabeledValueView(
                label: "Última leitura enviada",
                value: snapshot.lastEstimateUsedRegularization ? "Regularizada" : "Original"
            )
        }
    }

    private var backfillSection: some View {
        Section(
            header: Text("Histórico"),
            footer: Text(
                "A recuperação é manual e limitada às últimas seis horas. O Trio interrompe a busca passiva somente durante essa conexão, importa no máximo uma leitura a cada cinco minutos e desconecta assim que terminar para preservar a bateria."
            )
        ) {
            Button {
                presentedAlert = .backfillConfirmation
            } label: {
                HStack {
                    Text(
                        snapshot.isBackfillRunning
                            ? "Recuperando histórico…"
                            : "Recuperar últimas seis horas"
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
                    label: "Última recuperação",
                    value: smartFormatLongDate(lastBackfillDate)
                )
                LabeledValueView(
                    label: "Leituras importadas",
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
                    Text(isReplacementWarming ? "Acompanhar novo sensor" : "Trocar sensor")
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
        case .changeSensor:
            return Alert(
                title: Text("Preparar novo sensor Smart?"),
                message: Text(
                    "O Trio procurará um novo Smart próximo. O sensor atual continuará enviando glicemias durante todo o aquecimento e o histórico permanecerá intacto. A troca só será automática após o novo sensor produzir leituras confiáveis."
                ),
                primaryButton: .default(Text("Continuar")) {
                    authenticateAndPerform(.changeSensor)
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
                    authenticateAndPerform(.deleteCGM)
                },
                secondaryButton: .cancel(Text("Cancelar"))
            )
        }
    }

    private func alert(for alert: PresentedAlert) -> SwiftUI.Alert {
        switch alert {
        case let .pendingAction(action):
            return confirmationAlert(for: action)
        case let .authenticationError(message):
            return Alert(
                title: Text("Autenticação necessária"),
                message: Text(message),
                dismissButton: .default(Text("OK"))
            )
        case .backfillConfirmation:
            return Alert(
                title: Text("Recuperar histórico do Smart?"),
                message: Text(
                    "Encerre completamente o aplicativo oficial Smart antes de continuar. O Trio fará uma conexão temporária somente para copiar as leituras das últimas seis horas; nenhum registro será apagado do sensor."
                ),
                primaryButton: .default(Text("Recuperar")) {
                    viewModel.requestBackfill()
                },
                secondaryButton: .cancel(Text("Cancelar"))
            )
        }
    }

    private func formattedGlucose(_ glucose: Double?) -> String {
        guard let glucose else { return "–" }
        return displayGlucosePreference.format(
            HKQuantity(unit: .milligramsPerDeciliter, doubleValue: glucose)
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
                guard try await BaseUnlockManager().unlock() else {
                    presentedAlert = .authenticationError(
                        String(localized: "O sensor não foi alterado porque não foi possível confirmar sua identidade.")
                    )
                    return
                }

                switch action {
                case .changeSensor:
                    viewModel.beginSensorReplacement()
                    isSensorReplacementPresented = true
                case .deleteCGM:
                    actions.onDelete()
                }
            } catch {
                presentedAlert = .authenticationError(
                    String(
                        localized: "O sensor permanece conectado. Confirme com Face ID ou com o código do iPhone para continuar."
                    )
                )
            }
        }
    }

    private var sensorState: String {
        guard
            let lastCommunication = snapshot.lastCommunicationDate,
            Date().timeIntervalSince(lastCommunication) < .minutes(10)
        else {
            return String(localized: "Sem comunicação")
        }
        if snapshot.expiresAt.map({ $0 <= Date() }) == true {
            return String(localized: "Sensor expirado")
        }
        if snapshot.sessionMinutes.map({ $0 < 60 }) == true {
            return String(localized: "Aquecendo")
        }
        if snapshot.status == 0, snapshot.calibrationTemperatureStatus == 0 {
            return String(localized: "Sensor pronto")
        }
        return String(localized: "Verificar sensor")
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
                    Image("Smart2Sensor")
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .accessibilityLabel(Text("Sensor Smart 2.0"))
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            Section(
                header: Text("Antes de começar"),
                footer: Text(
                    "O Trio mantém o sensor atual enviando glicemias e preserva todo o histórico enquanto o novo Smart aquece em paralelo. A troca é automática somente após leituras confiáveis. Em caso de falha, o sensor atual não é substituído. Mantenha o app oficial Smart instalado como alternativa durante este primeiro teste."
                )
            ) {
                Label("Aplique o novo Smart no corpo", systemImage: "1.circle")
                Label("Não inicie o sensor no app oficial", systemImage: "2.circle")
                Label("Mantenha o app oficial completamente encerrado", systemImage: "3.circle")
                Label("Deixe o novo sensor próximo deste iPhone", systemImage: "4.circle")
            }

            statusSection
        }
        .insetGroupedListStyle()
        .navigationBarTitle(Text("Novo sensor Smart"), displayMode: .inline)
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
                title: Text("Ativar o novo Smart?"),
                message: Text(
                    "Confirme somente se este é o novo sensor já aplicado. O Trio iniciará o aquecimento em paralelo; o Smart atual continuará fornecendo as glicemias até a troca automática."
                ),
                primaryButton: .default(Text("Ativar e aquecer")) {
                    viewModel.activateReplacementSensor()
                },
                secondaryButton: .cancel(Text("Cancelar"))
            )
        }
    }

    @ViewBuilder private var statusSection: some View {
        switch state {
        case .idle:
            Section {
                Button("Procurar novo Smart") {
                    viewModel.beginSensorReplacement()
                }
            }

        case .searching:
            Section(header: Text("Procurando")) {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Procurando um novo sensor Smart próximo…")
                }
                Button("Cancelar") {
                    viewModel.cancelSensorReplacement()
                }
            }

        case let .candidate(name, identifier):
            Section(
                header: Text("Novo sensor encontrado"),
                footer: Text(
                    "Antes de ativar, confirme que o sensor atual continua funcionando e que este identificador pertence ao novo Smart."
                )
            ) {
                LabeledValueView(label: "Sensor", value: name)
                LabeledValueView(label: "Identificador", value: identifier)
                Button("Ativar e iniciar aquecimento") {
                    isActivationConfirmationPresented = true
                }
                Button("Procurar novamente") {
                    viewModel.beginSensorReplacement()
                }
            }

        case let .activating(message):
            Section(header: Text("Ativando")) {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(message)
                }
                Text("Não feche o Trio nem afaste o iPhone do sensor durante esta etapa.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

        case let .warming(startDate, readyAt, lastCommunicationDate):
            Section(header: Text("Aquecendo em paralelo")) {
                Label("Novo Smart ativado com sucesso", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                LabeledValueView(
                    label: "Início do aquecimento",
                    value: smartFormatLongDate(startDate)
                )
                LabeledValueView(
                    label: "Previsão de conclusão",
                    value: smartFormatLongDate(readyAt)
                )
                LabeledValueView(
                    label: "Último sinal do novo Smart",
                    value: smartFormatLongDate(lastCommunicationDate)
                )
                ProgressView(value: warmupProgress(startDate: startDate, readyAt: readyAt))
                Text(
                    Date() < readyAt
                        ?
                        "O Smart atual continua fornecendo as glicemias ao Trio. Nenhuma leitura do novo sensor será usada antes do fim do aquecimento."
                        :
                        "Aquecimento concluído. O Trio está confirmando as primeiras leituras confiáveis antes de fazer a troca automática."
                )
                .font(.footnote)
                .foregroundColor(.secondary)
            }

        case let .verificationRequired(startDate, referenceGlucose, candidateGlucose):
            Section(header: Text("Confirmação de segurança")) {
                Label("Insulina automática temporariamente protegida", systemImage: "exclamationmark.shield.fill")
                    .foregroundColor(.orange)
                LabeledValueView(label: "Sensor anterior", value: "\(Int(referenceGlucose.rounded())) mg/dL")
                LabeledValueView(label: "Novo Smart", value: "\(Int(candidateGlucose.rounded())) mg/dL")
                LabeledValueView(label: "Início da sessão", value: smartFormatLongDate(startDate))
                Text(
                    "O Trio liberará o novo sensor automaticamente após 30 minutos estáveis, ou após no máximo 60 minutos de leituras válidas. Uma ponta de dedo estável pode antecipar essa etapa."
                )
                .font(.footnote)
                .foregroundColor(.secondary)
            }

        case let .reacquiring(startDate, receivedReadingCount):
            Section(header: Text("Validando o novo Smart")) {
                Label("Novo sensor assumido como referência", systemImage: "checkmark.shield.fill")
                    .foregroundColor(.green)
                LabeledValueView(
                    label: "Glicemias confirmadas",
                    value: "\(receivedReadingCount) de \(SmartHandoverReacquisitionPolicy.requiredDeliveredReadings)"
                )
                LabeledValueView(label: "Início da sessão", value: smartFormatLongDate(startDate))
                ProgressView(
                    value: Double(receivedReadingCount),
                    total: Double(SmartHandoverReacquisitionPolicy.requiredDeliveredReadings)
                )
                Text(
                    "As glicemias do novo sensor já entram no Trio. A insulina automática será retomada assim que três leituras dele forem recebidas."
                )
                .font(.footnote)
                .foregroundColor(.secondary)
            }

        case let .completed(startDate):
            Section(header: Text("Troca automática concluída")) {
                Label("Novo Smart fornecendo glicemias", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                LabeledValueView(
                    label: "Início da sessão",
                    value: smartFormatLongDate(startDate)
                )
                Text(
                    "O novo sensor só assumiu após concluir o aquecimento e confirmar leituras confiáveis. O histórico anterior permanece no Trio."
                )
                .font(.footnote)
                .foregroundColor(.secondary)
            }

        case let .failed(message):
            Section(header: Text("Não foi possível concluir")) {
                Text(message)
                    .foregroundColor(.red)
                Text("O sensor anterior e o histórico do Trio não foram alterados.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Button("Tentar novamente") {
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
            Section(header: Text("Informações do dispositivo")) {
                LabeledValueView(label: "Fabricante", value: "MicroTech Medical")
                LabeledValueView(label: "Modelo", value: "LinX / Smart GX-01S")
                LabeledValueView(
                    label: "Comunicação",
                    value: "BLE passivo; conexão limitada para histórico ou ativação"
                )
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
                LabeledValueView(label: "Histórico no anúncio", value: "Até 3 minutos")
                LabeledValueView(label: "Backfill longo", value: "Manual, até 6 horas")
                LabeledValueView(
                    label: "Economia de bateria",
                    value: "Conexão encerrada automaticamente"
                )
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
                    value: snapshot.rawTrend.map(String.init)
                )
                LabeledValueView(
                    label: "Tendência calculada",
                    value: snapshot.trendRate.map { String(format: "%.2f mg/dL/min", $0) }
                )
                LabeledValueView(
                    label: "Amostras por minuto",
                    value: String(snapshot.minuteSampleCount)
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

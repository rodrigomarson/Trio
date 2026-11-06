import Combine
import Foundation
import HealthKit
import LoopKit
import os.log
import UIKit
import UserNotifications

private struct SmartLifecycleProgress: DeviceLifecycleProgress {
    public let percentComplete: Double
    public let progressState: DeviceLifecycleProgressState
}

private struct SmartStatusHighlight: DeviceStatusHighlight {
    public let localizedMessage: String
    public let imageName: String
    public let state: DeviceStatusHighlightState
}

public enum SmartDeliveryCadence {
    public static let intervalMinutes: UInt16 = 4

    public static func shouldDeliver(
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

public enum SmartSessionStatusPolicy {
    public static func isStopped(status: UInt8?) -> Bool {
        status.map { $0 & 0x01 != 0 } ?? false
    }

    public static func isWarmupConfirmed(status: UInt8?, minutesSinceStart: UInt16?) -> Bool {
        guard !isStopped(status: status), let minutesSinceStart else { return false }
        return minutesSinceStart < SmartSensorHandoverPolicy.warmupMinutes
    }
}

/// A host-neutral summary of whether Smart can currently supply glucose.
///
/// Trio maps the unavailable states into its generic CGM sensor-state log.
/// Keeping this type inside SmartCGMKit avoids coupling the kit to Trio's
/// persistence or Nightscout implementation.
public enum SmartSensorObservation: Equatable {
    public enum UnreliableState: String, Equatable {
        case notActivated = "smartNotActivated"
        case waitingForSensor = "smartWaitingForSensor"
        case warmup = "smartWarmup"
        case noSignal = "smartNoSignal"
        case expired = "smartExpired"
        case checkSensor = "smartCheckSensor"
        case replacementWarmup = "smartReplacementWarmup"
        case replacementNoSignal = "smartReplacementNoSignal"
        case replacementConfirming = "smartReplacementConfirming"
        case handoverVerification = "smartHandoverVerification"
        case handoverReacquisition = "smartHandoverReacquisition"
    }

    case reliable
    case unreliable(UnreliableState)
    case unavailable
}

/// Decides when a newly activated Smart can safely replace the sensor that is
/// still supplying Trio. The pending sensor is observed but never forwarded to
/// the glucose pipeline until it has completed the nominal warmup and produced
/// two consecutive reliable advertisements.
public enum SmartSensorHandoverPolicy {
    public static let warmupMinutes: UInt16 = 60
    public static let requiredConsecutiveReliableReadings = 2

    public static func updatedReliableReadingCount(
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

    public static func shouldHandover(reliableReadingCount: Int) -> Bool {
        reliableReadingCount >= requiredConsecutiveReliableReadings
    }
}

/// Screens the first readings from a warmed Smart against the sensor that is
/// still active. A difference must exceed both the ordinary CGM tolerance and
/// a meaningful absolute amount before Trio asks for a fingerstick.
public enum SmartHandoverDivergencePolicy {
    public static let stableReleaseInterval: TimeInterval = .minutes(30)
    public static let maximumHoldInterval: TimeInterval = .minutes(60)
    public static let requiredRecentReadings = 5
    public static let maximumStableSpread = 15.0

    public struct Assessment: Equatable {
        let referenceGlucose: Double
        let candidateGlucose: Double
        let absoluteDifference: Double
        let relativeDifference: Double

        var requiresFingerstickConfirmation: Bool {
            absoluteDifference > 20 && relativeDifference > 0.20
        }
    }

    public static func assess(
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

    public static func shouldAutomaticallyRelease(
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
public enum SmartHandoverReacquisitionPolicy {
    public static let requiredDeliveredReadings = 3

    public static func updatedDeliveredReadingCount(previousCount: Int) -> Int {
        min(requiredDeliveredReadings, max(0, previousCount) + 1)
    }

    public static func canResumeAutomaticInsulin(deliveredReadingCount: Int) -> Bool {
        deliveredReadingCount >= requiredDeliveredReadings
    }
}

/// Defines the advance notifications for a planned Smart replacement.
///
/// The final reminder is intentionally sent 65 minutes before expiry. This
/// gives the nominal 60-minute warmup a small validation margin while the
/// current sensor continues supplying Trio.
public enum SmartSensorReminderPolicy {
    public enum Kind: String, CaseIterable, Equatable {
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
                return String(localized: "Smart ends in 24 hours")
            case .prepareIn120Minutes:
                return String(localized: "Prepare to replace Smart")
            case .replaceIn65Minutes:
                return String(localized: "Time to start the new Smart")
            }
        }

        var body: String {
            switch self {
            case .expiresIn24Hours:
                return String(
                    localized: "Have a new sensor available so you can replace it without interrupting glucose readings."
                )
            case .prepareIn120Minutes:
                return String(
                    localized: "The current sensor ends in 2 hours. Keep the new Smart and iPhone ready for replacement."
                )
            case .replaceIn65Minutes:
                return String(
                    localized: "Apply the new sensor and use Trio > Smart / LinX > Change Sensor. The current Smart will keep sending glucose readings during warmup."
                )
            }
        }
    }

    public struct ScheduledNotification: Equatable {
        let kind: Kind
        let deliveryDate: Date
    }

    public static func notifications(expiresAt: Date, now: Date) -> [ScheduledNotification] {
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
public final class SmartCGMManager: CGMManager {
    public static let pluginIdentifier = "SmartCGMManager"
    public static let localizedTitle = String(localized: "Smart / LinX (Beta)")
    private static let sensorLifetime: TimeInterval = .hours(15 * 24)
    private static let warmupPeriod: TimeInterval = .hours(1)
    private static let legacyReplacementReminderPrefix = "Trio.Smart.replacement."
    private static let replacementReminderPrefix = "Trio.Smart.replacement.reminder."
    private static let replacementCompletedPrefix = "Trio.Smart.replacement.completed."
    private static let handoverVerificationPrefix = "Trio.Smart.handover.verification."
    public static let stateDidChangeNotification = Notification.Name(
        "SmartCGMManager.stateDidChange"
    )

    public enum SensorReplacementState: Equatable {
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
        let trendRate: LoopQuantity?
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

    private var foregroundObserver: NSObjectProtocol?
    // Accessed only on the main queue; invalidates callbacks after a lifecycle transition.
    private var reminderRevision = 0
    private let reminderStatus = Locked(String(localized: "Not checked"))
    public var replacementReminderStatus: String { reminderStatus.value }

    private func observeReminderLifecycle() {
        foregroundObserver = Foundation.NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleReplacementNotificationsIfNeeded(allowCatchUp: false)
        }
    }

    private let startsMonitoring: Bool
    private let lockedState: Locked<State>
    private let delegate = WeakSynchronizedDelegate<CGMManagerDelegate>()

    private lazy var scanner = SmartAdvertisementScanner(
        restorationIdentifier: SmartAdvertisementScanner.managerRestorationIdentifier
    ) { [weak self] reading in
        self?.handle(reading)
    }

    public convenience init(peripheralIdentifier: UUID, sessionStartDate: Date? = nil) {
        self.init(peripheralIdentifier: peripheralIdentifier, sessionStartDate: sessionStartDate, startsMonitoring: true)
    }

    init(peripheralIdentifier: UUID, sessionStartDate: Date? = nil, startsMonitoring: Bool) {
        self.startsMonitoring = startsMonitoring
        var state = State(peripheralIdentifier: peripheralIdentifier)
        state.sensorSessionAnchor = sessionStartDate.map {
            Date(timeIntervalSince1970: floor($0.timeIntervalSince1970 / 60) * 60)
        }
        lockedState = Locked(state)
        if startsMonitoring {
            scanner.start()
            observeReminderLifecycle()
            scheduleReplacementNotificationsIfNeeded()
        }
    }

    public required convenience init?(rawState: RawStateValue) {
        self.init(restoring: rawState, startsMonitoring: true)
    }

    init?(restoring rawState: RawStateValue, startsMonitoring: Bool) {
        self.startsMonitoring = startsMonitoring
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
            SmartAutomaticInsulinSafetyInterlock.activate(
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
        if startsMonitoring {
            scanner.start()
            observeReminderLifecycle()
            scheduleReplacementNotificationsIfNeeded()
        }
    }

    deinit {
        if let foregroundObserver { Foundation.NotificationCenter.default.removeObserver(foregroundObserver) }
        if startsMonitoring { scanner.stop() }
    }

    public var localizedTitle: String { Self.localizedTitle }
    public var pluginIdentifier: String { Self.pluginIdentifier }
    public func markAsDepedency(_: Bool) {}
    public var isOnboarded: Bool { true }
    public var appURL: URL? { nil }
    // Keep Trio's established polling and pump-heartbeat fallback enabled for
    // production validation. Passive Smart wakeups are not yet sufficient to
    // replace that safety net across activation, suspension and signal loss.
    public var providesBLEHeartbeat: Bool { false }
    public var managedDataInterval: TimeInterval? { .hours(3) }
    public static var healthKitStorageDelay: TimeInterval { 0 }
    public var shouldSyncToRemoteService: Bool { true }

    public var inSignalLoss: Bool {
        let state = lockedState.value
        guard state.sensorSessionAnchor != nil || state.pendingSessionAnchor != nil else { return false }
        let latestCommunication = [state.lastCommunicationDate, state.pendingLastCommunicationDate]
            .compactMap { $0 }
            .max()
        return latestCommunication.map { Date().timeIntervalSince($0) >= .minutes(8) } ?? true
    }

    public var isInoperable: Bool {
        let state = lockedState.value
        return state.sensorSessionAnchor.map {
            $0.addingTimeInterval(Self.sensorLifetime) <= Date()
        } ?? false
    }

    public var cgmManagerDelegate: CGMManagerDelegate? {
        get { delegate.delegate }
        set { delegate.delegate = newValue }
    }

    public var delegateQueue: DispatchQueue! {
        get { delegate.queue }
        set { delegate.queue = newValue }
    }

    public var rawState: RawStateValue {
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

    public var cgmManagerStatus: CGMManagerStatus {
        let state = lockedState.value
        let hasActiveSession = state.sensorSessionAnchor != nil &&
            !SmartSessionStatusPolicy.isStopped(status: state.lastStatus)
        let hasPendingSession = state.pendingSessionAnchor != nil &&
            state.pendingPeripheralIdentifier != nil
        let communicationDates = [state.lastCommunicationDate, state.pendingLastCommunicationDate]
            .compactMap { $0 }
        return CGMManagerStatus(
            hasValidSensorSession: hasActiveSession || hasPendingSession,
            lastCommunicationDate: communicationDates.max(),
            device: Self.device
        )
    }

    public var sensorObservation: SmartSensorObservation {
        sensorObservation(now: Date())
    }

    func sensorObservation(now: Date) -> SmartSensorObservation {
        let state = lockedState.value
        let activeReadingIsReliable = state.lastStatus == 0 &&
            state.lastCalibrationTemperatureStatus == 0 &&
            state.lastCommunicationDate.map { now.timeIntervalSince($0) < .minutes(8) } == true &&
            state.currentGlucose.map { $0.isFinite && (20 ... 600).contains($0) } == true &&
            state.currentGlucoseDate.map { now.timeIntervalSince($0) < .minutes(10) } == true

        // During parallel replacement the outgoing sensor remains Trio's CGM
        // source. Its reliable glucose therefore wins over the pending
        // sensor's expected warmup state.
        if activeReadingIsReliable {
            return .reliable
        }

        if let pendingStart = state.pendingSessionAnchor,
           state.pendingPeripheralIdentifier != nil
        {
            if case .verificationRequired = state.sensorReplacementState {
                return .unreliable(.handoverVerification)
            }
            if case .reacquiring = state.sensorReplacementState {
                return .unreliable(.handoverReacquisition)
            }
            if let pendingCommunication = state.pendingLastCommunicationDate,
               now.timeIntervalSince(pendingCommunication) >= .minutes(8)
            {
                return .unreliable(.replacementNoSignal)
            }
            return now < pendingStart.addingTimeInterval(Self.warmupPeriod)
                ? .unreliable(.replacementWarmup)
                : .unreliable(.replacementConfirming)
        }

        if SmartSessionStatusPolicy.isStopped(status: state.lastStatus) {
            return .unreliable(.notActivated)
        }
        guard let lastCommunication = state.lastCommunicationDate else {
            return state.sensorSessionAnchor == nil
                ? .unavailable
                : .unreliable(.waitingForSensor)
        }
        if now.timeIntervalSince(lastCommunication) >= .minutes(8) {
            return .unreliable(.noSignal)
        }
        if state.sensorSessionAnchor.map({ $0.addingTimeInterval(Self.sensorLifetime) <= now }) == true {
            return .unreliable(.expired)
        }
        if smartWarmupEndsAt(now: now, state: state) != nil {
            return .unreliable(.warmup)
        }
        if state.lastStatus != 0 || state.lastCalibrationTemperatureStatus != 0 {
            return .unreliable(.checkSensor)
        }
        return .unavailable
    }

    public var glucoseDisplay: GlucoseDisplayable? {
        let state = lockedState.value
        let isRecent = state.currentGlucoseDate.map { Date().timeIntervalSince($0) < .minutes(10) } ?? false
        return DisplayState(
            isStateValid: isRecent,
            trendType: Self.glucoseTrend(for: state.derivedTrendRate),
            trendRate: Self.trendQuantity(for: state.derivedTrendRate)
        )
    }

    public var debugDescription: String {
        let state = lockedState.value
        return "SmartCGMManager(configured: true, hasReading: \(state.currentGlucose != nil), reminders: \(replacementReminderStatus))"
    }

    public func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        scanner.start()
        scheduleReplacementNotificationsIfNeeded(allowCatchUp: false)
        completion(.noData)
    }

    public func delete() async {
        let state = lockedState.value
        SmartAutomaticInsulinSafetyInterlock.clear(
            sensorIdentifier: state.peripheralIdentifier.uuidString
        )
        cancelReplacementNotifications(for: state.peripheralIdentifier)
        if let pendingIdentifier = state.pendingPeripheralIdentifier {
            cancelReplacementNotifications(for: pendingIdentifier)
        }
        scanner.stop()
        await cgmManagerDelegate?.cgmManagerWantsDeletion(self)
    }

    public func acknowledgeAlert(
        alertIdentifier _: LoopKit.Alert.AlertIdentifier,
        completion: @escaping (Error?) -> Void
    ) {
        completion(nil)
    }

    public func acknowledgeAlert(alertIdentifier _: LoopKit.Alert.AlertIdentifier) async throws {}

    public func getSoundBaseURL() -> URL? { nil }
    public func getSounds() -> [LoopKit.Alert.Sound] { [] }

    public var cgmStatusHighlight: DeviceStatusHighlight? {
        let state = lockedState.value
        let now = Date()

        // A pending replacement is a separate sensor session. Its confirmed
        // warmup must take visual precedence over the stopped/stale state of
        // the outgoing sensor while Trio keeps that sensor's history and last
        // reading available until handover.
        if let pendingStart = state.pendingSessionAnchor,
           state.pendingPeripheralIdentifier != nil
        {
            if let pendingCommunication = state.pendingLastCommunicationDate,
               now.timeIntervalSince(pendingCommunication) >= .minutes(8)
            {
                return SmartStatusHighlight(
                    localizedMessage: String(localized: "New Smart\nno signal"),
                    imageName: "exclamationmark.circle.fill",
                    state: .warning
                )
            }

            let readyAt = pendingStart.addingTimeInterval(Self.warmupPeriod)
            return SmartStatusHighlight(
                localizedMessage: now < readyAt
                    ? String(localized: "New Smart\nwarming up")
                    : String(localized: "New Smart\nconfirming"),
                imageName: "hourglass",
                state: .normalCGM
            )
        }

        if SmartSessionStatusPolicy.isStopped(status: state.lastStatus) {
            return SmartStatusHighlight(
                localizedMessage: String(localized: "Smart\nnot activated"),
                imageName: "exclamationmark.triangle.fill",
                state: .warning
            )
        }

        guard let lastCommunication = state.lastCommunicationDate else {
            return SmartStatusHighlight(
                localizedMessage: String(localized: "Waiting for\nsensor"),
                imageName: "dot.radiowaves.left.and.right",
                state: .normalCGM
            )
        }
        if now.timeIntervalSince(lastCommunication) >= .minutes(8) {
            return SmartStatusHighlight(
                localizedMessage: String(localized: "Smart\nno signal"),
                imageName: "exclamationmark.circle.fill",
                state: .warning
            )
        }

        if smartWarmupEndsAt(now: now, state: state) != nil {
            return SmartStatusHighlight(
                localizedMessage: String(localized: "Smart\nwarming up"),
                imageName: "hourglass",
                state: .normalCGM
            )
        }

        return nil
    }

    public var cgmLifecycleProgress: DeviceLifecycleProgress? {
        let state = lockedState.value
        let now = Date()

        if let warmup = smartWarmupWindow(now: now, state: state) {
            let duration = warmup.readyAt.timeIntervalSince(warmup.startDate)
            let elapsed = now.timeIntervalSince(warmup.startDate)
            return SmartLifecycleProgress(
                percentComplete: min(1, max(0, elapsed / duration)),
                progressState: .warning
            )
        }

        guard let anchor = state.sensorSessionAnchor else { return nil }
        let lifetime = Self.sensorLifetime
        let elapsed = max(0, now.timeIntervalSince(anchor))
        let remaining = max(0, lifetime - elapsed)
        guard remaining < .hours(72) else { return nil }
        return SmartLifecycleProgress(
            percentComplete: min(1, elapsed / lifetime),
            progressState: remaining < .hours(24) ? .warning : .normalCGM
        )
    }

    /// End of the Smart warmup currently relevant to the home screen. A pending
    /// replacement takes precedence so Trio can keep showing glucose from the
    /// old sensor while counting down the new sensor in parallel.
    public var smartWarmupEndsAt: Date? {
        smartWarmupWindow(now: Date(), state: lockedState.value)?.readyAt
    }

    private func smartWarmupEndsAt(now: Date, state: State) -> Date? {
        smartWarmupWindow(now: now, state: state)?.readyAt
    }

    private func smartWarmupWindow(
        now: Date,
        state: State
    ) -> (startDate: Date, readyAt: Date)? {
        if let pendingStart = state.pendingSessionAnchor,
           state.pendingPeripheralIdentifier != nil
        {
            let readyAt = pendingStart.addingTimeInterval(Self.warmupPeriod)
            if now < readyAt { return (pendingStart, readyAt) }
        }

        if let activeStart = state.sensorSessionAnchor,
           SmartSessionStatusPolicy.isWarmupConfirmed(
               status: state.lastStatus,
               minutesSinceStart: state.lastMinutes
           )
        {
            let readyAt = activeStart.addingTimeInterval(Self.warmupPeriod)
            if now < readyAt { return (activeStart, readyAt) }
        }

        return nil
    }

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

    private func scheduleReplacementNotificationsIfNeeded(now: Date = Date(), allowCatchUp: Bool = true) {
        guard startsMonitoring else { return }
        let state = lockedState.value
        guard state.pendingPeripheralIdentifier == nil else {
            reminderStatus.mutate { $0 = String(localized: "Replacement in progress") }
            cancelReplacementNotifications(for: state.peripheralIdentifier)
            return
        }
        guard let sessionAnchor = state.sensorSessionAnchor,
              sessionAnchor.timeIntervalSince1970.isFinite,
              sessionAnchor <= now
        else {
            reminderStatus.mutate { $0 = String(localized: "Session start unavailable") }
            return
        }
        let expiresAt = sessionAnchor.addingTimeInterval(Self.sensorLifetime)
        guard expiresAt > now else {
            reminderStatus.mutate { $0 = String(localized: "Sensor expired") }
            cancelReplacementNotifications(for: state.peripheralIdentifier)
            return
        }
        let requests = SmartSensorReminderPolicy.notifications(expiresAt: expiresAt, now: now)
            .filter { allowCatchUp || expiresAt.addingTimeInterval(-$0.kind.leadTime) > now }
            .map { notification in
                let content = UNMutableNotificationContent()
                content.title = notification.kind.title
                content.body = notification.kind.body
                content.sound = .default
                content.userInfo["smartSessionAnchor"] = sessionAnchor.timeIntervalSince1970
                let components = Calendar(identifier: .gregorian).dateComponents(
                    [.year, .month, .day, .hour, .minute, .second, .timeZone],
                    from: notification.deliveryDate
                )
                return UNNotificationRequest(
                    identifier: replacementReminderIdentifier(for: state.peripheralIdentifier, kind: notification.kind),
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                )
            }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reminderRevision += 1
            let revision = self.reminderRevision
            let center = UNUserNotificationCenter.current()
            center.getPendingNotificationRequests { pending in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.reminderRevision == revision else { return }
                    let current = self.lockedState.value
                    guard current.peripheralIdentifier == state.peripheralIdentifier,
                          current.sensorSessionAnchor == sessionAnchor,
                          current.pendingPeripheralIdentifier == nil else { return }
                    let group = DispatchGroup()
                    for request in requests {
                        // Reuse requests already accepted by iOS. Adding the same identifier
                        // replaces it atomically; never remove all reminders before adding.
                        if pending.contains(where: {
                            $0.identifier == request.identifier &&
                                ($0.content.userInfo["smartSessionAnchor"] as? Double) == sessionAnchor.timeIntervalSince1970
                        }) { continue }
                        group.enter()
                        center.add(request) { error in
                            if let error {
                                os_log("Smart reminder scheduling failed: %{public}@", type: .error, error.localizedDescription)
                            }
                            group.leave()
                        }
                    }
                    group.notify(queue: .main) { [weak self] in
                        guard let self, self.reminderRevision == revision else { return }
                        center.getNotificationSettings { settings in
                            center.getPendingNotificationRequests { verified in
                                DispatchQueue.main.async { [weak self] in
                                    guard let self, self.reminderRevision == revision else { return }
                                    let expected = Set(requests.map(\.identifier))
                                    let present = expected.intersection(verified.map(\.identifier)).count
                                    let status: String
                                    if settings.authorizationStatus == .denied || settings.authorizationStatus == .notDetermined {
                                        status = String(localized: "Notifications are not authorized")
                                    } else if settings.alertSetting == .disabled || settings.authorizationStatus == .provisional {
                                        status = String(localized: "Notification banners are disabled or quiet")
                                    } else {
                                        status = "\(present)/\(expected.count) " +
                                            String(localized: "upcoming reminders scheduled")
                                    }
                                    self.reminderStatus.mutate { $0 = status }
                                    if present != expected.count {
                                        os_log(
                                            "Smart reminders missing after reconciliation: %d of %d",
                                            type: .error,
                                            expected.count - present,
                                            expected.count
                                        )
                                    }
                                    self.notifyLocalStateChanged()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func cancelReplacementNotifications(for peripheralIdentifier: UUID) {
        let identifiers = allReplacementNotificationIdentifiers(for: peripheralIdentifier)
        DispatchQueue.main.async { [weak self] in
            self?.reminderRevision += 1
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    private func notifySuccessfulHandover(for peripheralIdentifier: UUID) {
        let identifier = replacementCompletedIdentifier(for: peripheralIdentifier)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "New Smart is active")
        content.body = String(
            localized: "Warmup ended, automatic replacement completed, and the first glucose reading was received successfully."
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
        content.title = String(localized: "Confirm glucose before insulin")
        content.body = String(
            localized: "The Smart replacement showed \(Int(referenceGlucose.rounded())) and \(Int(candidateGlucose.rounded())) mg/dL. Automatic insulin is protected. Check with a fingerstick and record the calibration in Trio."
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
        content.title = String(localized: "Trio adopted the new Smart")
        content.body = String(
            localized: "The safety period ended and the new sensor became the reference. The algorithm will wait for three recent glucose readings before resuming automatic insulin."
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
        content.title = String(localized: "New Smart validated")
        content.body = String(
            localized: "Three glucose readings were received from the new sensor. Temporary protection ended and automatic treatment can resume using the new Smart as the reference."
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

        guard !isDuplicate else {
            // A restored manager can receive the same stopped/warmup packet it
            // persisted previously. Preserve the newly observed communication
            // time so relaunching Trio cannot resurrect a stale timestamp.
            notifyStateChanged()
            return
        }

        if handoverWasAutomaticallyReleased, let releasedSensorIdentifier {
            SmartAutomaticInsulinSafetyInterlock.beginReacquisition(
                sensorIdentifier: releasedSensorIdentifier.uuidString
            )
            clearHandoverVerificationNotification(for: releasedSensorIdentifier)
            notifyAutomaticHandoverRelease(for: releasedSensorIdentifier)
        }

        if handoverReacquisitionWasCompleted, let releasedSensorIdentifier {
            SmartAutomaticInsulinSafetyInterlock.clear(
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
            quantity: LoopQuantity(
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
            state.pendingLastCommunicationDate = reading.receivedAt

            isDuplicate = state.pendingLastMinutes == advertisement.minutesSinceStart &&
                state.pendingLastChecksum == advertisement.checksum
            guard !isDuplicate else { return }

            let previousMinute = state.pendingLastMinutes
            let previousReliableReadingCount = state.pendingReliableReadingCount
            state.pendingSensorName = reading.localName ?? state.pendingSensorName
            state.pendingLastMinutes = advertisement.minutesSinceStart
            state.pendingLastChecksum = advertisement.checksum
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

        guard wasHandled else { return }
        if isDuplicate {
            notifyStateChanged()
            return
        }
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
            SmartAutomaticInsulinSafetyInterlock.activate(
                .init(
                    sensorIdentifier: reading.peripheralIdentifier.uuidString,
                    referenceGlucose: divergenceAssessment.referenceGlucose,
                    candidateGlucose: divergenceAssessment.candidateGlucose,
                    detectedAt: reading.receivedAt,
                    phase: .divergenceVerification
                )
            )
        } else {
            SmartAutomaticInsulinSafetyInterlock.clear(
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

    private static func trendQuantity(for rate: Double?) -> LoopQuantity? {
        rate.map {
            LoopQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0)
        }
    }

    public func setRegularizationEnabled(_ enabled: Bool) {
        lockedState.mutate { state in
            state.regularizationEnabled = enabled
        }
        notifyStateChanged()
    }

    public func beginSensorReplacement() {
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

    public func activateCurrentSensor() {
        let state = lockedState.value
        let candidate = SmartAdvertisementScanner.ActivationCandidate(
            peripheralIdentifier: state.peripheralIdentifier,
            localName: state.sensorName,
            rssi: state.lastRSSI ?? 0,
            receivedAt: state.lastCommunicationDate ?? Date(),
            minutesSinceStart: state.lastMinutes ?? 0,
            status: state.lastStatus ?? 0x01,
            calibrationTemperatureStatus: state.lastCalibrationTemperatureStatus ?? 0,
            quality: state.lastQuality ?? 0
        )
        lockedState.mutate { state in
            state.sensorReplacementState = .activating(
                message: String(localized: "Connecting to Smart…")
            )
        }
        notifyLocalStateChanged()

        scanner.activate(
            candidate: candidate,
            existingSessionPolicy: .adopt,
            progress: { [weak self] phase in
                guard let self else { return }
                let message: String
                switch phase {
                case .connecting:
                    message = String(localized: "Connecting to Smart…")
                case .checkingSensor:
                    message = String(localized: "Checking the Smart session…")
                case .startingSession:
                    message = String(localized: "Starting the Smart session…")
                case .synchronizingTime:
                    message = String(localized: "Synchronizing the Smart clock…")
                case .confirmingSession:
                    message = String(localized: "Confirming warmup start…")
                }
                self.lockedState.mutate { state in
                    state.sensorReplacementState = .activating(message: message)
                }
                self.notifyLocalStateChanged()
            },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(result):
                    let anchor = Date(
                        timeIntervalSince1970: floor(result.sessionStartDate.timeIntervalSince1970 / 60) * 60
                    )
                    self.lockedState.mutate { state in
                        state.sensorSessionAnchor = anchor
                        state.lastMinutes = nil
                        state.lastChecksum = nil
                        state.lastStatus = nil
                        state.lastCalibrationTemperatureStatus = nil
                        state.lastQuality = nil
                        state.currentGlucose = nil
                        state.currentGlucoseDate = nil
                        state.lastDeliveredMinute = nil
                        state.lastDeliveredGlucose = nil
                        state.lastDeliveredGlucoseDate = nil
                        state.regularizer.reset()
                        state.sensorReplacementState = .completed(startDate: anchor)
                    }
                    self.scheduleReplacementNotificationsIfNeeded()
                    self.notifyStateChanged()
                case let .failure(error):
                    self.lockedState.mutate { state in
                        state.sensorReplacementState = .failed(message: error.localizedDescription)
                    }
                    self.notifyLocalStateChanged()
                }
            }
        )
    }

    public func activateReplacementSensor() {
        guard let candidate = lockedState.value.sensorReplacementCandidate else { return }
        lockedState.mutate { state in
            state.sensorReplacementState = .activating(message: String(localized: "Connecting to the new Smart…"))
        }
        notifyLocalStateChanged()

        scanner.activate(
            candidate: candidate,
            progress: { [weak self] phase in
                guard let self else { return }
                let message: String
                switch phase {
                case .connecting:
                    message = String(localized: "Connecting to the new Smart…")
                case .checkingSensor:
                    message = String(localized: "Validating the new sensor…")
                case .startingSession:
                    message = String(localized: "Starting the new session…")
                case .synchronizingTime:
                    message = String(localized: "Synchronizing time and warmup…")
                case .confirmingSession:
                    message = String(localized: "Confirming warmup start…")
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

    public func cancelSensorReplacement() {
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

    public func requestBackfill() {
        var context: (peripheralIdentifier: UUID, sessionAnchor: Date, currentMinute: UInt16)?
        lockedState.mutate { state in
            guard !state.isBackfillRunning else { return }
            guard
                let sessionAnchor = state.sensorSessionAnchor,
                let currentMinute = state.lastMinutes
            else {
                state.lastBackfillError =
                    String(localized: "Wait for a current Smart reading before recovering history.")
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
                        String(localized: "The sensor session changed during recovery. No readings were imported.")
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
                    quantity: LoopQuantity(
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

    public struct SettingsSnapshot {
        public let sensorName: String?
        public let sessionAnchor: Date?
        public let expiresAt: Date?
        public let sessionProgress: Double?
        public let sessionMinutes: UInt16?
        public let status: UInt8?
        public let calibrationTemperatureStatus: UInt8?
        public let rawTrend: Int8?
        public let quality: UInt8?
        public let checksum: UInt32?
        public let rssi: Int?
        public let lastCommunicationDate: Date?
        public let currentGlucose: Double?
        public let currentGlucoseDate: Date?
        public let lastDeliveredGlucose: Double?
        public let lastDeliveredGlucoseDate: Date?
        public let trendRate: Double?
        public let trend: GlucoseTrend?
        public let regularizationEnabled: Bool
        public let lastEstimateUsedRegularization: Bool
        public let minuteSampleCount: Int
        public let isBackfillRunning: Bool
        public let lastBackfillDate: Date?
        public let lastBackfillRecordCount: Int?
        public let lastBackfillError: String?
        public let sensorReplacementState: SensorReplacementState
    }

    public struct CalibrationSnapshot {
        public let glucose: Double
        public let date: Date
        public let trendRate: Double?
    }

    public struct SensorMetadata {
        public let sessionStartDate: Date?
        public let sensorIdentifier: String
    }

    public func sensorMetadata() -> SensorMetadata {
        let state = lockedState.value
        return SensorMetadata(
            sessionStartDate: state.sensorSessionAnchor,
            sensorIdentifier: state.sensorName ?? state.peripheralIdentifier.uuidString
        )
    }

    public func calibrationSnapshot() -> CalibrationSnapshot? {
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

    public var isAwaitingHandoverConfirmation: Bool {
        lockedState.value.handoverVerificationDetectedAt != nil
    }

    /// Accepts the new Smart early after an explicit, stable fingerstick. Trio
    /// then admits the new sensor's readings while keeping automatic insulin
    /// protected until three of those readings have been delivered.
    @discardableResult public func confirmHandoverAfterFingerstick() -> Bool {
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
        SmartAutomaticInsulinSafetyInterlock.beginReacquisition(
            sensorIdentifier: sensorIdentifier.uuidString
        )
        clearHandoverVerificationNotification(for: sensorIdentifier)
        notifyStateChanged()

        let content = UNMutableNotificationContent()
        content.title = String(localized: "New Smart confirmed")
        content.body = String(
            localized: "The fingerstick was recorded. The new Smart became the reference; Trio will confirm three of its glucose readings before resuming automatic insulin."
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

    public func settingsSnapshot() -> SettingsSnapshot {
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

// Time helpers are module-local; LoopKit does not export its equivalents.
extension TimeInterval {
    static func minutes(_ value: Double) -> TimeInterval { value * 60 }
    static func hours(_ value: Double) -> TimeInterval { value * 3600 }
}

extension HKUnit {
    static var milligramsPerDeciliter: HKUnit { HKUnit(from: "mg/dL") }
    static var milligramsPerDeciliterPerMinute: HKUnit { milligramsPerDeciliter.unitDivided(by: .minute()) }
}

/// Calibration admission rules shared by manager UI and host calibration adapters.
public enum SmartCalibrationPolicy {
    public static func isRecent(_ date: Date, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= -120 && age <= 300
    }

    public static func isStable(_ trendRate: Double?) -> Bool {
        trendRate.map { abs($0) < 2 } ?? false
    }
}

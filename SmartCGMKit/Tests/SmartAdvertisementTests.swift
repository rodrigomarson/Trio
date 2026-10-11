import Foundation
@testable import SmartCGMKit
import Testing

private typealias CGMAutomaticInsulinSafetyInterlock = SmartAutomaticInsulinSafetyInterlock

@Suite("Smart Advertisement Tests") struct SmartAdvertisementTests {
    @Test("Parses captured Smart advertisements") func parsesCapturedAdvertisements() throws {
        let samples: [(hex: String, minutes: UInt16, trend: Int8, current: UInt16, quality: UInt8, previous: [UInt16])] = [
            ("59004D000000037680627480647480630000FDC32BE7", 77, 3, 118, 98, [116, 116]),
            ("5900590000000177806375806475806400000F8DAF82", 89, 1, 119, 99, [117, 117]),
            ("590067000000FE75806476806377806400000563554D", 103, -2, 117, 100, [118, 119]),
            ("59006B000000FF7580647480647580640000C9654683", 107, -1, 117, 100, [116, 117])
        ]

        for sample in samples {
            let advertisement = try #require(SmartAdvertisement(manufacturerData: try data(from: sample.hex)))
            #expect(advertisement.minutesSinceStart == sample.minutes)
            #expect(advertisement.trend == sample.trend)
            #expect(advertisement.current.glucose == sample.current)
            #expect(advertisement.current.quality == sample.quality)
            #expect(advertisement.current.isValid)
            #expect(advertisement.previous.map(\.glucose) == sample.previous)
            #expect(advertisement.previous.allSatisfy { $0.isValid })
        }
    }

    @Test("Rejects an invalid checksum") func rejectsInvalidChecksum() throws {
        var bytes = [UInt8](try data(from: "59006B000000FF7580647480647580640000C9654683"))
        bytes[7] ^= 0x01
        #expect(SmartAdvertisement(manufacturerData: Data(bytes)) == nil)
    }

    @Test("Rejects another manufacturer") func rejectsAnotherManufacturer() throws {
        var bytes = [UInt8](try data(from: "59006B000000FF7580647480647580640000C9654683"))
        bytes[0] = 0x58
        #expect(SmartAdvertisement(manufacturerData: Data(bytes)) == nil)
    }

    @Test("Suppresses repeated advertisements before waking Trio") func suppressesDuplicateAdvertisements() throws {
        let identifier = UUID()
        let first = try #require(
            SmartAdvertisement(
                manufacturerData: try data(from: "59004D000000037680627480647480630000FDC32BE7")
            )
        )
        let next = try #require(
            SmartAdvertisement(
                manufacturerData: try data(from: "5900590000000177806375806475806400000F8DAF82")
            )
        )
        var deduplicator = SmartAdvertisementDeduplicator()

        let shouldForwardFirst = deduplicator.shouldForward(
            peripheralIdentifier: identifier,
            advertisement: first
        )
        let shouldSuppressDuplicate = !deduplicator.shouldForward(
            peripheralIdentifier: identifier,
            advertisement: first
        )
        let shouldForwardNext = deduplicator.shouldForward(
            peripheralIdentifier: identifier,
            advertisement: next
        )

        #expect(shouldForwardFirst)
        #expect(shouldSuppressDuplicate)
        #expect(shouldForwardNext)
    }

    @Test("Accepts captured advertisements with trailing transport data") func acceptsTrailingTransportData() throws {
        let advertisement = try #require(
            SmartAdvertisement(
                manufacturerData: try data(
                    from: "59009D010000026480636580636480640000E8DDD08203F7057236"
                )
            )
        )

        #expect(advertisement.minutesSinceStart == 413)
        #expect(advertisement.trend == 2)
        #expect(advertisement.current.glucose == 100)
        #expect(advertisement.current.quality == 99)
        #expect(advertisement.current.isValid)
        #expect(advertisement.previous.map(\.glucose) == [101, 100])
    }

    @Test("Parses advertisements after the checksum sum overflows 32 bits") func parsesAdvertisementAfterChecksumOverflow() throws {
        let advertisement = try #require(
            SmartAdvertisement(
                manufacturerData: try data(
                    from: "5900721400000CCE8064CC8064CB80640000D61E90D9"
                )
            )
        )

        #expect(advertisement.minutesSinceStart == 5234)
        #expect(advertisement.trend == 12)
        #expect(advertisement.current.glucose == 206)
        #expect(advertisement.current.quality == 100)
        #expect(advertisement.current.isValid)
        #expect(advertisement.previous.map(\.glucose) == [204, 203])
    }

    @Test("Orders current and previous records by session minute") func ordersHistoricalRecords() throws {
        let advertisement = try #require(
            SmartAdvertisement(
                manufacturerData: try data(from: "59006B000000FF7580647480647580640000C9654683")
            )
        )

        #expect(advertisement.chronologicalRecords.map(\.minutesSinceStart) == [105, 106, 107])
        #expect(advertisement.chronologicalRecords.map(\.record.glucose) == [117, 116, 117])
        #expect(advertisement.chronologicalRecords.allSatisfy { $0.record.isValid })
    }

    @Test("Keeps the latest value when regularization is disabled") func keepsLatestRawValue() throws {
        var regularizer = SmartGlucoseRegularizer()
        ingest([100, 104, 99, 103, 101], startingAt: 200, into: &regularizer)

        let estimate = try #require(
            regularizer.estimate(at: 204, regularizationEnabled: false)
        )

        #expect(estimate.glucose == 101)
        #expect(!estimate.usedRegularization)
        #expect(estimate.sampleCount == 5)
    }

    @Test("Uses minute readings to regularize small stable oscillations") func regularizesStableNoise() throws {
        var regularizer = SmartGlucoseRegularizer()
        ingest([100, 104, 99, 103, 101], startingAt: 300, into: &regularizer)

        let estimate = try #require(
            regularizer.estimate(at: 304, regularizationEnabled: true)
        )

        #expect(estimate.glucose == 102)
        #expect(estimate.usedRegularization)
        #expect(abs((estimate.trendRate ?? 0) - 0.1) < 0.0001)
    }

    @Test("Never regularizes a rapid glucose change") func preservesRapidChange() throws {
        var regularizer = SmartGlucoseRegularizer()
        ingest([120, 115, 110, 105, 100], startingAt: 400, into: &regularizer)

        let estimate = try #require(
            regularizer.estimate(at: 404, regularizationEnabled: true)
        )

        #expect(estimate.glucose == 100)
        #expect(!estimate.usedRegularization)
        #expect((estimate.trendRate ?? 0) <= -2)
    }

    @Test("Never regularizes a falling value near the low range") func preservesFallingLow() throws {
        var regularizer = SmartGlucoseRegularizer()
        ingest([104, 103, 102, 101, 99], startingAt: 500, into: &regularizer)

        let estimate = try #require(
            regularizer.estimate(at: 504, regularizationEnabled: true)
        )

        #expect(estimate.glucose == 99)
        #expect(!estimate.usedRegularization)
        #expect((estimate.trendRate ?? 0) < 0)
    }

    @Test("Produces a current estimate for every new sensor minute") func estimatesEveryMinute() throws {
        var regularizer = SmartGlucoseRegularizer()
        ingest([100, 102], startingAt: 600, into: &regularizer)

        #expect(try #require(regularizer.estimate(at: 600, regularizationEnabled: false)).glucose == 100)
        #expect(try #require(regularizer.estimate(at: 601, regularizationEnabled: false)).glucose == 102)
    }

    @Test("Delivers to Trio every four minutes while retaining minute samples") func deliversAtTrioCadence() {
        #expect(
            SmartDeliveryCadence.shouldDeliver(
                currentMinute: 700,
                lastDeliveredMinute: nil
            )
        )
        #expect(
            !SmartDeliveryCadence.shouldDeliver(
                currentMinute: 701,
                lastDeliveredMinute: 700
            )
        )
        #expect(
            !SmartDeliveryCadence.shouldDeliver(
                currentMinute: 703,
                lastDeliveredMinute: 700
            )
        )
        #expect(
            SmartDeliveryCadence.shouldDeliver(
                currentMinute: 704,
                lastDeliveredMinute: 700
            )
        )
        #expect(
            SmartDeliveryCadence.shouldDeliver(
                currentMinute: 10,
                lastDeliveredMinute: 704
            )
        )
    }

    @Test("Keeps the current sensor active throughout the new Smart warmup") func waitsForSmartWarmup() {
        let count = SmartSensorHandoverPolicy.updatedReliableReadingCount(
            previousCount: 0,
            minutesSinceStart: 59,
            packetStateIsReliable: true,
            currentRecordIsReliable: true
        )

        #expect(count == 0)
        #expect(!SmartSensorHandoverPolicy.shouldHandover(reliableReadingCount: count))
    }

    @Test("Requires two reliable Smart advertisements before automatic handover") func validatesSmartHandover() {
        let firstReliableReading = SmartSensorHandoverPolicy.updatedReliableReadingCount(
            previousCount: 0,
            minutesSinceStart: 60,
            packetStateIsReliable: true,
            currentRecordIsReliable: true
        )
        let secondReliableReading = SmartSensorHandoverPolicy.updatedReliableReadingCount(
            previousCount: firstReliableReading,
            minutesSinceStart: 61,
            packetStateIsReliable: true,
            currentRecordIsReliable: true
        )

        #expect(firstReliableReading == 1)
        #expect(!SmartSensorHandoverPolicy.shouldHandover(reliableReadingCount: firstReliableReading))
        #expect(secondReliableReading == 2)
        #expect(SmartSensorHandoverPolicy.shouldHandover(reliableReadingCount: secondReliableReading))
    }

    @Test("Resets Smart handover validation after an unreliable advertisement") func resetsSmartHandoverValidation() {
        let resetCount = SmartSensorHandoverPolicy.updatedReliableReadingCount(
            previousCount: 1,
            minutesSinceStart: 61,
            packetStateIsReliable: false,
            currentRecordIsReliable: true
        )

        #expect(resetCount == 0)
        #expect(!SmartSensorHandoverPolicy.shouldHandover(reliableReadingCount: resetCount))
    }

    @Test("Protects automatic insulin after a large Smart-to-Smart jump") func detectsLargeHandoverDivergence() throws {
        let assessment = try #require(
            SmartHandoverDivergencePolicy.assess(
                referenceGlucose: 65,
                candidateGlucoseValues: [116, 117, 118]
            )
        )

        #expect(assessment.candidateGlucose == 117)
        #expect(assessment.absoluteDifference == 52)
        #expect(assessment.relativeDifference == 0.8)
        #expect(assessment.requiresFingerstickConfirmation)
    }

    @Test("Does not protect for a difference within the ordinary tolerance") func acceptsOrdinaryHandoverDifference() throws {
        let assessment = try #require(
            SmartHandoverDivergencePolicy.assess(
                referenceGlucose: 100,
                candidateGlucoseValues: [118, 119, 120]
            )
        )

        #expect(!assessment.requiresFingerstickConfirmation)
    }

    @Test("Requires both relative and absolute divergence") func requiresBothDivergenceLimits() throws {
        let assessment = try #require(
            SmartHandoverDivergencePolicy.assess(
                referenceGlucose: 300,
                candidateGlucoseValues: [329, 330, 331]
            )
        )

        #expect(assessment.absoluteDifference == 30)
        #expect(assessment.relativeDifference == 0.1)
        #expect(!assessment.requiresFingerstickConfirmation)
    }

    @Test("Releases a stable new Smart after thirty minutes") func releasesStableHandoverAfterThirtyMinutes() {
        let detectedAt = Date(timeIntervalSince1970: 1_807_000_000)

        #expect(
            SmartHandoverDivergencePolicy.shouldAutomaticallyRelease(
                detectedAt: detectedAt,
                now: detectedAt.addingTimeInterval(.minutes(30)),
                recentReliableGlucoseValues: [112, 115, 114, 117, 116]
            )
        )
    }

    @Test("Keeps an unstable new Smart protected before the maximum hold") func keepsUnstableHandoverProtected() {
        let detectedAt = Date(timeIntervalSince1970: 1_807_000_000)

        #expect(
            !SmartHandoverDivergencePolicy.shouldAutomaticallyRelease(
                detectedAt: detectedAt,
                now: detectedAt.addingTimeInterval(.minutes(45)),
                recentReliableGlucoseValues: [100, 123, 108, 130, 111]
            )
        )
    }

    @Test("Assumes the new Smart after sixty minutes of valid readings") func releasesHandoverAtMaximumHold() {
        let detectedAt = Date(timeIntervalSince1970: 1_807_000_000)

        #expect(
            SmartHandoverDivergencePolicy.shouldAutomaticallyRelease(
                detectedAt: detectedAt,
                now: detectedAt.addingTimeInterval(.minutes(60)),
                recentReliableGlucoseValues: [100, 123, 108, 130, 111]
            )
        )
    }

    @Test("Never releases without five valid new-sensor readings") func requiresReliableHandoverSeries() {
        let detectedAt = Date(timeIntervalSince1970: 1_807_000_000)

        #expect(
            !SmartHandoverDivergencePolicy.shouldAutomaticallyRelease(
                detectedAt: detectedAt,
                now: detectedAt.addingTimeInterval(.minutes(90)),
                recentReliableGlucoseValues: [110, 111, 112, 113]
            )
        )
    }

    @Test("Requires three new Smart deliveries before automatic insulin resumes") func reacquiresNewSensorReadings() {
        let first = SmartHandoverReacquisitionPolicy.updatedDeliveredReadingCount(previousCount: 0)
        let second = SmartHandoverReacquisitionPolicy.updatedDeliveredReadingCount(previousCount: first)
        let third = SmartHandoverReacquisitionPolicy.updatedDeliveredReadingCount(previousCount: second)

        #expect(first == 1)
        #expect(second == 2)
        #expect(!SmartHandoverReacquisitionPolicy.canResumeAutomaticInsulin(deliveredReadingCount: second))
        #expect(third == 3)
        #expect(SmartHandoverReacquisitionPolicy.canResumeAutomaticInsulin(deliveredReadingCount: third))
    }

    @Test("Restores a pending Smart handover after Trio restarts") func restoresPendingSmartHandover() throws {
        let activeIdentifier = UUID()
        let pendingIdentifier = UUID()
        let pendingStartDate = Date(timeIntervalSince1970: 1_807_000_000)
        let pendingCommunicationDate = pendingStartDate.addingTimeInterval(.minutes(34))
        let rawState: [String: Any] = [
            "peripheralIdentifier": activeIdentifier.uuidString,
            "pendingPeripheralIdentifier": pendingIdentifier.uuidString,
            "pendingSensorName": "Smart 2.0",
            "pendingSessionAnchor": pendingStartDate.timeIntervalSince1970,
            "pendingLastMinutes": 34,
            "pendingLastChecksum": 123_456,
            "pendingLastCommunicationDate": pendingCommunicationDate.timeIntervalSince1970,
            "pendingReliableReadingCount": 1
        ]

        let manager = try #require(SmartCGMManager(restoring: rawState, startsMonitoring: false))
        let restored = manager.rawState

        #expect(restored["peripheralIdentifier"] as? String == activeIdentifier.uuidString)
        #expect(restored["pendingPeripheralIdentifier"] as? String == pendingIdentifier.uuidString)
        #expect(restored["pendingSensorName"] as? String == "Smart 2.0")
        #expect(restored["pendingSessionAnchor"] as? TimeInterval == pendingStartDate.timeIntervalSince1970)
        #expect(restored["pendingLastMinutes"] as? Int == 34)
        #expect(restored["pendingLastChecksum"] as? Int == 123_456)
        #expect(
            restored["pendingLastCommunicationDate"] as? TimeInterval ==
                pendingCommunicationDate.timeIntervalSince1970
        )
        #expect(restored["pendingReliableReadingCount"] as? Int == 1)
    }

    @Test("Does not claim the Smart app is open after signal loss") func reportsNeutralSignalLoss() throws {
        let now = Date()
        let manager = try #require(
            SmartCGMManager(
                restoring: [
                    "peripheralIdentifier": UUID().uuidString,
                    "sensorSessionAnchor": now.addingTimeInterval(.hours(-2)).timeIntervalSince1970,
                    "lastMinutes": 120,
                    "lastCommunicationDate": now.addingTimeInterval(.minutes(-9)).timeIntervalSince1970
                ], startsMonitoring: false
            )
        )

        let message = try #require(manager.cgmStatusHighlight?.localizedMessage)
        #expect(message.localizedCaseInsensitiveContains("no signal"))
        #expect(!message.localizedCaseInsensitiveContains("close"))
    }

    @Test("Surfaces the active Smart warmup countdown") func surfacesActiveWarmup() throws {
        let now = Date()
        let start = now.addingTimeInterval(.minutes(-20))
        let manager = try #require(
            SmartCGMManager(
                restoring: [
                    "peripheralIdentifier": UUID().uuidString,
                    "sensorSessionAnchor": start.timeIntervalSince1970,
                    "lastMinutes": 20,
                    "lastStatus": 0,
                    "lastCommunicationDate": now.timeIntervalSince1970
                ], startsMonitoring: false
            )
        )

        let message = try #require(manager.cgmStatusHighlight?.localizedMessage)
        let readyAt = try #require(manager.smartWarmupEndsAt)
        let progress = try #require(manager.cgmLifecycleProgress)

        #expect(message.localizedCaseInsensitiveContains("warming up"))
        #expect(abs(readyAt.timeIntervalSince(start.addingTimeInterval(.hours(1)))) < 1)
        #expect(progress.percentComplete > 0.32)
        #expect(progress.percentComplete < 0.35)
    }

    @Test("Does not label a stopped Smart as warming") func rejectsFalseWarmup() throws {
        let now = Date()
        let manager = try #require(
            SmartCGMManager(
                restoring: [
                    "peripheralIdentifier": UUID().uuidString,
                    "sensorSessionAnchor": now.addingTimeInterval(.minutes(-30)).timeIntervalSince1970,
                    "lastMinutes": 0,
                    "lastStatus": 1,
                    "lastCalibrationTemperatureStatus": 3,
                    "lastQuality": 255,
                    "lastCommunicationDate": now.timeIntervalSince1970
                ], startsMonitoring: false
            )
        )

        let message = try #require(manager.cgmStatusHighlight?.localizedMessage)
        #expect(message.localizedCaseInsensitiveContains("not activated"))
        #expect(manager.smartWarmupEndsAt == nil)
        #expect(SmartSessionStatusPolicy.isStopped(status: 1))
        #expect(!SmartSessionStatusPolicy.isWarmupConfirmed(status: 1, minutesSinceStart: 0))
    }

    @Test("Shows the new Smart warmup while the old sensor stays active") func surfacesParallelWarmup() throws {
        let now = Date()
        let activeStart = now.addingTimeInterval(-14 * 24 * 60 * 60)
        let pendingStart = now.addingTimeInterval(.minutes(-25))
        let manager = try #require(
            SmartCGMManager(
                restoring: [
                    "peripheralIdentifier": UUID().uuidString,
                    "sensorSessionAnchor": activeStart.timeIntervalSince1970,
                    "lastMinutes": 14 * 24 * 60,
                    "lastCommunicationDate": now.timeIntervalSince1970,
                    "pendingPeripheralIdentifier": UUID().uuidString,
                    "pendingSessionAnchor": pendingStart.timeIntervalSince1970,
                    "pendingLastMinutes": 25,
                    "pendingLastCommunicationDate": now.timeIntervalSince1970,
                    "pendingReliableReadingCount": 0
                ], startsMonitoring: false
            )
        )

        let message = try #require(manager.cgmStatusHighlight?.localizedMessage)
        let readyAt = try #require(manager.smartWarmupEndsAt)
        let progress = try #require(manager.cgmLifecycleProgress)

        #expect(message.localizedCaseInsensitiveContains("new Smart"))
        #expect(message.localizedCaseInsensitiveContains("warming up"))
        #expect(abs(readyAt.timeIntervalSince(pendingStart.addingTimeInterval(.hours(1)))) < 1)
        #expect(progress.percentComplete > 0.40)
        #expect(progress.percentComplete < 0.43)
    }

    @Test(
        "Prioritizes a warming replacement over a stopped outgoing Smart"
    ) func prioritizesParallelWarmupOverStoppedOutgoingSensor() throws {
        let now = Date()
        let pendingStart = now.addingTimeInterval(.minutes(-45))
        let pendingCommunication = now.addingTimeInterval(-5)
        let manager = try #require(
            SmartCGMManager(
                restoring: [
                    "peripheralIdentifier": UUID().uuidString,
                    "sensorSessionAnchor": now.addingTimeInterval(.hours(-2)).timeIntervalSince1970,
                    "lastMinutes": 0,
                    "lastStatus": 1,
                    "lastCommunicationDate": now.addingTimeInterval(.minutes(-15)).timeIntervalSince1970,
                    "pendingPeripheralIdentifier": UUID().uuidString,
                    "pendingSessionAnchor": pendingStart.timeIntervalSince1970,
                    "pendingLastMinutes": 45,
                    "pendingLastCommunicationDate": pendingCommunication.timeIntervalSince1970,
                    "pendingReliableReadingCount": 0
                ], startsMonitoring: false
            )
        )

        let message = try #require(manager.cgmStatusHighlight?.localizedMessage)
        let readyAt = try #require(manager.smartWarmupEndsAt)

        #expect(message.localizedCaseInsensitiveContains("new Smart"))
        #expect(message.localizedCaseInsensitiveContains("warming up"))
        #expect(!message.localizedCaseInsensitiveContains("not activated"))
        #expect(abs(readyAt.timeIntervalSince(pendingStart.addingTimeInterval(.hours(1)))) < 1)
        #expect(manager.sensorObservation(now: now) == .unreliable(.replacementWarmup))
        #expect(manager.cgmManagerStatus.hasValidSensorSession)
        let reportedCommunication = try #require(manager.cgmManagerStatus.lastCommunicationDate)
        #expect(abs(reportedCommunication.timeIntervalSince(pendingCommunication)) < 0.001)
    }

    @Test(
        "Keeps the outgoing reliable Smart as the CGM observation during replacement warmup"
    ) func keepsReliableOutgoingObservationDuringParallelWarmup() throws {
        let now = Date()
        let manager = try #require(
            SmartCGMManager(
                restoring: [
                    "peripheralIdentifier": UUID().uuidString,
                    "sensorSessionAnchor": now.addingTimeInterval(-.hours(24)).timeIntervalSince1970,
                    "lastMinutes": 24 * 60,
                    "lastStatus": 0,
                    "lastCalibrationTemperatureStatus": 0,
                    "lastCommunicationDate": now.timeIntervalSince1970,
                    "currentGlucose": 112.0,
                    "currentGlucoseDate": now.timeIntervalSince1970,
                    "pendingPeripheralIdentifier": UUID().uuidString,
                    "pendingSessionAnchor": now.addingTimeInterval(.minutes(-20)).timeIntervalSince1970,
                    "pendingLastMinutes": 20,
                    "pendingLastCommunicationDate": now.timeIntervalSince1970,
                    "pendingReliableReadingCount": 0
                ], startsMonitoring: false
            )
        )

        #expect(manager.sensorObservation(now: now) == .reliable)
    }

    @Test("Does not report stale Smart communication as reliable") func rejectsStaleCommunicationObservation() throws {
        let now = Date()
        let manager = try #require(
            SmartCGMManager(
                restoring: [
                    "peripheralIdentifier": UUID().uuidString,
                    "sensorSessionAnchor": now.addingTimeInterval(-.hours(24)).timeIntervalSince1970,
                    "lastMinutes": 24 * 60,
                    "lastStatus": 0,
                    "lastCalibrationTemperatureStatus": 0,
                    "lastCommunicationDate": now.addingTimeInterval(-.minutes(9)).timeIntervalSince1970,
                    "currentGlucose": 112.0,
                    "currentGlucoseDate": now.addingTimeInterval(-.minutes(9)).timeIntervalSince1970
                ], startsMonitoring: false
            )
        )

        #expect(manager.sensorObservation(now: now) == .unreliable(.noSignal))
    }

    @Test(
        "Reports initial Smart lifecycle states without claiming a valid stopped session"
    ) func reportsInitialLifecycleObservations() throws {
        let now = Date()
        let stopped = try #require(
            SmartCGMManager(
                restoring: [
                    "peripheralIdentifier": UUID().uuidString,
                    "sensorSessionAnchor": now.timeIntervalSince1970,
                    "lastMinutes": 0,
                    "lastStatus": 1,
                    "lastCommunicationDate": now.timeIntervalSince1970
                ], startsMonitoring: false
            )
        )
        #expect(stopped.sensorObservation(now: now) == .unreliable(.notActivated))
        #expect(!stopped.cgmManagerStatus.hasValidSensorSession)

        let warming = try #require(
            SmartCGMManager(
                restoring: [
                    "peripheralIdentifier": UUID().uuidString,
                    "sensorSessionAnchor": now.addingTimeInterval(.minutes(-30)).timeIntervalSince1970,
                    "lastMinutes": 30,
                    "lastStatus": 0,
                    "lastCalibrationTemperatureStatus": 0,
                    "lastCommunicationDate": now.timeIntervalSince1970
                ], startsMonitoring: false
            )
        )
        #expect(warming.sensorObservation(now: now) == .unreliable(.warmup))
        #expect(warming.cgmManagerStatus.hasValidSensorSession)
    }

    @Test("Schedules the three Smart replacement notifications") func schedulesSmartReplacementNotifications() {
        let now = Date(timeIntervalSince1970: 1_807_000_000)
        let expiresAt = now.addingTimeInterval(.hours(25))
        let notifications = SmartSensorReminderPolicy.notifications(
            expiresAt: expiresAt,
            now: now
        )

        #expect(notifications.map(\.kind) == [
            .expiresIn24Hours,
            .prepareIn120Minutes,
            .replaceIn65Minutes
        ])
        #expect(notifications[0].deliveryDate == expiresAt.addingTimeInterval(-.hours(24)))
        #expect(notifications[1].deliveryDate == expiresAt.addingTimeInterval(-.minutes(120)))
        #expect(notifications[2].deliveryDate == expiresAt.addingTimeInterval(-.minutes(65)))
    }

    @Test("Catches up only the actionable Smart replacement notification") func catchesUpSmartReplacementNotification() {
        let now = Date(timeIntervalSince1970: 1_807_000_000)
        let expiresAt = now.addingTimeInterval(.minutes(30))
        let notifications = SmartSensorReminderPolicy.notifications(
            expiresAt: expiresAt,
            now: now
        )

        #expect(notifications.count == 1)
        #expect(notifications.first?.kind == .replaceIn65Minutes)
        #expect(notifications.first?.deliveryDate == now.addingTimeInterval(2))
    }

    @Test("Does not notify after a Smart sensor has expired") func skipsExpiredSmartNotifications() {
        let now = Date(timeIntervalSince1970: 1_807_000_000)
        let notifications = SmartSensorReminderPolicy.notifications(
            expiresAt: now.addingTimeInterval(-1),
            now: now
        )

        #expect(notifications.isEmpty)
    }

    @Test("Parses the Smart CGM feature captured from the sensor") func parsesCGMFeature() throws {
        let feature = try #require(
            SmartCGMFeature(data: try data(from: "419101590C2B"))
        )

        #expect(feature.featureBits == 0x019141)
        #expect(feature.typeAndSampleLocation == 0x59)
        #expect(feature.supportsE2ECRC)
    }

    @Test("Parses standard CGM records including optional fields and CRC") func parsesCGMRecords() throws {
        let records = try SmartCGMMeasurement.records(
            from: try data(
                from: "0FE37B0034120102040FF062004AAE0800640035126258"
            ),
            supportsE2ECRC: true
        )

        #expect(records.count == 2)
        #expect(records[0].glucose == 123)
        #expect(records[0].timeOffset == 0x1234)
        #expect(records[0].trendRate == 1.5)
        #expect(records[0].quality == 98)
        #expect(records[0].sensorStatus == 1)
        #expect(records[0].calibrationTemperatureStatus == 2)
        #expect(records[0].warningStatus == 4)
        #expect(records[1].glucose == 100)
        #expect(records[1].timeOffset == 0x1235)
        #expect(records[1].trendRate == nil)
        #expect(records[1].quality == nil)
    }

    @Test("Rejects a historical record with an invalid CGM CRC") func rejectsInvalidCGMCRC() throws {
        #expect(throws: SmartCGMMeasurement.ParsingError.invalidCRC) {
            try SmartCGMMeasurement.records(
                from: try data(from: "0800640035126259"),
                supportsE2ECRC: true
            )
        }
    }

    @Test("Rejects incomplete standard CGM records") func rejectsIncompleteCGMRecord() throws {
        #expect(throws: SmartCGMMeasurement.ParsingError.truncatedRecord) {
            try SmartCGMMeasurement.records(
                from: try data(from: "08"),
                supportsE2ECRC: true
            )
        }
    }

    @Test("Parses a stopped CGM session before activation") func parsesStoppedCGMStatus() throws {
        let status = try SmartCGMStatus(
            data: Data([0x34, 0x12, 0x09, 0x00, 0x00]),
            supportsE2ECRC: false
        )

        #expect(status.timeOffset == 0x1234)
        #expect(status.isSessionStopped)
        #expect(status.needsTimeSynchronization)
    }

    @Test("Starts only a stopped sensor during onboarding") func preparesStoppedSession() throws {
        let status = try SmartCGMStatus(
            data: Data([0x00, 0x00, 0x01, 0x00, 0x00]),
            supportsE2ECRC: false
        )

        #expect(
            SmartCGMSessionPreparation.decide(
                status: status,
                now: Date(),
                allowActiveSessionAdoption: true
            ) == .startNewSession
        )
    }

    @Test("Adopts an active sensor without restarting it") func adoptsActiveSession() throws {
        let now = Date(timeIntervalSince1970: 1_788_111_000)
        let status = try SmartCGMStatus(
            data: Data([0x3C, 0x00, 0x00, 0x00, 0x00]),
            supportsE2ECRC: false
        )

        let decision = SmartCGMSessionPreparation.decide(
            status: status,
            now: now,
            allowActiveSessionAdoption: true
        )
        #expect(decision == .adoptActiveSession(startDate: now.addingTimeInterval(.minutes(-60))))
        #expect(
            SmartCGMSessionPreparation.decide(
                status: status,
                now: now,
                allowActiveSessionAdoption: false
            ) == .rejectActiveSession
        )
    }

    @Test("Builds and validates the standard Smart start-session exchange") func validatesStartSession() throws {
        #expect(
            SmartCGMSpecificOpsControlPoint.startSessionCommand(
                supportsE2ECRC: false
            ) == Data([0x1A])
        )

        let commandWithCRC = SmartCGMSpecificOpsControlPoint.startSessionCommand(
            supportsE2ECRC: true
        )
        #expect(commandWithCRC.count == 3)
        #expect(SmartCGMCRC.isValid([UInt8](commandWithCRC)))

        try SmartCGMSpecificOpsControlPoint.validateStartSessionResponse(
            Data([0x1C, 0x1A, 0x01]),
            supportsE2ECRC: false
        )
        #expect(throws: SmartCGMSpecificOpsControlPoint.ResponseError.failed(0x04)) {
            try SmartCGMSpecificOpsControlPoint.validateStartSessionResponse(
                Data([0x1C, 0x1A, 0x04]),
                supportsE2ECRC: false
            )
        }
    }

    @Test("Encodes the CGM session start time in the local timezone") func encodesSessionStartTime() throws {
        let timeZone = try #require(TimeZone(secondsFromGMT: -3 * 60 * 60))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 3,
                    hour: 12,
                    minute: 34,
                    second: 56
                )
            )
        )

        #expect(
            SmartCGMSessionStartTime.data(
                date: date,
                timeZone: timeZone,
                supportsE2ECRC: false
            ) == Data([0xEA, 0x07, 0x08, 0x03, 0x0C, 0x22, 0x38, 0xF4, 0x00])
        )

        let valueWithCRC = SmartCGMSessionStartTime.data(
            date: date,
            timeZone: timeZone,
            supportsE2ECRC: true
        )
        #expect(valueWithCRC.count == 11)
        #expect(SmartCGMCRC.isValid([UInt8](valueWithCRC)))
    }

    @Test("Builds read-only historical record requests") func buildsBackfillRequest() {
        #expect(
            SmartRecordAccessControlPoint.reportStoredRecords(from: nil) ==
                Data([0x01, 0x01])
        )
        #expect(
            SmartRecordAccessControlPoint.reportStoredRecords(from: 0x1234) ==
                Data([0x01, 0x03, 0x01, 0x34, 0x12])
        )
    }

    @Test("Parses historical record completion responses") func parsesBackfillResponse() {
        #expect(
            SmartRecordAccessControlPoint.response(
                from: Data([0x05, 0x00, 0x2A, 0x00])
            ) == .numberOfRecords(42)
        )
        #expect(
            SmartRecordAccessControlPoint.response(
                from: Data([0x06, 0x00, 0x01, 0x01])
            ) == .completion(requestOpcode: 0x01, responseCode: 0x01)
        )
    }

    @Test("Selects a safe five-minute backfill series limited to six hours") func selectsBackfillSeries() {
        let records = (0 ... 400).map { minute in
            SmartCGMMeasurement(
                glucose: Double(100 + minute % 20),
                timeOffset: UInt16(minute),
                trendRate: nil,
                quality: 100,
                sensorStatus: nil,
                calibrationTemperatureStatus: nil,
                warningStatus: nil
            )
        }

        let selected = SmartBackfillSelector.select(records, endingAt: 400)

        #expect(selected.first?.timeOffset == 40)
        #expect(selected.last?.timeOffset == 400)
        #expect(selected.count == 73)
        #expect(
            zip(selected, selected.dropFirst()).allSatisfy {
                $1.timeOffset - $0.timeOffset >= 5
            }
        )
    }

    private func ingest(
        _ glucose: [UInt16],
        startingAt firstMinute: UInt16,
        into regularizer: inout SmartGlucoseRegularizer
    ) {
        for (offset, value) in glucose.enumerated() {
            regularizer.ingest(
                [(
                    minutesSinceStart: firstMinute + UInt16(offset),
                    record: SmartAdvertisement.GlucoseRecord(
                        glucose: value,
                        quality: 100,
                        isValid: true
                    )
                )],
                packetStateIsReliable: true
            )
        }
    }

    private func data(from hex: String) throws -> Data {
        let characters = Array(hex)
        guard characters.count.isMultiple(of: 2) else {
            throw TestError("Hex input must contain an even number of characters")
        }

        return try Data(stride(from: 0, to: characters.count, by: 2).map { offset in
            let byte = String(characters[offset ... offset + 1])
            guard let value = UInt8(byte, radix: 16) else {
                throw TestError("Invalid hexadecimal byte: \(byte)")
            }
            return value
        })
    }
}

private struct TestError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

@Suite("Smart module migration compatibility", .serialized) struct SmartMigrationCompatibilityTests {
    @Test("Legacy manager identifier remains stable") func managerIdentifier() {
        #expect(SmartCGMManager.pluginIdentifier == "SmartCGMManager")
    }

    @Test("Restoration preserves processing history, cadence and calibration source") func processingStateRoundTrip() throws {
        let id = UUID().uuidString
        let epoch = 1_800_000_000.0
        let state: [String: Any] = [
            "peripheralIdentifier": id,
            "sensorSessionAnchor": epoch,
            "lastMinutes": 82,
            "lastDeliveredMinute": 80,
            "currentGlucose": 123.0,
            "currentGlucoseDate": epoch + 82 * 60,
            "lastDeliveredGlucose": 121.0,
            "lastDeliveredGlucoseDate": epoch + 80 * 60,
            "derivedTrendRate": 0.5,
            "regularizationEnabled": true,
            "lastEstimateUsedRegularization": true,
            "minuteHistoryMinutes": [80, 81, 82],
            "minuteHistoryGlucose": [121.0, 122.0, 123.0],
            "minuteHistoryQuality": [100, 100, 100],
            "lastBackfillDate": epoch + 75 * 60,
            "lastBackfillRecordCount": 12
        ]
        let manager = try #require(SmartCGMManager(restoring: state, startsMonitoring: false))
        let restored = manager.rawState
        #expect(restored["lastDeliveredMinute"] as? Int == 80)
        #expect(restored["regularizationEnabled"] as? Bool == true)
        #expect(restored["minuteHistoryMinutes"] as? [Int] == [80, 81, 82])
        #expect(restored["minuteHistoryGlucose"] as? [Double] == [121, 122, 123])
        #expect(restored["lastBackfillRecordCount"] as? Int == 12)
        #expect(manager.calibrationSnapshot()?.glucose == 123)
        #expect(manager.calibrationSnapshot()?.trendRate == 0.5)
    }

    @Test("An invalid stored identity cannot restore a manager") func invalidIdentity() {
        #expect(SmartCGMManager(restoring: ["peripheralIdentifier": "invalid"], startsMonitoring: false) == nil)
    }

    @Test("The active sensor cannot also become its pending replacement") func duplicateIdentityRejected() throws {
        let id = UUID().uuidString
        let manager = try #require(SmartCGMManager(restoring: [
            "peripheralIdentifier": id,
            "pendingPeripheralIdentifier": id,
            "pendingSessionAnchor": 1_800_000_000.0
        ], startsMonitoring: false))
        #expect(manager.rawState["pendingPeripheralIdentifier"] == nil)
    }

    @Test("The legacy interlock survives module extraction and enforces sensor ownership") func legacyInterlockRoundTrip() throws {
        let key = "CGMAutomaticInsulinSafetyInterlock.smartHandover"
        let previous = UserDefaults.standard.data(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let id = UUID().uuidString
        let legacy = SmartAutomaticInsulinSafetyInterlock.State(
            sensorIdentifier: id, referenceGlucose: 100, candidateGlucose: 150,
            detectedAt: Date(timeIntervalSince1970: 1_800_000_000), phase: nil
        )
        UserDefaults.standard.set(try JSONEncoder().encode(legacy), forKey: key)
        #expect(SmartAutomaticInsulinSafetyInterlock.state == legacy)
        #expect(SmartAutomaticInsulinSafetyInterlock.blockingMessage != nil)
        SmartAutomaticInsulinSafetyInterlock.clear(sensorIdentifier: UUID().uuidString)
        #expect(SmartAutomaticInsulinSafetyInterlock.state == legacy)
        SmartAutomaticInsulinSafetyInterlock.beginReacquisition(sensorIdentifier: id)
        #expect(SmartAutomaticInsulinSafetyInterlock.state?.phase == .reacquiring)
        #expect(SmartAutomaticInsulinSafetyInterlock.blockingMessage != nil)
        SmartAutomaticInsulinSafetyInterlock.clear(sensorIdentifier: id)
        #expect(SmartAutomaticInsulinSafetyInterlock.state == nil)
    }
}

@Suite("Smart calibration admission") struct SmartCalibrationPolicyTests {
    @Test("Retains the five-minute freshness and two-minute future boundaries") func freshness() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SmartCalibrationPolicy.isRecent(now.addingTimeInterval(-300), now: now))
        #expect(!SmartCalibrationPolicy.isRecent(now.addingTimeInterval(-301), now: now))
        #expect(SmartCalibrationPolicy.isRecent(now.addingTimeInterval(120), now: now))
        #expect(!SmartCalibrationPolicy.isRecent(now.addingTimeInterval(121), now: now))
    }

    @Test("Requires a known stable trend before accepting calibration") func stability() {
        #expect(SmartCalibrationPolicy.isStable(1.99))
        #expect(SmartCalibrationPolicy.isStable(-1.99))
        #expect(!SmartCalibrationPolicy.isStable(2))
        #expect(!SmartCalibrationPolicy.isStable(-2))
        #expect(!SmartCalibrationPolicy.isStable(nil))
        #expect(!SmartCalibrationPolicy.isStable(.nan))
    }
}

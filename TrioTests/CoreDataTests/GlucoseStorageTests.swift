import ActivityKit
import CoreData
import Foundation
import Swinject
import Testing

@testable import Trio

@Suite("GlucoseStorage Tests", .serialized) struct GlucoseStorageTests: Injectable {
    @Injected() var storage: GlucoseStorage!
    let resolver: Resolver
    var coreDataStack: CoreDataStack!
    var testContext: NSManagedObjectContext!

    init() async throws {
        // Create test context
        // As we are only using this single test context to initialize our in-memory DeterminationStorage we need to perform the Unit Tests serialized
        coreDataStack = try await CoreDataStack.createForTests()
        testContext = coreDataStack.newTaskContext()

        // Create assembler with test assembly
        let assembler = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly(),
            TestAssembly(testContext: testContext) // Add our test assembly last to override Storage
        ])

        resolver = assembler.resolver
        injectServices(resolver)
    }

    @Test("Storage is correctly initialized") func testStorageInitialization() {
        // Verify storage exists
        #expect(storage != nil, "GlucoseStorage should be injected")

        // Verify it's the correct type
        #expect(storage is BaseGlucoseStorage, "Storage should be of type BaseGlucoseStorage")
    }

    @Test("Store and retrieve glucose entries") func testStoreAndRetrieveGlucose() async throws {
        // Given
        let testGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 126)
        ]

        // When
        try await storage.storeGlucose(testGlucose)

        // Then verify stored entries
        let storedEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 126"),
            key: "date",
            ascending: false
        ) as? [GlucoseStored]

        #expect(storedEntries?.isEmpty == false, "Should have stored entries")
        #expect(storedEntries?.count == 1, "Should have exactly one entry")
        #expect(storedEntries?[0].glucose == 126, "Glucose value should match")
        #expect(storedEntries?[0].direction == "Flat", "Direction should match")
    }

    @Test("Delete glucose entry") func testDeleteGlucose() async throws {
        // Given
        let testGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 140)
        ]
        try await storage.storeGlucose(testGlucose)

        // Get the stored entry's ObjectID
        let storedEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 140"),
            key: "date",
            ascending: false
        ) as? [GlucoseStored]

        guard let objectID = storedEntries?.first?.objectID else {
            throw TestError("Failed to get stored entry's ObjectID")
        }

        #expect(storedEntries.isNotNilNotEmpty == true, "Should have exactly one (test) entry")

        // When
        await storage.deleteGlucose(objectID)

        // Then verify deletion
        let remainingEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 140"),
            key: "date",
            ascending: false
        ) as? [GlucoseStored]

        #expect(remainingEntries?.isEmpty == true, "Should have no entries after deletion")

        // Finally verify that it stored a copy
        let archivedEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: DeletedGlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 140"),
            key: "date",
            ascending: false
        ) as? [DeletedGlucoseStored]

        #expect(archivedEntries?.isEmpty == false, "Should have archived entries after deletion")
    }

    @Test("Get glucose not yet uploaded to Nightscout") func testGetGlucoseNotYetUploadedToNightscout() async throws {
        // Given
        let testGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 160)
        ]
        try await storage.storeGlucose(testGlucose)

        // When
        let notUploadedEntries = try await storage.getGlucoseNotYetUploadedToNightscout()

        // Then
        #expect(!notUploadedEntries.isEmpty, "Should have entries not uploaded to NS")
        #expect(notUploadedEntries[0].glucose == 160, "Glucose value should match")
    }

    @Test("Sub-39 glucose is clamped to 39 on storeGlucose") func testStoreGlucoseClampsBelowMinimum() async throws {
        // Given a CGM reading below the 39 mg/dL floor (e.g. LibreTransmitter delivering 23)
        let testGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 23)
        ]

        // When
        try await storage.storeGlucose(testGlucose)

        // Then the stored row should be clamped to 39, not 23
        let clampedEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 39"),
            key: "date",
            ascending: false
        ) as? [GlucoseStored]

        #expect(clampedEntries?.count == 1, "Sub-39 glucose should be clamped and stored as 39")

        let rawEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 23"),
            key: "date",
            ascending: false
        ) as? [GlucoseStored]

        #expect(rawEntries?.isEmpty == true, "Raw sub-39 value must not be persisted")
    }

    @Test("Sub-39 glucose is clamped to 39 on backfillGlucose") func testBackfillGlucoseClampsBelowMinimum() async throws {
        // Given a backfilled CGM reading below the 39 mg/dL floor
        let backfillDate = Date().addingTimeInterval(-30 * 60)
        let testGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 456, dateString: backfillDate, glucose: 28)
        ]

        // When
        try await storage.backfillGlucose(testGlucose)

        // Then the backfilled row should be clamped to 39
        let clampedEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 39"),
            key: "date",
            ascending: false
        ) as? [GlucoseStored]

        #expect(clampedEntries?.count == 1, "Sub-39 backfilled glucose should be clamped and stored as 39")
    }

    @Test("CGM state upload ledger excludes completed treatments") func testCGMStateUploadLedgerPending() {
        let first = makeSensorChange(date: Date(timeIntervalSince1970: 1000), notes: "first")
        let second = makeSensorChange(date: Date(timeIntervalSince1970: 2000), notes: "second")

        let pending = CGMStateUploadLedger.pending(
            all: [second, first],
            uploaded: [first]
        )

        #expect(pending == [second])
    }

    @Test("CGM state upload ledger merges, deduplicates, and prunes") func testCGMStateUploadLedgerMerge() {
        let now = Date(timeIntervalSince1970: 4_000_000)
        let expired = makeSensorChange(
            date: now.addingTimeInterval(-31.days.timeInterval),
            notes: "expired"
        )
        let current = makeSensorChange(
            date: now.addingTimeInterval(-1.days.timeInterval),
            notes: "current"
        )

        let merged = CGMStateUploadLedger.merging(
            existing: [expired, current],
            successfullyUploaded: [current],
            now: now
        )

        #expect(merged == [current])
    }

    @Test("Live Activity keeps the complete six-hour chart window") func testLiveActivityChartCoverage() {
        let newestDate = Date(timeIntervalSince1970: 10000)
        let points = (0 ..< 360).map { minute in
            GlucoseData(
                glucose: 100 + minute % 10,
                date: newestDate.addingTimeInterval(TimeInterval(-minute * 60)),
                direction: .flat
            )
        }

        let rendered = LiveActivityGlucoseChartPolicy.pointsForRendering(points)

        #expect(rendered.count == LiveActivityGlucoseChartPolicy.maximumRenderedPointCount)
        #expect(rendered[0].date == points[0].date)
        #expect(rendered[1].date == points[1].date)
        #expect(rendered.last?.date == points.last?.date)
    }

    @Test("Live Activity preserves every Smart point when no reduction is needed") func testLiveActivityKeepsSmartPoints() {
        let points = (0 ..< 90).map { minute in
            GlucoseData(
                glucose: 100,
                date: Date(timeIntervalSince1970: TimeInterval(minute * 4 * 60)),
                direction: .flat
            )
        }

        let rendered = LiveActivityGlucoseChartPolicy.pointsForRendering(points)

        #expect(rendered.count == points.count)
        #expect(rendered.first?.date == points.first?.date)
        #expect(rendered.last?.date == points.last?.date)
    }

    @Test(
        "Live Activity keeps updating an old session while Trio is in the background"
    ) func testLiveActivityOldBackgroundSessionContinuesUpdating() {
        let now = Date(timeIntervalSince1970: 30000)
        let action = LiveActivityUpdatePolicy.existingSessionAction(
            activityState: .active,
            startDate: now.addingTimeInterval(-(LiveActivityUpdatePolicy.maximumActivityAge + 60)),
            isAppActive: false,
            now: now
        )

        #expect(action == .update)
    }

    @Test("Live Activity recreates an old session when Trio becomes active") func testLiveActivityOldForegroundSessionRecreates() {
        let now = Date(timeIntervalSince1970: 30000)
        let action = LiveActivityUpdatePolicy.existingSessionAction(
            activityState: .active,
            startDate: now.addingTimeInterval(-(LiveActivityUpdatePolicy.maximumActivityAge + 60)),
            isAppActive: true,
            now: now
        )

        #expect(action == .recreate)
    }

    @Test(
        "Live Activity waits for foreground before replacing an ended session"
    ) func testLiveActivityEndedBackgroundSessionWaits() {
        let action = LiveActivityUpdatePolicy.existingSessionAction(
            activityState: .ended,
            startDate: Date(timeIntervalSince1970: 1000),
            isAppActive: false,
            now: Date(timeIntervalSince1970: 2000)
        )

        #expect(action == .waitForForeground)
    }

    @Test("Live Activity calculates glucose change from exactly two readings") func testLiveActivityChangeWithTwoReadings() {
        let points = [
            GlucoseData(glucose: 105, date: Date(timeIntervalSince1970: 2000), direction: .flat),
            GlucoseData(glucose: 100, date: Date(timeIntervalSince1970: 1700), direction: .flat)
        ]

        let change = LiveActivityAttributes.ContentState.calculateChange(chart: points, units: .mgdL)

        #expect(!change.isEmpty)
        #expect(change.contains("5"))
    }

    @Test(
        "Test glucose alarms",
        .enabled(if: false, "Flaky test, disabled while investigating")
    ) func testGlucoseAlarms() async throws {
        // Given
        let lowGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 55)
        ]
        let highGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 271)
        ]
        let normalGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 100)
        ]

        // When - Test low glucose
        try await storage.storeGlucose(lowGlucose)
        var storedEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 55"),
            key: "date",
            ascending: false
        ) as? [GlucoseStored]

        // Then
        #expect(storedEntries?.first?.glucose == 55, "Low glucose value should match")
        #expect(storage.alarm == .low, "Should trigger low glucose alarm") // default low limit is 72 mg/dL

        // When - Test high glucose
        try await storage.storeGlucose(highGlucose)
        storedEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 271"),
            key: "date",
            ascending: false
        ) as? [GlucoseStored]

        // Then
        #expect(storedEntries?.first?.glucose == 271, "High glucose value should match")
        #expect(storage.alarm == .high, "Should trigger high glucose alarm") // default high limit is 270 mg/dL

        // When - Test normal glucose
        try await storage.storeGlucose(normalGlucose)
        storedEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 100"),
            key: "date",
            ascending: false
        ) as? [GlucoseStored]

        // Then
        #expect(storedEntries?.first?.glucose == 100, "Normal glucose value should match")
        #expect(storage.alarm == nil, "Should not trigger any alarm")
    }

    /* Commenting out while we don't have getGlucoseStatus defined
     @Test("getGlucoseStatus returns correct deltas for 0/5/15/30m readings") func testGetGlucoseStatusFourPoints() async throws {
         let now = Date()
         // Prepare 4 readings: at 0, 5, 15, and 30 minutes ago
         let specs: [(offset: TimeInterval, value: Int)] = [
             (0, 100), // now
             (5 * 60, 110), // 5m ago
             (15 * 60, 120), // 15m ago
             (30 * 60, 130) // 30m ago
         ]

         // Insert them into CoreData so that our fetch predicate picks them up
         for (offset, value) in specs {
             await testContext.perform {
                 let glucoseToStore = GlucoseStored(context: testContext)
                 glucoseToStore.id = UUID()
                 glucoseToStore.date = now.addingTimeInterval(-offset)
                 glucoseToStore.glucose = Int16(value)
             }
         }
         try testContext.save()

         // Call the method under test
         let status = try await storage.getGlucoseStatus()
         #expect(status != nil, "Expected non‐nil status")

         // “Now” glucose is the 0m reading
         #expect(status!.glucose == 100)

         // lastDelta: only the 5m point: (100–110)/5*5 = –10
         #expect(status!.delta == -10)

         // shortAvgDelta: average of 5m and 15m windows:
         //   5m window:   (100–110)/5*5   = –10
         //   15m window: (100–120)/15*5 ≈ –6.6667 → –6.67
         //   avg ≈ (–10 + –6.67)/2 = –8.333… → rounded to –8.33
         #expect(status!.shortAvgDelta == -8.33)

         // longAvgDelta: only the 30m window: (100–130)/30*5 = –5
         #expect(status!.longAvgDelta == -5)
     }*/

    private func makeSensorChange(date: Date, notes: String) -> NightscoutTreatment {
        NightscoutTreatment(
            eventType: .nsSensorChange,
            createdAt: date,
            enteredBy: NightscoutTreatment.local,
            notes: notes,
            targetTop: nil,
            targetBottom: nil
        )
    }
}

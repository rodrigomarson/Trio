import CoreData
import Foundation

enum LiveActivityGlucoseChartPolicy {
    /// A six-hour window can contain up to 360 one-minute CGM samples.
    static let maximumFetchedPointCount = 360

    /// The lock-screen chart cannot visually distinguish hundreds of adjacent
    /// points. Capping the rendered payload keeps ActivityKit updates efficient
    /// while retaining the newest values and coverage of the complete window.
    static let maximumRenderedPointCount = 120

    static func pointsForRendering(_ points: [GlucoseData]) -> [GlucoseData] {
        guard points.count > maximumRenderedPointCount else { return points }

        let newest = Array(points.prefix(2))
        let older = Array(points.dropFirst(2))
        let availableSlots = maximumRenderedPointCount - newest.count
        guard availableSlots > 1, older.count > availableSlots else {
            return Array(points.prefix(maximumRenderedPointCount))
        }

        let lastIndex = older.count - 1
        let sampledOlder = (0 ..< availableSlots).map { slot in
            let ratio = Double(slot) / Double(availableSlots - 1)
            let index = Int((ratio * Double(lastIndex)).rounded())
            return older[index]
        }
        return newest + sampledOlder
    }
}

// Fetch Data for Glucose and Determination from Core Data and map them to the Structs in order to pass them thread safe to the glucoseDidUpdate/ pushUpdate function

@available(iOS 16.2, *)
extension LiveActivityManager {
    func fetchAndMapGlucose() async throws -> [GlucoseData] {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "fetchAndMapGlucose"
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate.predicateForSixHoursAgo,
            key: "date",
            ascending: false,
            fetchLimit: LiveActivityGlucoseChartPolicy.maximumFetchedPointCount
        )

        return try await context.perform {
            guard let glucoseResults = results as? [GlucoseStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            let points = glucoseResults.map {
                GlucoseData(glucose: Int($0.glucose), date: $0.date ?? Date(), direction: $0.directionEnum)
            }
            return LiveActivityGlucoseChartPolicy.pointsForRendering(points)
        }
    }

    // TODO: extract logic or at least rename function appropiately
    func fetchAndMapDetermination() async throws -> DeterminationData? {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "fetchAndMapDetermination"
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: OrefDetermination.self,
            onContext: context,
            predicate: NSPredicate.predicateFor30MinAgoForDetermination,
            key: "deliverAt",
            ascending: false,
            fetchLimit: 1,
            relationshipKeyPathsForPrefetching: ["forecasts", "forecasts.forecastValues"]
        )

        let tddResults = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: TDDStored.self,
            onContext: context,
            predicate: NSPredicate.predicateFor30MinAgo,
            key: "date",
            ascending: false,
            fetchLimit: 1,
            propertiesToFetch: ["total"]
        )

        return try await context.perform {
            guard let determinationResults = results as? [OrefDetermination],
                  let tddResults = tddResults as? [[String: Any]]
            else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            guard let determination = determinationResults.first else {
                return nil
            }

            let tddValue = (tddResults.first?["total"] as? NSDecimalNumber)?.decimalValue ?? 0

            // Compute cone bounds and per-type lines from forecast relationships (cap at 24 values = 2h)
            var allForecastValues = [[Int]]()
            var forecastLines = [(type: String, values: [Int])]()

            if let forecasts = determination.forecasts {
                let hasCarbs = forecasts.contains(where: {
                    ($0.type == "cob" || $0.type == "uam") && !$0.forecastValuesArray.isEmpty
                })
                for forecast in forecasts.sorted(by: { ($0.type ?? "") < ($1.type ?? "") }) {
                    let values = forecast.forecastValuesArray.prefix(24).map { Int($0.value) }
                    guard !values.isEmpty else { continue }
                    // iob is hidden when cob or uam are active (matches phone app behavior)
                    if forecast.type == "iob", hasCarbs { continue }
                    allForecastValues.append(Array(values))
                    if let type = forecast.type {
                        forecastLines.append((type: type, values: Array(values)))
                    }
                }
            }

            let minCount = allForecastValues.map(\.count).min() ?? 0
            var minForecast = [Int]()
            var maxForecast = [Int]()

            for index in 0 ..< minCount {
                let col = allForecastValues.compactMap { $0.indices.contains(index) ? $0[index] : nil }
                minForecast.append(col.min() ?? 0)
                maxForecast.append(col.max() ?? 0)
            }

            return DeterminationData(
                cob: Int(determination.cob),
                tdd: tddValue,
                target: determination.currentTarget?.decimalValue ?? 0,
                date: determination.deliverAt,
                minForecast: minForecast,
                maxForecast: maxForecast,
                forecastLines: forecastLines
            )
        }
    }

    func fetchAndMapTempTarget() async throws -> TempTargetData? {
        try await fetchAndMapLatest(
            ofType: TempTargetStored.self,
            predicate: .predicateForOneDayAgo,
            key: "date",
            propertiesToFetch: ["enabled", "name", "target", "date", "duration"]
        ) { row in
            TempTargetData(
                isActive: row["enabled"] as? Bool ?? false,
                tempTargetName: row["name"] as? String ?? "Temp Target",
                date: row["date"] as? Date ?? Date(),
                duration: row["duration"] as? Decimal ?? 0,
                target: row["target"] as? Decimal ?? 0
            )
        }
    }

    func fetchAndMapOverride() async throws -> OverrideData? {
        try await fetchAndMapLatest(
            ofType: OverrideStored.self,
            predicate: .predicateForOneDayAgo,
            key: "date",
            propertiesToFetch: ["enabled", "name", "target", "date", "duration"]
        ) { row in
            OverrideData(
                isActive: row["enabled"] as? Bool ?? false,
                overrideName: row["name"] as? String ?? "Override",
                date: row["date"] as? Date ?? Date(),
                duration: row["duration"] as? Decimal ?? 0,
                target: row["target"] as? Decimal ?? 0
            )
        }
    }

    private func fetchAndMapLatest<Entity: NSManagedObject, Output>(
        ofType type: Entity.Type,
        predicate: NSPredicate,
        key: String,
        propertiesToFetch: [String],
        map: @escaping ([String: Any]) -> Output
    ) async throws -> Output? {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "fetchAndMapLatest"

        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: type,
            onContext: context,
            predicate: predicate,
            key: key,
            ascending: false,
            fetchLimit: 1,
            propertiesToFetch: propertiesToFetch
        )

        return try await context.perform {
            guard let rows = results as? [[String: Any]] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return rows.first.map(map)
        }
    }
}

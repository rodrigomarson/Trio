import CoreData
import LoopKit
import Observation
import SwiftDate
import SwiftUI

extension Calibrations {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() var glucoseStorage: GlucoseStorage!
        @ObservationIgnored @Injected() var calibrationService: CalibrationService!
        @ObservationIgnored @Injected() var trioAlertManager: TrioAlertManager!
        @ObservationIgnored @Injected() var fetchGlucoseManager: FetchGlucoseManager!

        var slope: Double = 1
        var intercept: Double = 1
        var newCalibration: Decimal = 0
        var calibrations: [Calibration] = []
        var calibrate: (Int) -> Double = { Double($0) }
        var items: [Item] = []
        var isSmartCGM = false
        var sensorGlucose: Double?
        var sensorGlucoseDate: Date?
        var sensorTrendRate: Double?
        var calibrationReadinessMessage = ""
        var lastActionMessage: String?

        var units: GlucoseUnits = .mgdL

        var canAddCalibration: Bool {
            guard newCalibration > 0 else { return false }
            guard isSmartCGM else { return true }
            return sensorGlucose != nil && calibrationReadinessMessage.isEmpty
        }

        let backgroundContext = CoreDataStack.shared.newTaskContext()
        private let viewContext = CoreDataStack.shared.persistentContainer.viewContext

        override func subscribe() {
            units = settingsManager.settings.units
            calibrate = calibrationService.calibrate
            setupCalibrations()
            refreshCalibrationCandidate()
        }

        private func setupCalibrations() {
            slope = calibrationService.slope
            intercept = calibrationService.intercept
            calibrations = calibrationService.calibrations
            items = calibrations.map {
                Item(calibration: $0)
            }
        }

        /// - Returns: An array of NSManagedObjectIDs for glucose readings.
        private func fetchGlucose() async throws -> [NSManagedObjectID] {
            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: GlucoseStored.self,
                onContext: backgroundContext,
                predicate: NSPredicate.predicateFor20MinAgo,
                key: "date",
                ascending: false,
                fetchLimit: 1 /// We only need the last value
            )

            return try await backgroundContext.perform {
                guard let glucoseResults = results as? [GlucoseStored] else {
                    throw CoreDataError.fetchError(function: #function, file: #file)
                }

                return glucoseResults.map(\.objectID)
            }
        }

        @MainActor func addCalibration() async {
            do {
                defer {
                    UIApplication.shared.endEditing()
                    setupCalibrations()
                    refreshCalibrationCandidate()
                }

                var glucose = newCalibration
                if units == .mmolL {
                    glucose = newCalibration.asMgdL
                }

                guard glucose >= 40, glucose <= 400 else {
                    lastActionMessage = String(localized: "A glicemia de ponta de dedo deve estar entre 40 e 400 mg/dL.")
                    return
                }

                if isSmartCGM {
                    guard
                        let smartManager = fetchGlucoseManager.cgmManager as? SmartCGMManager,
                        let candidate = smartManager.calibrationSnapshot()
                    else {
                        lastActionMessage = String(localized: "Aguarde uma nova leitura do Smart antes de calibrar.")
                        return
                    }

                    guard Self.isRecent(candidate.date) else {
                        lastActionMessage = String(localized: "A leitura do Smart está antiga. Aguarde uma nova leitura.")
                        return
                    }

                    guard candidate.trendRate.map({ abs($0) < 2 }) ?? false else {
                        lastActionMessage = String(
                            localized: "A glicemia está mudando rapidamente. Aguarde a tendência estabilizar antes de calibrar."
                        )
                        return
                    }

                    calibrationService.addCalibration(
                        Calibration(
                            x: candidate.glucose,
                            y: Double(glucose),
                            date: candidate.date
                        )
                    )
                    let releasedHandoverProtection = smartManager.confirmHandoverAfterFingerstick()
                    newCalibration = 0
                    lastActionMessage = releasedHandoverProtection
                        ? String(
                            localized: "Calibração registrada. O novo Smart foi aceito; a insulina automática será retomada após três glicemias dele."
                        )
                        : String(localized: "Calibração registrada. As próximas leituras usarão o novo ajuste.")
                    return
                }

                let glucoseValuesIds = try await fetchGlucose()
                let glucoseObjects: [GlucoseStored] = try await CoreDataStack.shared
                    .getNSManagedObject(with: glucoseValuesIds, context: viewContext)

                if let lastGlucose = glucoseObjects.first {
                    let unfiltered = lastGlucose.glucose
                    let calibration = Calibration(x: Double(unfiltered), y: Double(glucose))

                    calibrationService.addCalibration(calibration)
                    newCalibration = 0
                    lastActionMessage = String(localized: "Calibração registrada.")
                } else {
                    debug(.service, "Glucose is stale for calibration")
                    issueStaleGlucoseAlert()
                    lastActionMessage = String(localized: "Aguarde uma nova leitura do sensor antes de calibrar.")
                    return
                }
            } catch {
                debug(.default, "\(DebuggingIdentifiers.failed) Failed to add calibration: \(error)")
                lastActionMessage = String(localized: "Não foi possível registrar a calibração.")
            }
        }

        func refreshCalibrationCandidate() {
            isSmartCGM = fetchGlucoseManager.cgmManager is SmartCGMManager
            guard isSmartCGM else {
                sensorGlucose = nil
                sensorGlucoseDate = nil
                sensorTrendRate = nil
                calibrationReadinessMessage = ""
                return
            }

            guard
                let smartManager = fetchGlucoseManager.cgmManager as? SmartCGMManager,
                let candidate = smartManager.calibrationSnapshot()
            else {
                sensorGlucose = nil
                sensorGlucoseDate = nil
                sensorTrendRate = nil
                calibrationReadinessMessage = String(localized: "Aguardando uma leitura atual do Smart.")
                return
            }

            sensorGlucose = candidate.glucose
            sensorGlucoseDate = candidate.date
            sensorTrendRate = candidate.trendRate

            if !Self.isRecent(candidate.date) {
                calibrationReadinessMessage = String(localized: "A leitura do Smart está antiga. Aguarde a próxima leitura.")
            } else if candidate.trendRate.map({ abs($0) < 2 }) != true {
                calibrationReadinessMessage = String(
                    localized: "A glicemia ainda não está estável. Aguarde antes de registrar a ponta de dedo."
                )
            } else {
                calibrationReadinessMessage = ""
            }
        }

        /// Surfaces the "glucose too stale to calibrate against" condition as
        /// a one-shot info alert through `TrioAlertManager`. Mirrors the old
        /// `info(.service, …)` banner path that ran via `router.alertMessage`.
        private func issueStaleGlucoseAlert() {
            let content = Alert.Content(
                title: String(localized: "Calibration unavailable"),
                body: String(localized: "Glucose is stale for calibration"),
                acknowledgeActionButtonLabel: String(localized: "OK")
            )
            let alert = Alert(
                identifier: Alert.Identifier(
                    managerIdentifier: "trio.calibration",
                    alertIdentifier: "glucose.stale"
                ),
                foregroundContent: content,
                backgroundContent: content,
                trigger: .immediate,
                interruptionLevel: .active,
                sound: nil
            )
            trioAlertManager?.issueAlert(alert)
        }

        func removeLast() {
            calibrationService.removeLast()
            setupCalibrations()
        }

        func removeAll() {
            calibrationService.removeAllCalibrations()
            setupCalibrations()
        }

        func removeAtIndex(_ index: Int) {
            let calibration = calibrations[index]
            calibrationService.removeCalibration(calibration)
            setupCalibrations()
        }

        private static func isRecent(_ date: Date) -> Bool {
            let age = Date().timeIntervalSince(date)
            return age >= -120 && age <= .minutes(5)
        }
    }
}

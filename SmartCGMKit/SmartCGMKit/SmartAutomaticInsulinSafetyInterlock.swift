import Foundation

public enum SmartAutomaticInsulinSafetyInterlock {
    public struct State: Codable, Equatable {
        public enum Phase: String, Codable {
            case divergenceVerification
            case reacquiring
        }

        public let sensorIdentifier: String
        public let referenceGlucose: Double
        public let candidateGlucose: Double
        public let detectedAt: Date
        public var phase: Phase?

        public init(
            sensorIdentifier: String,
            referenceGlucose: Double,
            candidateGlucose: Double,
            detectedAt: Date,
            phase: Phase? = nil
        ) {
            self.sensorIdentifier = sensorIdentifier
            self.referenceGlucose = referenceGlucose
            self.candidateGlucose = candidateGlucose
            self.detectedAt = detectedAt
            self.phase = phase
        }
    }

    private static let defaultsKey = "CGMAutomaticInsulinSafetyInterlock.smartHandover"

    public static var state: State? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    public static var blockingMessage: String? {
        guard let state else { return nil }
        switch state.phase {
        case .reacquiring:
            return "The new Smart has been adopted. Automatic insulin is waiting for three readings from the new sensor before resuming."
        case .divergenceVerification,
             nil:
            return "The Smart replacement showed a significant difference. Confirm glucose with a fingerstick or wait for automatic validation of the new sensor."
        }
    }

    public static func activate(_ state: State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    public static func beginReacquisition(sensorIdentifier: String) {
        guard var current = state, current.sensorIdentifier == sensorIdentifier else { return }
        current.phase = .reacquiring
        activate(current)
    }

    public static func clear(sensorIdentifier: String? = nil) {
        if let sensorIdentifier, state?.sensorIdentifier != sensorIdentifier {
            return
        }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

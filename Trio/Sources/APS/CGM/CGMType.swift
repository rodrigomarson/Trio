import Foundation

enum CGMType: String, JSON, CaseIterable, Identifiable {
    var id: String { rawValue }
    case none
    case nightscout
    case xdrip
    case simulator
    case enlite
    case plugin

    var displayName: String {
        switch self {
        case .none:
            return "None"
        case .nightscout:
            return "Nightscout as CGM"
        case .xdrip:
            return "xDrip4iOS"
        case .simulator:
            return String(localized: "Glucose Simulator", comment: "Glucose Simulator CGM type")
        case .enlite:
            return "Medtronic Enlite"
        case .plugin:
            return "Plugin CGM"
        }
    }

    var appURL: URL? {
        switch self {
        case .enlite,
             .nightscout,
             .none:
            return nil
        case .xdrip:
            return URL(string: "xdripswift://")!
        case .simulator:
            return nil
        case .plugin:
            return nil
        }
    }

    var externalLink: URL? {
        switch self {
        case .xdrip:
            return URL(string: "https://xdrip4ios.readthedocs.io/")!
        default: return nil
        }
    }

    var subtitle: String {
        switch self {
        case .none:
            return String(localized: "None", comment: "No CGM selected")
        case .nightscout:
            return String(localized: "Uses your Nightscout as CGM", comment: "Online or internal server")
        case .xdrip:
            return String(
                localized:
                "Using shared app group with external CGM app xDrip4iOS",
                comment: "Shared app group xDrip4iOS"
            )
        case .simulator:
            return String(localized: "Glucose Simulator for Demo Only", comment: "Simple simulator")
        case .enlite:
            return String(localized: "Minilink transmitter", comment: "Minilink transmitter")
        case .plugin:
            return String(localized: "Plugin CGM", comment: "Plugin CGM")
        }
    }
}

enum GlucoseDataError: Error {
    case noData
    case unreliableData
}

/// Persists a CGM safety condition that must prevent automatic insulin delivery.
///
/// The state deliberately lives outside an individual CGM manager so the APS
/// continues to honor it after an app restart. Manual boluses and manual basal
/// actions remain under the user's direct control; this interlock applies to
/// algorithm-driven temporary basal and SMB delivery.
enum CGMAutomaticInsulinSafetyInterlock {
    struct State: Codable, Equatable {
        enum Phase: String, Codable {
            case divergenceVerification
            case reacquiring
        }

        let sensorIdentifier: String
        let referenceGlucose: Double
        let candidateGlucose: Double
        let detectedAt: Date
        var phase: Phase?
    }

    private static let defaultsKey = "CGMAutomaticInsulinSafetyInterlock.smartHandover"

    static var state: State? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    static var blockingMessage: String? {
        guard let state else { return nil }
        switch state.phase {
        case .reacquiring:
            return "O novo Smart já foi assumido. A insulina automática aguarda três glicemias próprias do novo sensor antes de ser retomada."
        case .divergenceVerification,
             nil:
            return "A troca do Smart apresentou uma diferença importante. Confirme a glicemia com ponta de dedo ou aguarde a validação automática do novo sensor."
        }
    }

    static func activate(_ state: State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func beginReacquisition(sensorIdentifier: String) {
        guard var current = state, current.sensorIdentifier == sensorIdentifier else { return }
        current.phase = .reacquiring
        activate(current)
    }

    static func clear(sensorIdentifier: String? = nil) {
        if let sensorIdentifier, state?.sensorIdentifier != sensorIdentifier {
            return
        }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

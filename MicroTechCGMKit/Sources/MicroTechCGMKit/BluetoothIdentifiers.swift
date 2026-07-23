import Foundation

public enum MicroTechBluetoothIdentifiers {
    public static let service = "0000181F-0000-1000-8000-00805F9B34FB"

    static func isProtocolService(_ value: String) -> Bool {
        let normalized = value.uppercased()
        return normalized == "181F" || normalized == service
    }
}

public enum MicroTechCharacteristic: String, CaseIterable, Hashable, Sendable {
    case keyExchange = "0000F001-0000-1000-8000-00805F9B34FB"
    case command = "0000F002-0000-1000-8000-00805F9B34FB"
    case liveGlucose = "0000F003-0000-1000-8000-00805F9B34FB"
}

public enum MicroTechDeviceFamily: String, CaseIterable, Equatable, Sendable {
    case smart
    case linX
    case aiDEXX
    case lumi

    var localNamePrefix: String {
        switch self {
        case .smart:
            return "Smart-"
        case .linX:
            return "LinX-"
        case .aiDEXX:
            return "AiDEX X-"
        case .lumi:
            return "Lumi-"
        }
    }
}

public struct MicroTechDiscoveredDevice: Equatable, Sendable {
    public let identifier: UUID
    public let localName: String
    public let family: MicroTechDeviceFamily
    public let serial: MicroTechSensorSerial

    public init?(
        identifier: UUID,
        localName: String,
        advertisedServiceUUIDs: [String]
    ) {
        guard advertisedServiceUUIDs.contains(where: MicroTechBluetoothIdentifiers.isProtocolService) else {
            return nil
        }

        guard let family = MicroTechDeviceFamily.allCases.first(where: {
            localName.hasPrefix($0.localNamePrefix)
        }) else {
            return nil
        }

        guard let serial = try? MicroTechSensorSerial(String(localName.suffix(MicroTechSensorSerial.requiredLength))) else {
            return nil
        }

        self.identifier = identifier
        self.localName = localName
        self.family = family
        self.serial = serial
    }
}

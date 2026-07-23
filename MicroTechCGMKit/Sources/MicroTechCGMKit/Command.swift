import Foundation

public enum MicroTechCommand: Equatable, Sendable {
    case deviceInformation
    case currentGlucose
    case startTime
    case historyRange
    case processedHistory(startingAt: UInt16)
    case reconnectControl34
    case reconnectControl35

    var identifier: UInt8 {
        switch self {
        case .deviceInformation:
            return 0x10
        case .currentGlucose:
            return 0x11
        case .startTime:
            return 0x21
        case .historyRange:
            return 0x22
        case .processedHistory:
            return 0x23
        case .reconnectControl34:
            return 0x34
        case .reconnectControl35:
            return 0x35
        }
    }

    var payload: [UInt8] {
        switch self {
        case let .processedHistory(startingAt):
            return [
                UInt8(truncatingIfNeeded: startingAt),
                UInt8(truncatingIfNeeded: startingAt >> 8)
            ]
        case .reconnectControl34, .reconnectControl35:
            return [0x01]
        default:
            return []
        }
    }

    public var plaintextFrame: [UInt8] {
        MicroTechChecksums.appendingCrc16(to: [identifier] + payload)
    }
}

import Foundation

public struct MicroTechProcessedGlucoseWord: Equatable, Sendable {
    public let glucoseMgDL: UInt16
    public let isWarmup: Bool
    public let unknownFlags: UInt8
    public let isValid: Bool

    public init(rawValue: UInt16) {
        glucoseMgDL = rawValue & 0x03FF
        isWarmup = rawValue & 0x0400 != 0
        unknownFlags = UInt8(truncatingIfNeeded: (rawValue >> 11) & 0x0F)
        isValid = rawValue & 0x8000 != 0
    }
}

public struct MicroTechLiveGlucosePacket: Equatable, Sendable {
    public static let expectedLength = 17

    public let messageKind: UInt16
    public let reservedByte: UInt8
    public let rawTrend: Int8
    public let minuteIndex: UInt16
    public let processedGlucose: MicroTechProcessedGlucoseWord
    public let trailingStatusBytes: [UInt8]

    public var trendMgDLPerMinute: Double {
        Double(rawTrend) / 10
    }

    public var indicatesEndedSensor: Bool {
        UInt8(truncatingIfNeeded: messageKind) == 0x03
    }

    public var hasUsableGlucose: Bool {
        processedGlucose.isValid && !processedGlucose.isWarmup && !indicatesEndedSensor
    }

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count == Self.expectedLength else {
            throw MicroTechProtocolError.invalidPacketLength(expected: Self.expectedLength, actual: bytes.count)
        }
        guard MicroTechChecksums.hasValidTrailingCrc16(bytes) else {
            throw MicroTechProtocolError.checksumMismatch
        }

        messageKind = Self.uint16LittleEndian(bytes[0], bytes[1])
        reservedByte = bytes[2]
        rawTrend = Int8(bitPattern: bytes[3])
        minuteIndex = Self.uint16LittleEndian(bytes[4], bytes[5])
        processedGlucose = MicroTechProcessedGlucoseWord(
            rawValue: Self.uint16LittleEndian(bytes[6], bytes[7])
        )
        trailingStatusBytes = Array(bytes[8 ..< 15])
    }

    private static func uint16LittleEndian(_ low: UInt8, _ high: UInt8) -> UInt16 {
        UInt16(low) | UInt16(high) << 8
    }
}

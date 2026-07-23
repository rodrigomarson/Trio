import Foundation

public enum MicroTechProtocolError: Error, Equatable, Sendable {
    case invalidSerialLength(actual: Int)
    case invalidSerialCharacter(Character)
    case invalidKeyLength(expected: Int, actual: Int)
    case invalidPacketLength(expected: Int, actual: Int)
    case invalidPayloadLength(command: UInt8, expected: Int, actual: Int)
    case checksumMismatch
    case encryptionFailed
    case decryptionFailed
}

extension MicroTechProtocolError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidSerialLength(actual):
            return "The sensor serial must contain exactly 10 ASCII alphanumeric characters; received \(actual)."
        case let .invalidSerialCharacter(character):
            return "The sensor serial contains an unsupported character: \(character)."
        case let .invalidKeyLength(expected, actual):
            return "The protocol key must contain \(expected) bytes; received \(actual)."
        case let .invalidPacketLength(expected, actual):
            return "The protocol packet must contain \(expected) bytes; received \(actual)."
        case let .invalidPayloadLength(command, expected, actual):
            return "Command 0x\(String(command, radix: 16)) requires \(expected) payload bytes; received \(actual)."
        case .checksumMismatch:
            return "The protocol packet checksum is invalid."
        case .encryptionFailed:
            return "The protocol packet could not be encrypted."
        case .decryptionFailed:
            return "The protocol packet could not be decrypted."
        }
    }
}

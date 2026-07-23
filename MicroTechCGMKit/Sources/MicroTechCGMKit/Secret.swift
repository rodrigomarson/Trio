import Foundation

public struct MicroTechSecret: Equatable, Sendable {
    let bytes: [UInt8]

    public init(keyBytes: [UInt8]) throws {
        guard keyBytes.count == MicroTechProtocolCrypto.keyLength else {
            throw MicroTechProtocolError.invalidKeyLength(
                expected: MicroTechProtocolCrypto.keyLength,
                actual: keyBytes.count
            )
        }
        bytes = keyBytes
    }
}

extension MicroTechSecret: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "<redacted \(bytes.count)-byte secret>"
    }

    public var debugDescription: String {
        description
    }
}
